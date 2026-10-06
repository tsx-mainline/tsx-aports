#!/bin/bash
# Build one or all tsx-aports packages with abuild, in an Alpine v3.24
# container of the package architecture: armv7 (docker --platform
# linux/arm/v7) or aarch64 (docker --platform linux/arm64). A host of another
# architecture runs the container under qemu-user. An arm64 host with 32-bit
# support runs both natively. Each architecture has its own image tag, made
# by scripts/arch-image.sh, and the script checks the architecture of the
# container before the first build of a pass. The build is local by default,
# like the build tools of the main repo.
# BUILD_HOST is optional.
# It uses the same push, run, and pull pattern as tools/build/remote-build.sh
# in tsx-xx60-linux. It has no default value, so this repo names no build host.
#
#   scripts/build.sh [--skip-existing] [--skip-unreachable] [--verify] [--arch ARCH] <PKGDIR>|--all
#   PKGDIR is a package directory relative to the repo root, for example
#   common/sendspin-cli or xx60/tsx-xx60-chromium.
#
#   --arch ARCH         armv7 or aarch64. The default is the architecture in
#                       the first architecture in the arch= of the package. It
#                       matters for a noarch package (common/tsx-keys, armv7
#                       by default) and for --all. With --all and no --arch,
#                       the script builds two passes: armv7 (common/ and
#                       xx60/) and aarch64 (common/). A package
#                       whose arch= does not list the pass architecture is
#                       left out of that pass.
#
#   --skip-existing     do not build a package if
#                       <pkgname>-<pkgver>-r<pkgrel>.apk is already in
#                       packages/v3.24/<category>/. In CI,
#                       scripts/carry-forward.py puts the published tree
#                       there first, so the build makes only new versions.
#                       A change to another package does not rebuild
#                       tensorflow-lite-c or chromium.
#   --skip-unreachable  skip a package if a download source= gets the HTTP
#                       status 404 or 410. This is the case for a kernel
#                       package whose tsx-xx60-linux release does not exist
#                       yet. The script prints a GitHub ::warning:: line and
#                       does not change the exit status. Any other network
#                       failure fails the build. A source that is already in
#                       the dist/ of the package counts as present.
#   --verify            do not write new sha512sums. The build fails when a
#                       downloaded source does not match the sha512sums of the
#                       APKBUILD. CI uses this, so a changed archive or a
#                       wrong sum stops the build and nothing is signed.
#
# Environment:
#   TSX_APORTS_KEY   path to the PRIVATE signing key (required), for example
#                    tsx-mainline/keys/tsx-mainline-<id>.rsa. The keys/
#                    directory of this repo is gitignored and never holds it.
#                    The key stays outside every repo.
#   BUILD_HOST       ssh destination to build on instead of this machine
#                    (optional).
#   BUILD_DIR        remote path that mirrors this repo (required with
#                    BUILD_HOST).
#
# Order: with --all, a package is built after the packages of this repo that it
# depends on or makes depends on (order_dirs below). A pass builds the packages
# in packages/v3.24/<category>/<arch>, and a family package also sees the
# common packages that an earlier build of this run made there.
#
# Steps for each package: `abuild checksum` writes real sha512sums for each
# source= (for example the tag archive of tsx-linux-common). With --verify,
# the script leaves this step out, and `abuild -r` checks the sums that the
# APKBUILD has. Then `abuild -r` fetches the missing build dependencies,
# builds, packages, signs, and indexes.
# Output: packages/v3.24/<common|xx60>/<arch>/*.apk and APKINDEX.tar.gz.
# With BUILD_HOST, the script also copies the APKBUILD back, because the
# checksum step can change it. Then the real checksum is what you commit.
# Check the diff before you commit.
#
# THE PRIVATE KEY NEVER LEAVES THIS MACHINE (user rule). A local build (no
# BUILD_HOST) mounts TSX_APORTS_KEY read-only into the container and signs
# there. A BUILD_HOST build does NOT copy TSX_APORTS_KEY to the host. The
# remote run (ON_HOST=1) generates its OWN throwaway RSA keypair and signs
# with that key. The script pulls the throwaway-signed packages back and
# re-signs them HERE, locally, with the real key. scripts/resign.sh does
# this in four steps:
#   1. It splits each apk.
#   2. It discards the throwaway signature.
#   3. It signs control.tar.gz with abuild-sign and TSX_APORTS_KEY in a
#      disposable container.
#   4. It runs `apk verify` on the result against a trust store that holds
#      ONLY the public key of the project.
# CI does not set BUILD_HOST. CI restores its GitHub Actions secret
# TSX_APORTS_PRIVKEY straight into a local TSX_APORTS_KEY, like any other
# local build (.github/workflows/build.yml).
#
# The throwaway keypair is in BUILD_DIR/.throwaway-key/ on the build host.
# Separate scripts/build.sh calls for the same BUILD_DIR REUSE it. The script
# does not generate a new key and delete it for each call. The reason: the
# `depends="tsx-xx60-boot-tools>=1-r4"` of a kernel package is resolved by
# abuild from packages/v3.24 (REPODEST). Like .throwaway-key/, this directory
# is excluded from the push below, so it stays on the host between calls.
# If each call made its own throwaway key, a dependency from an earlier call
# would be in an index signed by a key that the container of the current call
# does not trust ("UNTRUSTED signature"). You would then have to build every
# dependent package by hand in one session under one key.
# The docker build step below also trusts the committed public key of this
# repo (common/tsx-keys/*.rsa.pub). A dependency can carry the real project
# signature (for example packages/ from a local build), and the container
# then trusts it too. The container gets only a .pub, never the private key.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# arch_platform, ensure_image, check_image_arch and arch_image. Each
# architecture has its own image tag (see that file).
. "$(dirname "${BASH_SOURCE[0]}")/arch-image.sh"

