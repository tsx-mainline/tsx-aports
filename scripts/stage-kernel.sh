#!/bin/bash
# Stage the binary inputs for xx60/tsx-xx60-kernel-<flavor> from a kernel that
# is already built on a build host. The script packs them into the bundle
# tsx-xx60-kernel-<flavor>-bundle.tar.zst. This is the format that the job
# "kbundle" in .github/workflows/release.yml of tsx-xx60-linux publishes as a
# release asset. It then updates pkgver and sha512sums in the APKBUILD of the
# package.
# The script does NOT compile anything. The kernel and its modules must
# already exist in BUILD_HOST_KDIR: zImage, the board DTB, and the .ko files.
# The script runs `make modules_install`. This installs the built .ko files
# into a tree and runs depmod. It starts the compiler only if a file is stale.
# With --pack-boot, the script runs kernel/mkimage.sh. This packs an Android
# boot image from the zImage, the DTB, and an initramfs, and does not compile.
# If the kernel build has a TSW-760 DTB (kernels with
# meson8m2-crestron-tsw760.dts), --pack-boot packs both board DTBs into the
# vendor AML_ multi-DTB container (mkimage.sh --board-dtbs). The one image
# then boots the TSW-1060 and the TSW-760, and the bundle has both DTBs.
# Before it packs anything, the script checks each boot image (packed or
# fetched) with scripts/check-bootimg-dtbs.py against the DTBs of the kernel.
# It refuses a fetched image that has no container when the kernel has the
# TSW-760 DTB.
#
# The source= of the APKBUILD is a URL (a tagged tsx-xx60-linux release). The
# script does not change this URL or _kbundle_tag. It changes only the local
# file dist/<bundle>.tar.zst (named like the basename of the URL) and
# sha512sums= (one line, for that one file). The APKBUILD sets SRCDEST=dist.
# So `abuild checksum` and scripts/build.sh find this local file and verify it.
# They do not fetch the release, which can have no tag yet. This is what
# "local build of an unreleased kernel" means here.
#
#   scripts/stage-kernel.sh stable|lts [--pack-boot]
#
# Required environment (no defaults, because this repo names no build host):
#   BUILD_HOST            ssh destination of the build host
#   BUILD_HOST_KDIR       remote kbuild output directory for this flavor
#                         (has arch/arm/boot/zImage,
#                          arch/arm/boot/dts/amlogic/*.dtb,
#                          include/config/kernel.release)
#   BUILD_HOST_LINUX_DIR  remote kernel source checkout that matches
#                         BUILD_HOST_KDIR (the source tree for modules_install)
#
# For the boot image, set one of these:
#   BUILD_HOST_BOOTIMG    remote path to an already-packed tsxboot-emmc.img
#                         for this flavor (skips the packing)
#   --pack-boot, with these variables:
#   BUILD_HOST_INITRAMFS  remote path to initramfs-switchroot.cpio.gz
#   BUILD_HOST_MKIMAGE    remote path to kernel/mkimage.sh (tsx-xx60-linux).
#                         Use a version with --board-dtbs when the kernel has
#                         the TSW-760 DTB.
#
# Optional:
#   BUILD_HOST_DOCKER_IMG cross-toolchain docker image on the host. It is used
#                         for modules_install (needs the ARM strip) and for
#                         mkimage.sh (needs python3 and the DT/image tools).
#                         The default is tsx-mainline.
#   DTB_NAME              file name of the TSW-1060 device tree blob (default
#                         meson8m2-crestron-tsw1060.dtb)
#   DTB760_NAME           file name of the TSW-760 device tree blob (default
#                         meson8m2-crestron-tsw760.dtb). The script uses it
#                         when the kernel build has it.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
FLAVOR=${1:?"usage: stage-kernel.sh stable|lts [--pack-boot]"}
PACK_BOOT=0; [ "${2:-}" = --pack-boot ] && PACK_BOOT=1
case "$FLAVOR" in stable|lts) ;; *) echo "flavor must be 'stable' or 'lts'" >&2; exit 1;; esac

: "${BUILD_HOST:?set BUILD_HOST (ssh destination of the build host)}"
: "${BUILD_HOST_KDIR:?set BUILD_HOST_KDIR (remote kbuild output dir for $FLAVOR)}"
: "${BUILD_HOST_LINUX_DIR:?set BUILD_HOST_LINUX_DIR (remote kernel source checkout for $FLAVOR)}"
DTB_NAME=${DTB_NAME:-meson8m2-crestron-tsw1060.dtb}
DTB760_NAME=${DTB760_NAME:-meson8m2-crestron-tsw760.dtb}
DOCKER_IMG=${BUILD_HOST_DOCKER_IMG:-tsx-mainline}
if [ -z "${BUILD_HOST_BOOTIMG:-}" ] && [ "$PACK_BOOT" != 1 ]; then
	echo "set BUILD_HOST_BOOTIMG (an already-packed image) or pass --pack-boot" >&2; exit 1
