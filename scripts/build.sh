#!/bin/bash
# Build one or all tsx-aports packages with abuild, in an Alpine v3.24 armv7
# container (docker --platform linux/arm/v7, qemu-user). Local by default,
# like the main repo's build tools; BUILD_HOST is opt-in (same push/run/pull
# pattern as tsx-xx60-linux's tools/build/remote-build.sh) -- no default
# value, so this repo names no build host.
#
#   scripts/build.sh [--skip-existing] [--skip-unreachable] <PKGDIR>|--all
#   PKGDIR is a package directory relative to the repo root, e.g.
#   common/sendspin-cli or xx60/tsx-xx60-chromium.
#
#   --skip-existing     do not build a package whose
#                       <pkgname>-<pkgver>-r<pkgrel>.apk is already in
#                       packages/v3.24/<category>/ (CI: scripts/carry-forward.py
#                       puts the published tree there first, so only new
#                       versions are built -- tensorflow-lite-c and chromium
#                       are never rebuilt just because something else changed).
#   --skip-unreachable  skip (with a GitHub ::warning:: line, exit status
#                       unaffected) a package with a download source= that
#                       the server answers 404/410 for, e.g. a kernel package
#                       whose tsx-xx60-linux release does not exist yet. Any
#                       other network failure still fails the build. A source
#                       already staged in the package's dist/ counts as present.
#
# Env:
#   TSX_APORTS_KEY   path to the PRIVATE signing key (required), e.g.
#                    tsx-mainline/keys/tsx-mainline-<id>.rsa (this repo's own
#                    keys/ is gitignored and never holds it -- the key lives
#                    outside every repo).
#   BUILD_HOST       ssh destination to build on instead of here (opt-in).
#   BUILD_DIR        remote path this repo is mirrored to (required with
#                    BUILD_HOST).
#
# What runs per package: `abuild checksum` (fills in real sha512sums for any
# source= that came from a URL -- e.g. sendspin-cli's pinned tarball; a
# no-op when all sources are already-checksummed local files) then
# `abuild -r` (fetch missing build deps, build, package, sign, index).
# Output: packages/v3.24/<common|xx60>/armv7/*.apk +APKINDEX.tar.gz. If
# BUILD_HOST was used, the (possibly checksum-updated) APKBUILD is synced
# back too, so the real checksum is what ends up committed -- diff it before
# committing.
#
# THE PRIVATE KEY NEVER LEAVES THIS MACHINE (user rule). A local build (no
# BUILD_HOST) mounts TSX_APORTS_KEY read-only into the container as before
# and signs there, same as ever. A BUILD_HOST build does NOT copy
# TSX_APORTS_KEY to the host at all: the remote invocation (ON_HOST=1)
# generates its OWN throwaway RSA keypair and signs with that; the
# throwaway-signed packages are pulled back and re-signed HERE, locally,
# with the real key (scripts/resign.sh: split each apk, discard the
# throwaway signature, abuild-sign control.tar.gz with TSX_APORTS_KEY in a
# disposable container, then `apk verify` the result against a trust store
# holding ONLY the project's public key). CI is unaffected -- it never sets
# BUILD_HOST; its GitHub Actions secret TSX_APORTS_PRIVKEY is restored
# straight into a local TSX_APORTS_KEY the same as any other local build
# (.github/workflows/build.yml).
#
# The throwaway keypair lives at BUILD_DIR/.throwaway-key/ on the build
# host and is REUSED across separate scripts/build.sh invocations against
# the same BUILD_DIR, instead of being generated fresh (and deleted) every
# call: a kernel package's `depends="tsx-xx60-boot-tools>=1-r4"` is
# resolved by abuild from packages/v3.24 (REPODEST), which -- like
# .throwaway-key/ -- is excluded from the push below and so persists
# remotely between calls; if each call minted its own throwaway key, a dep
# built in an earlier call would sit in an index signed by a key the
# current call's container never trusts ("UNTRUSTED signature"), forcing
# every dependent package into one big session under one key by hand. The
# docker build step below also trusts this repo's own committed public key
# (common/tsx-keys/*.rsa.pub) so a dependency that happens to carry the
# real project signature (e.g. packages/ staged in from a local build) is
# trusted too -- still only ever a .pub, never the private key.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

# to_build_host ARGS...: `rsync -a ARGS...`, but refuses outright if any
# argument names a private key -- $TSX_APORTS_KEY itself, or anything ending
# in .rsa that is not its own .rsa.pub -- so this one function is the single
# place standing between BUILD_HOST and the private key ever reaching it.
# Every rsync in the BUILD_HOST branch below goes through it, even ones that
# do not currently touch the key: a future edit adding one more rsync call
# there is covered by construction, not by remembering to re-check it.
# scripts/tests/test-resign.sh exercises this directly (no BUILD_HOST
# needed: it sources this file with TSX_APORTS_BUILD_SH_SOURCE_ONLY=1).
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

# assert_remote_cmd_safe CMD: a grep guard on the literal command string
# this script is about to hand to `ssh "$BUILD_HOST"` -- refuses if it
# embeds the local private key's own path (it must not: the remote build
# never sees it, only a throwaway key it generates itself).
assert_remote_cmd_safe() {
	case "$1" in
	*"$TSX_APORTS_KEY"*) echo "build.sh: BUG: the command about to run on BUILD_HOST embeds the local private key path -- refusing" >&2; exit 1;;
	esac
}

# apkbuild_info PKGDIR: print "<pkgname> <pkgver> <pkgrel>" then one line per
# download URL in source= (the optional "name::" prefix stripped), by
# sourcing the APKBUILD in a subshell -- the same thing abuild does. The
# APKBUILDs of this repo only define variables and functions at top level.
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