# to_build_host ARGS...: runs `rsync -a ARGS...`. It refuses if any argument
# names a private key. This is $TSX_APORTS_KEY itself, or anything that ends
# in .rsa and is not its own .rsa.pub. This one function is the only guard
# between BUILD_HOST and the private key.
# Every rsync in the BUILD_HOST branch below uses it, also the ones that do
# not touch the key now. A future rsync call in that branch then has the
# guard without an extra check.
# scripts/tests/test-resign.sh tests this function directly. It does not need
# BUILD_HOST, because it loads this file with TSX_APORTS_BUILD_SH_SOURCE_ONLY=1.
to_build_host() {
	local a
	for a in "$@"; do
		case "$a" in
		"$TSX_APORTS_KEY"|*.rsa) tbh_die_key "$a";;
		esac
	done
	rsync -a "$@"
}
tbh_die_key() { echo "build.sh: BUG: refusing to copy a private key ($1) to BUILD_HOST" >&2; exit 1; }

# assert_remote_cmd_safe CMD: a guard for the command string that this script
# gives to `ssh "$BUILD_HOST"`. It refuses if the string contains the local
# path of the private key. It must not, because the remote build never sees
# the key. It sees only a throwaway key that it generates itself.
assert_remote_cmd_safe() {
	case "$1" in
	*"$TSX_APORTS_KEY"*) echo "build.sh: BUG: the command about to run on BUILD_HOST embeds the local private key path -- refusing" >&2; exit 1;;
	esac
}

# apkbuild_info PKGDIR: prints "<pkgname> <pkgver> <pkgrel>". Then it prints
# one line for each download URL in source=, without the optional "name::"
# prefix. It reads the APKBUILD in a subshell, like abuild does. The APKBUILDs
# of this repo define only variables and functions at the top level.
apkbuild_info() {
	(
		set +eu
		startdir="$REPO/$1" srcdir=/nonexistent
		. "$REPO/$1/APKBUILD" >/dev/null 2>&1
		echo "$pkgname $pkgver $pkgrel"
		for s in $source; do
			case "${s#*::}" in http://*|https://*) echo "${s#*::}";; esac
		done
	)
}