fi
if [ "$PACK_BOOT" = 1 ]; then
	: "${BUILD_HOST_INITRAMFS:?--pack-boot needs BUILD_HOST_INITRAMFS}"
	: "${BUILD_HOST_MKIMAGE:?--pack-boot needs BUILD_HOST_MKIMAGE}"
fi

PKGDIR="$REPO/xx60/tsx-xx60-kernel-$FLAVOR"
DIST="$PKGDIR/dist"
mkdir -p "$DIST"
say() { echo "[stage-kernel:$FLAVOR] $*"; }

ssh_do() { ssh -o BatchMode=yes "$BUILD_HOST" "$@"; }

KREL=$(ssh_do "cat '$BUILD_HOST_KDIR/include/config/kernel.release'")
[ -n "$KREL" ] || { echo "could not read kernel.release from $BUILD_HOST_KDIR" >&2; exit 1; }
say "kernel.release = $KREL"
echo "$KREL" > "$DIST/kernel.release"

KCOMMIT=$(ssh_do "git -C '$BUILD_HOST_LINUX_DIR' rev-parse HEAD")
[ -n "$KCOMMIT" ] || { echo "could not read HEAD commit from $BUILD_HOST_LINUX_DIR" >&2; exit 1; }
say "kernel.commit = $KCOMMIT"
echo "$KCOMMIT" > "$DIST/kernel.commit"

RDTB=$BUILD_HOST_KDIR/arch/arm/boot/dts/amlogic
DTBS="$DTB_NAME"
ssh_do "test -f '$RDTB/$DTB760_NAME'" && DTBS="$DTBS $DTB760_NAME"
say "fetching zImage + $DTBS"
rsync -a "$BUILD_HOST:$BUILD_HOST_KDIR/arch/arm/boot/zImage" "$DIST/zImage"
rm -f "$DIST/$DTB760_NAME"
for d in $DTBS; do rsync -a "$BUILD_HOST:$RDTB/$d" "$DIST/$d"; done

say "modules_install (already-built .ko's; no compile) into a remote scratch tree"
RSTAGE="/tmp/tsx-aports-stage-$FLAVOR-mods.$$"
ssh_do "mkdir -p '$RSTAGE' && docker run --rm -u \$(id -u):\$(id -g) \
	-v '$BUILD_HOST_LINUX_DIR':'$BUILD_HOST_LINUX_DIR' \
	-v '$BUILD_HOST_KDIR':'$BUILD_HOST_KDIR' -v '$RSTAGE':'$RSTAGE' \
	$DOCKER_IMG make -C '$BUILD_HOST_LINUX_DIR' O='$BUILD_HOST_KDIR' ARCH=arm \
	CROSS_COMPILE=arm-linux-gnueabihf- INSTALL_MOD_PATH='$RSTAGE' INSTALL_MOD_STRIP=1 \
	modules_install -j\$(nproc) && cd '$RSTAGE' && tar czf '$RSTAGE.tar.gz' lib/modules"
rsync -a "$BUILD_HOST:$RSTAGE.tar.gz" "$DIST/modules-$KREL.tar.gz"
ssh_do "rm -rf '$RSTAGE' '$RSTAGE.tar.gz'"

if [ -n "${BUILD_HOST_BOOTIMG:-}" ]; then
	say "fetching already-packed boot image $BUILD_HOST_BOOTIMG"
	rsync -a "$BUILD_HOST:$BUILD_HOST_BOOTIMG" "$DIST/tsxboot-emmc.img"
else
	RBOOT="/tmp/tsx-aports-stage-$FLAVOR-boot.$$"
	if [ "$DTBS" = "$DTB_NAME" ]; then
		DTBARG="--dtb '$RDTB/$DTB_NAME'"
	else
		# mkimage.sh --board-dtbs needs the two DTBs in one directory, with their build names
		ssh_do "mkdir -p '$RBOOT/dtbs' && cp '$RDTB/$DTB_NAME' '$RBOOT/dtbs/meson8m2-crestron-tsw1060.dtb' && cp '$RDTB/$DTB760_NAME' '$RBOOT/dtbs/meson8m2-crestron-tsw760.dtb'"
		DTBARG="--board-dtbs '$RBOOT/dtbs'"
	fi
	say "packing a new boot image (mkimage.sh, no compile) from zImage + $DTBS + the switchroot initramfs"
	ssh_do "mkdir -p '$RBOOT' && docker run --rm -u \$(id -u):\$(id -g) \
		-v '$BUILD_HOST_KDIR':'$BUILD_HOST_KDIR' -v '$(dirname "$BUILD_HOST_MKIMAGE")':'$(dirname "$BUILD_HOST_MKIMAGE")' \
		-v '$(dirname "$BUILD_HOST_INITRAMFS")':'$(dirname "$BUILD_HOST_INITRAMFS")' -v '$RBOOT':'$RBOOT' \
		$DOCKER_IMG '$BUILD_HOST_MKIMAGE' --kernel '$BUILD_HOST_KDIR/arch/arm/boot/zImage' \
		$DTBARG \
		--initrd '$BUILD_HOST_INITRAMFS' --out '$RBOOT/tsxboot-emmc.img'"
	rsync -a "$BUILD_HOST:$RBOOT/tsxboot-emmc.img" "$DIST/tsxboot-emmc.img"
	ssh_do "rm -rf '$RBOOT'"
