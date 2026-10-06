#!/bin/sh
# Pin the kernel packages to the bundles of a tsx-xx60-linux release.
#
#   scripts/pin-kernel.sh TAG [lts|stable ...]
#   TAG  a tag of tsx-xx60-linux that started release.yml, for example v0.2.0
#
# For each flavor (default: both), the script does these steps:
#   1. It downloads tsx-xx60-kernel-<flavor>-bundle.tar.zst of the release
#      TAG. It also puts the file in dist/ of the package, so a local build
#      uses the same file as CI.
#   2. It checks CHECKSUMS.sha256 inside the bundle.
#   3. It checks that kernel.release starts with the kernel version of pkgver,
#      that kernel.commit matches the -g<hash> of kernel.release, and that the
#      modules tarball of that release is in the bundle.
#   4. It writes _kbundle_tag, _kernelrelease and the sha512 of the bundle
#      into the APKBUILD. It does not change pkgver or pkgrel. Set them first.
#      An apk version must rise, or `apk upgrade` does not take the package.
# The script stops at the first failed check and then changes no APKBUILD of
# the flavor that failed.
#
# PIN_BASE_URL replaces https://github.com/tsx-mainline/tsx-xx60-linux/releases/download
# (the tests use it with a local server).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TAG=${1:?usage: pin-kernel.sh TAG [lts|stable ...]}
shift
[ $# -gt 0 ] || set -- lts stable
BASE=${PIN_BASE_URL:-https://github.com/tsx-mainline/tsx-xx60-linux/releases/download}
die() { echo "pin-kernel.sh: $*" >&2; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
for F in "$@"; do
	case $F in lts|stable) ;; *) die "the flavor must be lts or stable (got $F)";; esac
	PKG="$HERE/../xx60/tsx-xx60-kernel-$F"
	[ -f "$PKG/APKBUILD" ] || die "no $PKG/APKBUILD"
	NAME=tsx-xx60-kernel-$F-bundle.tar.zst
	echo "== $F: $BASE/$TAG/$NAME"
	curl -fsSL -o "$T/$NAME" "$BASE/$TAG/$NAME" || die "cannot download the bundle of $F from the release $TAG"
	mkdir "$T/x-$F"
	tar --zstd -xf "$T/$NAME" -C "$T/x-$F" || die "cannot unpack the bundle of $F"
	(cd "$T/x-$F" && sha256sum -c --quiet CHECKSUMS.sha256) || die "CHECKSUMS.sha256 of the $F bundle does not match its files"
	REL=$(cat "$T/x-$F/kernel.release")
	COMMIT=$(cat "$T/x-$F/kernel.commit")
	PKGVER=$(sed -n 's/^pkgver=//p' "$PKG/APKBUILD")
	case $REL in "${PKGVER%%_*}"-[0-9]*-g[0-9a-f]*) ;; *) die "kernel.release $REL does not fit pkgver $PKGVER";; esac
	case $COMMIT in "${REL##*-g}"*) ;; *) die "kernel.commit $COMMIT does not match kernel.release $REL";; esac
	[ -f "$T/x-$F/modules-$REL.tar.gz" ] || die "the $F bundle has no modules-$REL.tar.gz"
	SUM=$(sha512sum "$T/$NAME" | cut -d' ' -f1)
	sed -i -e "s|^_kbundle_tag=.*|_kbundle_tag=$TAG|" \
		-e "s|^_kernelrelease=.*|_kernelrelease=$REL|" \
		-e "s|^[0-9a-f]*  $NAME\$|$SUM  $NAME|" "$PKG/APKBUILD"
	grep -q "^$SUM  $NAME\$" "$PKG/APKBUILD" || die "no sha512sums line for $NAME in the APKBUILD"
	mkdir -p "$PKG/dist"
	cp "$T/$NAME" "$PKG/dist/$NAME"
	echo "   kernel.release $REL"
	echo "   kernel.commit  $COMMIT"
	echo "   pinned: _kbundle_tag=$TAG, sha512 ${SUM%"${SUM#????????????}"}..."
done
