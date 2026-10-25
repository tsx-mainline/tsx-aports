#!/bin/bash
# Stage the bundle of uc-pxx/uc-pxx-kernel-lts from an already built kernel:
# uc-pxx-kernel-lts-bundle.tar.zst in the dist/ folder of the recipe. Then
# update the recipe (pkgver, pkgrel, _kernelrelease, _kbundle_tag,
# sha512sums).
#
#   scripts/stage-kernel-uc-pxx.sh KOUT UC_PXX_LINUX
#   KOUT          the --out folder of ci/build-kernel.sh of uc-pxx-linux:
#                 Image, rk3399-crestron-ucp10.dtb, rk3399-crestron-ucp8.dtb,
#                 kernel.release, kernel.commit, modules-<release>.tar.gz and
#                 sha256sums.txt
#   UC_PXX_LINUX  a checkout of uc-pxx-linux (or an archive of one commit)
#                 whose kernel/KERNEL_REV.lts is the commit of the kernel. Its
#                 kernel/mkimage.sh makes the boot images.
#
# Nothing is compiled except the shim of kernel/mkimage.sh. Run the script on
# the build host (it needs aarch64-linux-gnu-gcc, mkbootimg, fdtget, fdtput
# and python3), in the copy of this repository that scripts/build.sh builds
# from (BUILD_DIR). Copy the APKBUILD back to the workstation after it.
#
# The boot images have an EMPTY resource (kernel/mkimage.sh --resource with an
# empty file). The resource for U-Boot derives from vendor files, so no
# bundle and no package holds it. uc-pxx-update-boot on the panel puts the
# resource of the unit into the image before it writes boot_a. The script
# stops when kernel/mkimage.sh is not the reviewed file (MKIMAGE_SHA256).
# Each run makes a new random build token. The token goes into the header
# name field and into the kernel command line (uc-pxx.id=), and the
# boot-marking hook compares the two. UC_PXX_TOKEN sets the token (tests only).
#
# pkgver is <upstream version>_git<YYYYMMDD> of today. pkgrel goes up when a
# new bundle is staged on the same day and restarts at 0 for a new pkgver.
# _kbundle_tag becomes uc-pxx-kernel-<YYYYMMDD>, the tsx-aports release that
# must hold this exact bundle.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
KOUT=${1:?usage: stage-kernel-uc-pxx.sh KOUT UC_PXX_LINUX}
SRC=${2:?usage: stage-kernel-uc-pxx.sh KOUT UC_PXX_LINUX}
# kernel/mkimage.sh of uc-pxx-linux as reviewed with the boot control (it
# writes the build token)
MKIMAGE_SHA256=98ef579ce1f152463c8902c53c2f2f8edfbdfd6b8a0d40d650c59844d893703f
PKGDIR=$REPO/uc-pxx/uc-pxx-kernel-lts
APKBUILD=$PKGDIR/APKBUILD
BUNDLE=uc-pxx-kernel-lts-bundle.tar.zst
TOOL=$REPO/uc-pxx/uc-pxx-boot-tools/uc-pxx-update-boot
say() { echo "[stage-kernel-uc-pxx] $*"; }
die() { echo "stage-kernel-uc-pxx: $*" >&2; exit 1; }

for f in Image rk3399-crestron-ucp10.dtb rk3399-crestron-ucp8.dtb kernel.release kernel.commit sha256sums.txt; do
	[ -f "$KOUT/$f" ] || die "no $KOUT/$f"