fi

say "boot image DTBs"
CHK=$(mktemp -d); trap 'rm -rf "$CHK"' EXIT
for d in $DTBS; do cp "$DIST/$d" "$CHK/"; done
[ "$DTB_NAME" = meson8m2-crestron-tsw1060.dtb ] || mv "$CHK/$DTB_NAME" "$CHK/meson8m2-crestron-tsw1060.dtb"
[ "$DTB760_NAME" = meson8m2-crestron-tsw760.dtb ] || [ ! -f "$CHK/$DTB760_NAME" ] || mv "$CHK/$DTB760_NAME" "$CHK/meson8m2-crestron-tsw760.dtb"
python3 "$HERE/check-bootimg-dtbs.py" "$DIST/tsxboot-emmc.img" "$CHK" || {
	echo "the boot image does not carry this kernel's board DTBs (a TSW-760 needs mkimage.sh --board-dtbs): not staged" >&2; exit 1; }

say "checksums"
(cd "$DIST" && sha256sum zImage $DTBS "modules-$KREL.tar.gz" tsxboot-emmc.img > CHECKSUMS.sha256)
cat "$DIST/CHECKSUMS.sha256"

# --- pack the bundle (same layout and name as the "kbundle" CI job) ---
BUNDLE="tsx-xx60-kernel-$FLAVOR-bundle.tar.zst"
say "packing $BUNDLE"
tar --zstd -cf "$DIST/$BUNDLE" -C "$DIST" \
	zImage $DTBS "modules-$KREL.tar.gz" tsxboot-emmc.img \
	kernel.release kernel.commit CHECKSUMS.sha256
ls -l "$DIST/$BUNDLE"

# --- derive pkgver from the kernelrelease and rewrite the APKBUILD ---
# Scheme: pkgver = <upstream version>_git<YYYYMMDD>. <upstream version> is
# the dotted release (for example 7.2.8 or 6.18.54). The script takes it from
# kernel.release, up to the first '-'. The date is today, the day of staging.
# The exact commit is in dist/kernel.release and dist/kernel.commit.
# An apk pkgver cannot contain '-'. For this reason, a date suffix replaces
# the "-NNNNN-gHASH" suffix of git describe. The two files record the exact
# commit for anyone who must reproduce this package. This is build
# provenance and not runtime state, so no file on the panel has it.
BASEVER=${KREL%%-*}
PKGVER="${BASEVER}_git$(date +%Y%m%d)"
say "derived pkgver=$PKGVER (from kernel.release $KREL)"

APKBUILD="$PKGDIR/APKBUILD"
# pkgrel: a new kernel release that you stage on the same day has the same
# pkgver, and apk upgrades only to a higher version. In that case, increase
# pkgrel. A new pkgver starts again at pkgrel 0. If you stage the same
# release again, pkgver and pkgrel stay the same.
OLDVER=$(sed -n 's/^pkgver=//p' "$APKBUILD")
OLDREL=$(sed -n 's/^pkgrel=//p' "$APKBUILD")
OLDKREL=$(sed -n 's/^_kernelrelease=//p' "$APKBUILD")
if [ "$OLDVER" != "$PKGVER" ]; then
	PKGREL=0
elif [ "$OLDKREL" != "$KREL" ]; then
	PKGREL=$((OLDREL + 1))
else
	PKGREL=$OLDREL
fi
say "pkgrel=$PKGREL (was $OLDVER-r$OLDREL, $OLDKREL)"
BUNDLESUM=$(sha512sum "$DIST/$BUNDLE" | cut -d' ' -f1)
sed -i \
	-e "s/^pkgver=.*/pkgver=$PKGVER/" \
	-e "s/^pkgrel=.*/pkgrel=$PKGREL/" \
	-e "s/^_kernelrelease=.*/_kernelrelease=$KREL/" \
	"$APKBUILD"
python3 - "$APKBUILD" "$BUNDLESUM" "$BUNDLE" <<'PY'
import re, sys
path, bsum, bundle = sys.argv[1:4]
text = open(path).read()
block = f'sha512sums="\n{bsum}  {bundle}\n"\n'
text = re.sub(r'sha512sums="[^"]*"\n', block, text, flags=re.S)
open(path, "w").write(text)
PY
say "updated $APKBUILD (pkgver=$PKGVER, pkgrel=$PKGREL, sha512sums refreshed for $BUNDLE)"
say "_kbundle_tag is NOT touched -- it only matters for a networked (CI) build;"
say "this staged dist/$BUNDLE satisfies a local build via SRCDEST regardless of its value"
say "done. Build with: scripts/build.sh xx60/tsx-xx60-kernel-$FLAVOR"
