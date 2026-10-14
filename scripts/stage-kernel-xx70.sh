#!/bin/bash
# Stage the binary inputs of xx70/tsx-xx70-kernel-<flavor> from an already
# built kernel on the build host, pack them into
# tsx-xx70-kernel-<flavor>-bundle.tar.zst and update the APKBUILD of that
# package (pkgver, pkgrel, _kernelrelease, sha512sums).
#
# Nothing is compiled. The kernel and its modules must exist in
# BUILD_HOST_KDIR (arch/arm64/boot/Image.gz, the board DTBs, the .ko files).
# The script installs the built modules into a scratch tree (make
# modules_install, then depmod) and packs the boot_b image with
# kernel/mkimage.sh from Image.gz, the DTBs, lk2nd.img and the boot initramfs.
# The image holds the DTB of every board (all eight TSW-xx70 panel variants
# by default). lk2nd selects one by the board ID and the panel name.
#
# The bundle stays on the build host, in
# BUILD_DIR/xx70/tsx-xx70-kernel-<flavor>/dist/. scripts/build.sh (with
# BUILD_HOST and the same BUILD_DIR) builds the package there and does not
# delete that directory. Only the hash and the version come back here.
# Order: run this script, then scripts/build.sh xx70/tsx-xx70-kernel-<flavor>.
#
# The APKBUILD source= is a URL of a release. This script does not change
# that URL or _kbundle_tag. The APKBUILD sets SRCDEST=dist, so abuild uses
# the staged file and checks it with sha512sums= instead of fetching it.
#
#   scripts/stage-kernel-xx70.sh stable|lts
#
# Required environment (no defaults: this repository names no build host):
#   BUILD_HOST            ssh destination of the build host
#   BUILD_DIR             remote path this repository is mirrored to (the
#                         same value as for scripts/build.sh)
#   BUILD_HOST_KDIR       remote kernel build directory (O=) of this flavor
#   BUILD_HOST_LINUX_DIR  remote kernel source tree of this flavor
#   BUILD_HOST_LK2ND      remote path of lk2nd.img
#   BUILD_HOST_INITRAMFS  remote path of the boot initramfs (.cpio.gz)
#   BUILD_HOST_MKIMAGE    remote path of kernel/mkimage.sh (tsx-xx70-linux)
# Optional:
#   BUILD_HOST_CROSS      cross compiler prefix for modules_install
#                         (default aarch64-linux-gnu-)
#   DTB_NAMES             DTB file names, separated by spaces (default: the
#                         eight board DTBs, in the order of ci/build-kernel.sh
#                         of tsx-xx70-linux). All of them go into the boot_b
#                         image and into the bundle.
#   KERNEL_REV            expected commit of BUILD_HOST_LINUX_DIR (for
#                         example the line in tsx-xx70-linux
#                         kernel/KERNEL_REV.<flavor>). The script stops on a
#                         difference.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
FLAVOR=${1:?"usage: stage-kernel-xx70.sh stable|lts"}
case "$FLAVOR" in stable|lts) ;; *) echo "flavor must be 'stable' or 'lts'" >&2; exit 1;; esac

: "${BUILD_HOST:?set BUILD_HOST (ssh destination of the build host)}"
: "${BUILD_DIR:?set BUILD_DIR (remote path of this repository, as for build.sh)}"
: "${BUILD_HOST_KDIR:?set BUILD_HOST_KDIR (remote kernel build directory of $FLAVOR)}"
: "${BUILD_HOST_LINUX_DIR:?set BUILD_HOST_LINUX_DIR (remote kernel source tree of $FLAVOR)}"
: "${BUILD_HOST_LK2ND:?set BUILD_HOST_LK2ND (remote lk2nd.img)}"
: "${BUILD_HOST_INITRAMFS:?set BUILD_HOST_INITRAMFS (remote boot initramfs)}"
: "${BUILD_HOST_MKIMAGE:?set BUILD_HOST_MKIMAGE (remote kernel/mkimage.sh)}"
DTB_NAMES=${DTB_NAMES:-apq8053-crestron-tsw770.dtb apq8053-crestron-tsw1070.dtb
	apq8053-crestron-tsw570.dtb apq8053-crestron-tsw570-truly.dtb
	apq8053-crestron-tsw770-rev1.dtb apq8053-crestron-tsw770-truly.dtb
	apq8053-crestron-tsw1070-rev1.dtb apq8053-crestron-tsw1070-truly.dtb}