# Let a test load the two functions above without running the rest of this
# script (no PKGDIR required, no docker, no ssh, no real BUILD_HOST).
if [ "${TSX_APORTS_BUILD_SH_SOURCE_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

SKIP_EXISTING=0 SKIP_UNREACHABLE=0 PASS=
while :; do case ${1:-} in
	--skip-existing) SKIP_EXISTING=1; PASS="$PASS $1"; shift;;
	--skip-unreachable) SKIP_UNREACHABLE=1; PASS="$PASS $1"; shift;;
	*) break;;
esac; done
TARGET=${1:?"usage: build.sh [--skip-existing] [--skip-unreachable] <PKGDIR>|--all"}

if [ -n "${BUILD_HOST:-}" ] && [ -z "${ON_HOST:-}" ]; then
	: "${BUILD_DIR:?BUILD_HOST needs BUILD_DIR (remote path this repo is mirrored to)}"
	: "${TSX_APORTS_KEY:?set TSX_APORTS_KEY (local path to the private key -- it re-signs the build host output afterward; it is never copied there)}"
	[ -f "$TSX_APORTS_KEY" ] && [ -f "$TSX_APORTS_KEY.pub" ] || { echo "build.sh: no such key: $TSX_APORTS_KEY(.pub)" >&2; exit 1; }

	echo "[build.sh] pushing $REPO -> $BUILD_HOST:$BUILD_DIR"
	ssh -o BatchMode=yes "$BUILD_HOST" "mkdir -p '$BUILD_DIR'"
	# src/ and pkg/ are abuild's own per-package work dirs (root-owned inside
	# the container, since builds run with abuild -F); never delete or
	# descend into them from here -- they are host-side build state, not
	# part of the pushed source tree. .throwaway-key/ is the persistent
	# throwaway signing keypair below -- also host-side state, never
	# pushed from or deleted by the local side.
	to_build_host --delete --exclude packages/ --exclude '.throwaway-key/' --exclude '.git/' --exclude 'src/' --exclude 'pkg/' --exclude 'extract/' \
		"$REPO/" "$BUILD_HOST:$BUILD_DIR/"

	echo "[build.sh] building on $BUILD_HOST with a throwaway signing key (generated there and reused for this BUILD_DIR -- the real key stays here)"
	# KD persists at BUILD_DIR/.throwaway-key so a package built by an
	# earlier, separate scripts/build.sh call against this same BUILD_DIR
	# (e.g. tsx-xx60-boot-tools) is still signed with a key THIS call's
	# container trusts when it resolves that package as a build dep out of
	# packages/v3.24 (REPODEST) -- see the file header comment.
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

if [ "$TARGET" = --all ]; then
	PKGDIRS=$( (cd "$REPO" && find common xx60 -mindepth 1 -maxdepth 1 -type d) | sort)
else
	[ -f "$REPO/$TARGET/APKBUILD" ] || { echo "build.sh: no $REPO/$TARGET/APKBUILD" >&2; exit 1; }
	PKGDIRS="$TARGET"
fi

# want_build PKGDIR: 0 = build it, 1 = skip (says why).
want_build() {
	local info name ver rel url code cat n
	info=$(apkbuild_info "$1")
	read -r name ver rel <<<"$(echo "$info" | head -n1)"
	cat=${1%%/*}
	if [ "$SKIP_EXISTING" = 1 ]; then
		for n in "$REPO/packages/v3.24/$cat"/*/"$name-$ver-r$rel.apk"; do
			if [ -f "$n" ]; then
				echo "[build.sh] $1: $name-$ver-r$rel.apk already in packages/v3.24/$cat -- skipping"
				return 1
			fi
		done
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

for PKGDIR in $PKGDIRS; do
	want_build "$PKGDIR" || continue
	echo "=== building $PKGDIR ==="
	docker run --rm --platform linux/arm/v7 \
		-v "$REPO:/repo" \
		-v "$TSX_APORTS_KEY:/keys/$KEYNAME:ro" \
		-v "$TSX_APORTS_KEY.pub:/keys/$KEYNAME.pub:ro" \
		alpine:3.24 sh -euc "
			apk update >/dev/null
			# zstd: alpine-sdk's abuild does not pull it in, but its
			# unpack step needs the zstd binary for any .tar.zst
			# source (e.g. the xx60/tsx-xx60-kernel-FLAVOR bundles).
			apk add --no-cache alpine-sdk zstd >/dev/null
			cp /keys/$KEYNAME.pub /etc/apk/keys/
			# also trust this repo's own committed public key(s)
			# (common/tsx-keys/*.rsa.pub -- public, already part of the
			# pushed tree): a build dep resolved out of packages/v3.24
			# may carry the real project signature (e.g. a local build's
			# output staged in ahead of time) rather than this
			# container's own signing key, and should still verify.
			for k in /repo/common/tsx-keys/*.rsa.pub; do [ -f \"\$k\" ] && cp \"\$k\" /etc/apk/keys/; done
			mkdir -p /root/.abuild
			echo 'PACKAGER_PRIVKEY=/keys/$KEYNAME' > /root/.abuild/abuild.conf
			echo 'PACKAGER=\"unex <7575866+unex@users.noreply.github.com>\"' >> /root/.abuild/abuild.conf
			cd /repo/$PKGDIR
			abuild -F checksum
			abuild -F -r -P /repo/packages/v3.24
		"
done
echo "=== packages/v3.24 ==="
find "$REPO/packages/v3.24" -maxdepth 3 2>/dev/null || true