# apkbuild_arch PKGDIR: the arch= value of the APKBUILD.
apkbuild_arch() {
	(
		set +eu
		startdir="$REPO/$1" srcdir=/nonexistent
		. "$REPO/$1/APKBUILD" >/dev/null 2>&1
		echo "$arch"
	)
}

# apkbuild_graph PKGDIR: two lines. The first holds the names that the recipe
# makes (pkgname, the subpackages, the provides). The second holds the names
# that it needs (depends and makedepends, as written).
apkbuild_graph() {
	(
		set +eu
		startdir="$REPO/$1" srcdir=/nonexistent
		. "$REPO/$1/APKBUILD" >/dev/null 2>&1
		names=$pkgname
		for s in $subpackages; do names="$names ${s%%:*}"; done
		for s in $provides; do names="$names ${s%%[<>=~]*}"; done
		echo "$names"
		echo $depends $makedepends
	)
}

# order_dirs: reads package directories (one on each line), prints them in
# build order. A package comes after every package of the list that it needs
# (depends or makedepends, also through a subpackage or a provides). abuild
# installs the depends of a package before the build, so a package that is
# not built yet makes the build fail ("no such package"). Entries that name no
# recipe of the list (Alpine packages, so: and cmd: names) are not important.
# Packages without a relation keep their input order. A cycle stops the script.
order_dirs() {
	local -A owner=() deps=() state=()
	local -a dirs=() out=() g=()
	local d n
	while IFS= read -r d; do [ -n "$d" ] && dirs+=("$d"); done
	for d in "${dirs[@]}"; do
		mapfile -t g < <(apkbuild_graph "$d")
		for n in ${g[0]}; do [ -n "${owner[$n]:-}" ] || owner[$n]=$d; done
		deps[$d]=${g[1]:-}
	done
	order_visit() {
		local d=$1 x n o
		state[$d]=1
		for x in ${deps[$d]}; do
			n=${x%%[<>=~]*}; n=${n#!}
			case $n in ""|*:*) continue;; esac
			o=${owner[$n]:-}
			{ [ -n "$o" ] && [ "$o" != "$d" ]; } || continue
			case ${state[$o]:-0} in
			1) echo "build.sh: dependency cycle between $d and $o" >&2; exit 1;;
			0) order_visit "$o";;
			esac
		done
		state[$d]=2
		out+=("$d")
	}
	for d in "${dirs[@]}"; do [ "${state[$d]:-0}" = 0 ] && order_visit "$d"; done
	[ ${#out[@]} = 0 ] || printf '%s\n' "${out[@]}"
	return 0
}

# arm32_prefix ARCH: prints "linux32" when an ARCH container needs it, and
# nothing otherwise. A 32-bit ARM (armv7) container on an arm64 host runs
# natively, and its uname -m says aarch64 because the kernel is 64-bit. Build
# tools (CMake, for example) then pick the 64-bit code. linux32 makes uname -m
# say armv8l, like a 32-bit ARM machine. A container under qemu-user already
# says armv7l and needs nothing.
arm32_prefix() {
	if [ "$1" = armv7 ] && [ "$(uname -m)" = aarch64 ]; then echo linux32; fi
}

# pkg_arch PKGDIR WANT: the architecture to build PKGDIR for, or nothing when
# its arch= does not allow WANT (WANT empty: the first one it lists).
pkg_arch() {
	local a w=$2 x
	a=$(apkbuild_arch "$1")
	case " $a " in *" noarch "*|*" all "*) echo "${w:-armv7}"; return;; esac
	if [ -n "$w" ]; then
		case " $a " in *" $w "*) echo "$w";; esac
		return
	fi
	for x in $a; do case $x in armv7|aarch64) echo "$x"; return;; esac; done
}