# one line with single spaces: the list goes into the ssh command lines below
# shellcheck disable=SC2086
DTB_NAMES=$(echo $DTB_NAMES)
CROSS=${BUILD_HOST_CROSS:-aarch64-linux-gnu-}

PKG=tsx-xx70-kernel-$FLAVOR
PKGDIR="$REPO/xx70/$PKG"
BUNDLE="$PKG-bundle.tar.zst"
APKBUILD="$PKGDIR/APKBUILD"
UPDATE_BOOT="$REPO/xx70/tsx-xx70-boot-tools/tsx-update-boot"
say() { echo "[stage-kernel-xx70:$FLAVOR] $*"; }

# The remote part. It reads its settings from the environment of the ssh
# command line below and prints "key=value" lines at the end.
REMOTE=$(cat <<'RSH'
set -eu
B=$BUILD_HOST_KDIR/arch/arm64/boot
DTBS=
for n in $DTB_NAMES; do DTBS="$DTBS $B/dts/qcom/$n"; done
[ -n "$DTBS" ] || { echo "DTB_NAMES is empty" >&2; exit 1; }
for f in "$B/Image.gz" $DTBS "$BUILD_HOST_LK2ND" "$BUILD_HOST_INITRAMFS" "$BUILD_HOST_MKIMAGE"; do
	[ -f "$f" ] || { echo "no such file on the build host: $f" >&2; exit 1; }
done
KREL=$(cat "$BUILD_HOST_KDIR/include/config/kernel.release")
KCOMMIT=$(git -C "$BUILD_HOST_LINUX_DIR" rev-parse HEAD)
if [ -n "${KERNEL_REV:-}" ] && [ "$KERNEL_REV" != "$KCOMMIT" ]; then
	echo "kernel source is at $KCOMMIT, expected $KERNEL_REV" >&2; exit 1
fi
DIST=$BUILD_DIR/xx70/$PKG/dist
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
rm -rf "$DIST"; mkdir -p "$DIST"

# modules: install the built .ko files (no compile) into a scratch tree
make -s -C "$BUILD_HOST_LINUX_DIR" O="$BUILD_HOST_KDIR" ARCH=arm64 CROSS_COMPILE="$CROSS" \
	INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH="$W/mods" modules_install >&2
rm -f "$W/mods/lib/modules/$KREL/build" "$W/mods/lib/modules/$KREL/source"
[ -f "$W/mods/lib/modules/$KREL/modules.dep" ] || { echo "no modules.dep for $KREL" >&2; exit 1; }
(cd "$W/mods" && tar --owner=0 --group=0 --numeric-owner -czf "$DIST/modules-$KREL.tar.gz" lib)

# the boot_b image
# shellcheck disable=SC2086 # one word per DTB path
sh "$BUILD_HOST_MKIMAGE" "$BUILD_HOST_LK2ND" "$B/Image.gz" $DTBS "$BUILD_HOST_INITRAMFS" "$DIST/tsx-xx70-boot.img" >&2
cp "$B/Image.gz" "$DIST/Image.gz"
for n in $DTB_NAMES; do cp "$B/dts/qcom/$n" "$DIST/$n"; done
echo "$KREL" > "$DIST/kernel.release"
echo "$KCOMMIT" > "$DIST/kernel.commit"
(cd "$DIST" && sha256sum Image.gz $DTB_NAMES "modules-$KREL.tar.gz" tsx-xx70-boot.img > CHECKSUMS.sha256)
echo "krel=$KREL"
echo "kcommit=$KCOMMIT"
echo "dist=$DIST"
RSH
)