done
KREL=$(cat "$KOUT/kernel.release")
KCOMMIT=$(cat "$KOUT/kernel.commit")
[ -f "$KOUT/modules-$KREL.tar.gz" ] || die "no $KOUT/modules-$KREL.tar.gz"
(cd "$KOUT" && sha256sum -c --quiet sha256sums.txt) || die "$KOUT does not match its sha256sums.txt"
PIN=$(grep -v '^#' "$SRC/kernel/KERNEL_REV.lts" | head -n 1 | tr -d ' \n')
[ "$PIN" = "$KCOMMIT" ] || die "the kernel is $KCOMMIT, kernel/KERNEL_REV.lts of $SRC pins $PIN"
GOT=$(sha256sum "$SRC/kernel/mkimage.sh" | cut -d' ' -f1)
[ "$GOT" = "$MKIMAGE_SHA256" ] || die "$SRC/kernel/mkimage.sh has sha256 $GOT, the reviewed file is $MKIMAGE_SHA256"
TOKEN=${UC_PXX_TOKEN:-ucpxx-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')}
say "kernel $KREL ($KCOMMIT), token $TOKEN"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir "$W/b"
: > "$W/empty.res"
for m in ucp10 ucp8; do
	bash "$SRC/kernel/mkimage.sh" --resource "$W/empty.res" --board "$TOKEN" \
		"$KOUT/Image" "$KOUT/rk3399-crestron-$m.dtb" "$W/b/uc-pxx-$m-lts.img"
	info=$(python3 -I "$TOOL" inspect "$W/b/uc-pxx-$m-lts.img") || die "uc-pxx-$m-lts.img fails the check of uc-pxx-update-boot"
	want="crestron,uc-p${m#ucp}"
	grep -qx "token=$TOKEN" <<<"$info" && grep -qx "model=$want" <<<"$info" && grep -qx "release=$KREL" <<<"$info" ||
		die "uc-pxx-$m-lts.img: $info (expected $TOKEN, $want, $KREL)"
	say "uc-pxx-$m-lts.img: $want, $(stat -c %s "$W/b/uc-pxx-$m-lts.img") bytes"
done
cp "$KOUT/rk3399-crestron-ucp10.dtb" "$KOUT/rk3399-crestron-ucp8.dtb" "$KOUT/modules-$KREL.tar.gz" \
	"$KOUT/kernel.release" "$KOUT/kernel.commit" "$W/b/"
echo "$TOKEN" > "$W/b/token.txt"
FILES="uc-pxx-ucp10-lts.img uc-pxx-ucp8-lts.img rk3399-crestron-ucp10.dtb rk3399-crestron-ucp8.dtb modules-$KREL.tar.gz kernel.release kernel.commit token.txt"
# shellcheck disable=SC2086 # one word per file
(cd "$W/b" && sha256sum $FILES > CHECKSUMS.sha256)
# shellcheck disable=SC2086
(cd "$W/b" && tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - CHECKSUMS.sha256 $FILES) |
	zstd -q -19 -T0 > "$W/$BUNDLE"
mkdir -p "$PKGDIR/dist"
install -m 644 "$W/$BUNDLE" "$PKGDIR/dist/$BUNDLE"
SUM=$(sha512sum "$PKGDIR/dist/$BUNDLE" | cut -d' ' -f1)

BASEVER=${KREL%%-*}
DATE=$(date +%Y%m%d)
PKGVER=${BASEVER}_git$DATE
OLDVER=$(sed -n 's/^pkgver=//p' "$APKBUILD")
OLDREL=$(sed -n 's/^pkgrel=//p' "$APKBUILD")
OLDKREL=$(sed -n 's/^_kernelrelease=//p' "$APKBUILD")
OLDSUM=$(sed -n "s/^\([0-9a-f]\{128\}\)  $BUNDLE\$/\1/p" "$APKBUILD")
if [ "$OLDVER" != "$PKGVER" ]; then PKGREL=0
elif [ "$OLDKREL" != "$KREL" ] || [ "$OLDSUM" != "$SUM" ]; then PKGREL=$((OLDREL + 1))
else PKGREL=$OLDREL; fi
sed -i \
	-e "s/^pkgver=.*/pkgver=$PKGVER/" \
	-e "s/^pkgrel=.*/pkgrel=$PKGREL/" \
	-e "s/^_kernelrelease=.*/_kernelrelease=$KREL/" \
	-e "s/^_kbundle_tag=.*/_kbundle_tag=uc-pxx-kernel-$DATE/" \
	-e "s/^[0-9a-f]\{128\}  $BUNDLE\$/$SUM  $BUNDLE/" \
	"$APKBUILD"
grep -q "^$SUM  $BUNDLE\$" "$APKBUILD" || die "no sha512sums line for $BUNDLE in $APKBUILD"
say "pkgver=$PKGVER pkgrel=$PKGREL (was $OLDVER-r$OLDREL, $OLDKREL), _kbundle_tag=uc-pxx-kernel-$DATE"
say "bundle $(stat -c %s "$PKGDIR/dist/$BUNDLE") bytes, sha512 ${SUM:0:16}..."
say "done. Build with scripts/build.sh uc-pxx/uc-pxx-kernel-lts"