# This lets a test load the functions above without the rest of the script.
# It needs no PKGDIR, no docker, no ssh, and no real BUILD_HOST.
if [ "${TSX_APORTS_BUILD_SH_SOURCE_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

SKIP_EXISTING=0 SKIP_UNREACHABLE=0 VERIFY=0 PASS= WANT_ARCH=
while :; do case ${1:-} in
	--skip-existing) SKIP_EXISTING=1; PASS="$PASS $1"; shift;;
	--skip-unreachable) SKIP_UNREACHABLE=1; PASS="$PASS $1"; shift;;
	--verify) VERIFY=1; PASS="$PASS $1"; shift;;
	--arch) WANT_ARCH=${2:?--arch needs armv7 or aarch64}; arch_platform "$WANT_ARCH" >/dev/null || exit 1; PASS="$PASS --arch $WANT_ARCH"; shift 2;;
	*) break;;
esac; done
TARGET=${1:?"usage: build.sh [--skip-existing] [--skip-unreachable] [--verify] [--arch ARCH] <PKGDIR>|--all"}

if [ -n "${BUILD_HOST:-}" ] && [ -z "${ON_HOST:-}" ]; then
	: "${BUILD_DIR:?BUILD_HOST needs BUILD_DIR (remote path this repo is mirrored to)}"
	: "${TSX_APORTS_KEY:?set TSX_APORTS_KEY (local path to the private key -- it re-signs the build host output afterward; it is never copied there)}"
	[ -f "$TSX_APORTS_KEY" ] && [ -f "$TSX_APORTS_KEY.pub" ] || { echo "build.sh: no such key: $TSX_APORTS_KEY(.pub)" >&2; exit 1; }

	echo "[build.sh] pushing $REPO -> $BUILD_HOST:$BUILD_DIR"
	ssh -o BatchMode=yes "$BUILD_HOST" "mkdir -p '$BUILD_DIR'"
	# src/ and pkg/ are the work directories of abuild for each package. The
	# container owns them as root, because builds run with abuild -F. Never
	# delete them or enter them from here. They are build state on the host
	# and not part of the pushed source tree. .throwaway-key/ is the
	# persistent throwaway signing keypair (see below). It is also state on
	# the host. The local side never pushes it and never deletes it.
	to_build_host --delete --exclude packages/ --exclude '.throwaway-key/' --exclude '.git/' --exclude 'src/' --exclude 'pkg/' --exclude 'extract/' \
		"$REPO/" "$BUILD_HOST:$BUILD_DIR/"

	echo "[build.sh] building on $BUILD_HOST with a throwaway signing key (generated there and reused for this BUILD_DIR -- the real key stays here)"
	# KD stays at BUILD_DIR/.throwaway-key. A package from an earlier,
	# separate scripts/build.sh call for this BUILD_DIR (for example
	# tsx-xx60-boot-tools) then has a signature that the container of THIS call
	# trusts, when it resolves the package as a build dependency from
	# packages/v3.24 (REPODEST). See the comment at the top of this file.
	REMOTE_CMD="set -e; KD='$BUILD_DIR/.throwaway-key'; mkdir -p \"\$KD\"; [ -f \"\$KD/throwaway.rsa\" ] || { openssl genrsa -out \"\$KD/throwaway.rsa\" 4096 >/dev/null 2>&1; openssl rsa -in \"\$KD/throwaway.rsa\" -pubout -out \"\$KD/throwaway.rsa.pub\" >/dev/null 2>&1; }; ON_HOST=1 TSX_APORTS_KEY=\"\$KD/throwaway.rsa\" '$BUILD_DIR/scripts/build.sh'$PASS '$TARGET'"
	assert_remote_cmd_safe "$REMOTE_CMD"
	ssh -o BatchMode=yes "$BUILD_HOST" "$REMOTE_CMD"

	echo "[build.sh] pulling packages/ back (still signed with the build host's throwaway key)"
	REMOTE_PKGS=$(mktemp -d)
	rsync -a "$BUILD_HOST:$BUILD_DIR/packages/" "$REMOTE_PKGS/"
	mkdir -p "$REPO/packages"
	echo "[build.sh] re-signing every package locally with the real key (it never left this machine)"
	while IFS= read -r -d '' arch_dir; do
		rel=${arch_dir#"$REMOTE_PKGS/"}
		mkdir -p "$REPO/packages/$rel"
		"$HERE/resign.sh" "$arch_dir" "$REPO/packages/$rel"
	done < <(find "$REMOTE_PKGS" -mindepth 3 -maxdepth 3 -type d -print0)
	rm -rf "$REMOTE_PKGS"

	if [ "$TARGET" != --all ]; then
		rsync -a "$BUILD_HOST:$BUILD_DIR/$TARGET/APKBUILD" "$REPO/$TARGET/APKBUILD"
	else
		for CAT in common xx60; do
			for d in "$REPO/$CAT"/*/; do
				[ -f "${d}APKBUILD" ] || continue
				p="$CAT/$(basename "$d")/APKBUILD"
				rsync -a "$BUILD_HOST:$BUILD_DIR/$p" "$REPO/$p"
			done
		done
	fi
	exit 0
fi

: "${TSX_APORTS_KEY:?set TSX_APORTS_KEY (path to the private signing key)}"
[ -f "$TSX_APORTS_KEY" ] || { echo "build.sh: no such file: $TSX_APORTS_KEY" >&2; exit 1; }
[ -f "$TSX_APORTS_KEY.pub" ] || { echo "build.sh: no such file: $TSX_APORTS_KEY.pub" >&2; exit 1; }
KEYNAME=$(basename "$TSX_APORTS_KEY")

# JOBS: one "PKGDIR ARCH" line per build
JOBS=
if [ "$TARGET" = --all ]; then
	for A in ${WANT_ARCH:-armv7 aarch64}; do
		case $A in armv7) CATS="common xx60";; *) CATS="common";; esac
		LIST=
		for D in $( (cd "$REPO" && for c in $CATS; do [ -d "$c" ] && find "$c" -mindepth 1 -maxdepth 1 -type d; done) | sort); do
			[ -f "$REPO/$D/APKBUILD" ] || continue
			[ -n "$(pkg_arch "$D" "$A")" ] && LIST="$LIST$D
"
		done
		# Build in dependency order (order_dirs), not in the order of the names.
		ORDERED=$(printf '%s' "$LIST" | order_dirs) || exit 1
		for D in $ORDERED; do JOBS="$JOBS$D $A
"; done
	done
else
	[ -f "$REPO/$TARGET/APKBUILD" ] || { echo "build.sh: no $REPO/$TARGET/APKBUILD" >&2; exit 1; }
	A=$(pkg_arch "$TARGET" "$WANT_ARCH")
	[ -n "$A" ] || { echo "build.sh: $TARGET is not built for ${WANT_ARCH:-any architecture} (arch=$(apkbuild_arch "$TARGET"))" >&2; exit 1; }
	JOBS="$TARGET $A
"
fi

# want_build PKGDIR ARCH: returns 0 to build the package, and 1 to skip it. It says why it skips.
# --skip-existing looks only in the directory of ARCH, so an armv7 build does not hide a
# missing aarch64 build.
want_build() {
	local info name ver rel url code cat n
	info=$(apkbuild_info "$1")
	read -r name ver rel <<<"$(echo "$info" | head -n1)"
	cat=${1%%/*}
	if [ "$SKIP_EXISTING" = 1 ]; then
		n="$REPO/packages/v3.24/$cat/$2/$name-$ver-r$rel.apk"
		if [ -f "$n" ]; then
			echo "[build.sh] $1: $name-$ver-r$rel.apk already in packages/v3.24/$cat/$2 -- skipping"
			return 1
		fi
	fi
	if [ "$SKIP_UNREACHABLE" = 1 ]; then
		for url in $(echo "$info" | tail -n +2); do
			[ -f "$REPO/$1/dist/$(basename "$url")" ] && continue
			code=$(curl -sL -r 0-0 -o /dev/null -w '%{http_code}' "$url" || true)
			case "$code" in
			200|206) ;;
			404|410)
				echo "::warning title=$name skipped::$url does not exist yet (HTTP $code); $1 was not built"
				return 1;;
			*) echo "build.sh: $1: cannot check $url (HTTP $code)" >&2; exit 1;;
			esac
		done
	fi
	return 0
}

echo "[build.sh] build order:$(printf '%s\n' "$JOBS" | awk 'NF{printf " %s(%s)", $1, $2}')"
# READY: the architectures whose image is pulled and checked in this run. The
# check stops the build when a container of one pass reports another
# architecture (scripts/arch-image.sh says why this can happen).
READY=
CHECKSUM_CMD='abuild -F checksum'
[ "$VERIFY" = 0 ] || CHECKSUM_CMD=true
while read -r PKGDIR PKGARCH; do
	[ -n "$PKGDIR" ] || continue
	want_build "$PKGDIR" "$PKGARCH" || continue
	case " $READY " in
	*" $PKGARCH "*) ;;
	*) ensure_image "$PKGARCH"; check_image_arch "$PKGARCH"; READY="$READY $PKGARCH";;
	esac
	echo "=== building $PKGDIR ($PKGARCH) ==="
	# A family package (xx60/...) depends on common packages (tsx-base,
	# tsx-ledbar and more). abuild -r resolves a dependency only from the
	# repository of the package itself, so the build adds the common packages
	# that an earlier build wrote to packages/v3.24/common.
	COMMON_REPO=
	case ${PKGDIR%%/*} in
	common) ;;
	*) [ -f "$REPO/packages/v3.24/common/$PKGARCH/APKINDEX.tar.gz" ] && COMMON_REPO=/repo/packages/v3.24/common;;
	esac
	docker run --rm --platform "$(arch_platform "$PKGARCH")" \
		-v "$REPO:/repo" \
		-v "$TSX_APORTS_KEY:/keys/$KEYNAME:ro" \
		-v "$TSX_APORTS_KEY.pub:/keys/$KEYNAME.pub:ro" \
		"$(arch_image "$PKGARCH")" $(arm32_prefix "$PKGARCH") sh -euc "
			[ -z '$COMMON_REPO' ] || echo '$COMMON_REPO' >> /etc/apk/repositories
			apk update >/dev/null
			# zstd: alpine-sdk does not install it. The unpack step of
			# abuild needs the zstd binary for each .tar.zst source, for
			# example the xx60/tsx-xx60-kernel-FLAVOR bundles.
			apk add --no-cache alpine-sdk zstd >/dev/null
			cp /keys/$KEYNAME.pub /etc/apk/keys/
			# Also trust the committed public keys of this repo
			# (common/tsx-keys/*.rsa.pub, public and already in the pushed
			# tree). A build dependency from packages/v3.24 can have the
			# real project signature (for example the output of a local
			# build) and not the signing key of this container. It must
			# still verify.
			for k in /repo/common/tsx-keys/*.rsa.pub; do [ -f \"\$k\" ] && cp \"\$k\" /etc/apk/keys/; done
			mkdir -p /root/.abuild
			echo 'PACKAGER_PRIVKEY=/keys/$KEYNAME' > /root/.abuild/abuild.conf
			echo 'PACKAGER=\"unex <7575866+unex@users.noreply.github.com>\"' >> /root/.abuild/abuild.conf
			cd /repo/$PKGDIR
			$CHECKSUM_CMD
			abuild -F -r -P /repo/packages/v3.24
		"
done <<EOF
$JOBS
EOF
echo "=== packages/v3.24 ==="
find "$REPO/packages/v3.24" -maxdepth 3 2>/dev/null || true