say "staging on the build host (modules_install and mkimage.sh, no compile)"
OUT=$(ssh -o BatchMode=yes "$BUILD_HOST" env \
	BUILD_DIR="'$BUILD_DIR'" PKG="$PKG" BUILD_HOST_KDIR="'$BUILD_HOST_KDIR'" \
	BUILD_HOST_LINUX_DIR="'$BUILD_HOST_LINUX_DIR'" BUILD_HOST_LK2ND="'$BUILD_HOST_LK2ND'" \
	BUILD_HOST_INITRAMFS="'$BUILD_HOST_INITRAMFS'" BUILD_HOST_MKIMAGE="'$BUILD_HOST_MKIMAGE'" \
	DTB_NAMES="'$DTB_NAMES'" CROSS="$CROSS" KERNEL_REV="${KERNEL_REV:-}" bash -s <<<"$REMOTE")
KREL=$(sed -n 's/^krel=//p' <<<"$OUT")
KCOMMIT=$(sed -n 's/^kcommit=//p' <<<"$OUT")
RDIST=$(sed -n 's/^dist=//p' <<<"$OUT")
[ -n "$KREL" ] && [ -n "$RDIST" ] || { echo "the build host returned no kernel release" >&2; exit 1; }
say "kernel.release = $KREL"
say "kernel.commit = $KCOMMIT"

# The same check that tsx-update-boot makes on the panel, run on the host
# with the packaged script: layout, size and the crestron,tswxx70 DTB.
say "checking the boot_b image with tsx-update-boot --check"
ssh -o BatchMode=yes "$BUILD_HOST" "sh -s -- --check '$RDIST/tsx-xx70-boot.img'" < "$UPDATE_BOOT" ||
	{ echo "the boot_b image does not pass tsx-update-boot --check: not staged" >&2; exit 1; }

say "packing $BUNDLE on the build host"
ssh -o BatchMode=yes "$BUILD_HOST" "cd '$RDIST' && tar --owner=0 --group=0 --numeric-owner --zstd -cf '$BUNDLE' Image.gz $DTB_NAMES 'modules-$KREL.tar.gz' tsx-xx70-boot.img kernel.release kernel.commit CHECKSUMS.sha256 && ls -l '$BUNDLE'"
BUNDLESUM=$(ssh -o BatchMode=yes "$BUILD_HOST" "sha512sum '$RDIST/$BUNDLE'" | cut -d' ' -f1)
[ ${#BUNDLESUM} = 128 ] || { echo "no sha512 from the build host" >&2; exit 1; }

# pkgver: <upstream version>_git<YYYYMMDD>; pkgrel goes up when a new bundle
# is staged on the same day (a new kernel release, or the same kernel with a
# new lk2nd or initramfs in the boot_b image), and restarts at 0 for a new
# pkgver.
BASEVER=${KREL%%-*}
PKGVER="${BASEVER}_git$(date +%Y%m%d)"
OLDVER=$(sed -n 's/^pkgver=//p' "$APKBUILD")
OLDREL=$(sed -n 's/^pkgrel=//p' "$APKBUILD")
OLDKREL=$(sed -n 's/^_kernelrelease=//p' "$APKBUILD")
OLDSUM=$(sed -n "s/^\([0-9a-f]\{128\}\)  $BUNDLE\$/\1/p" "$APKBUILD")
if [ "$OLDVER" != "$PKGVER" ]; then PKGREL=0
elif [ "$OLDKREL" != "$KREL" ] || [ "$OLDSUM" != "$BUNDLESUM" ]; then PKGREL=$((OLDREL + 1))
else PKGREL=$OLDREL; fi
say "pkgver=$PKGVER pkgrel=$PKGREL (was $OLDVER-r$OLDREL, $OLDKREL)"
sed -i \
	-e "s/^pkgver=.*/pkgver=$PKGVER/" \
	-e "s/^pkgrel=.*/pkgrel=$PKGREL/" \
	-e "s/^_kernelrelease=.*/_kernelrelease=$KREL/" \
	"$APKBUILD"
python3 - "$APKBUILD" "$BUNDLESUM" "$BUNDLE" <<'PY'
import re, sys
path, bsum, bundle = sys.argv[1:4]
text = open(path).read()
text = re.sub(r'sha512sums="[^"]*"\n', f'sha512sums="\n{bsum}  {bundle}\n"\n', text, flags=re.S)
open(path, "w").write(text)
PY
say "updated $APKBUILD"
say "done. Build with: BUILD_HOST=<host> BUILD_DIR=$BUILD_DIR scripts/build.sh xx70/$PKG"
