#!/bin/bash
# Stage the binary inputs for xx60/tsx-xx60-kernel-<flavor> from an already
# built kernel on a build host, pack them into the same
# tsx-xx60-kernel-<flavor>-bundle.tar.zst format tsx-xx60-linux's
# .github/workflows/release.yml (job "kbundle") publishes as a release
# asset, and update that package's APKBUILD (pkgver + sha512sums) to match.
# This does NOT compile anything: the kernel and its modules must already
# be built (zImage, the board DTB and the .ko files all present in
# BUILD_HOST_KDIR); this script only runs `make modules_install`
# (installs already-built .ko's into a tree + depmod, no compiler invoked
# unless something is actually stale) and, with --pack-boot, kernel/mkimage.sh
# (packs an Android boot image from the zImage + DTB + an initramfs --
# again no compilation). With a TSW-760 DTB in the kernel build (kernels with
# meson8m2-crestron-tsw760.dts), --pack-boot packs both board DTBs into the
# vendor AML_ multi-DTB container (mkimage.sh --board-dtbs), so the one image
# boots the TSW-1060 and the TSW-760; the bundle carries both DTBs. Every boot
# image (packed or fetched) is checked with scripts/check-bootimg-dtbs.py
# against the kernel's DTBs before anything is packed: a fetched image
# without the container is refused when the kernel has the TSW-760 DTB.
#
# The APKBUILD's source= is a URL (a tagged tsx-xx60-linux release); this
# script does not touch that URL or its _kbundle_tag, only the local
# dist/<bundle>.tar.zst (named to match the URL's basename) and
# sha512sums= (a single line, for that one file). The APKBUILD sets
# SRCDEST=dist, so `abuild checksum`/`scripts/build.sh` finds this local
# file and verifies it instead of fetching the (possibly not-yet-tagged)
# release -- that is what "local build of an unreleased kernel" means here.
#
#   scripts/stage-kernel.sh stable|lts [--pack-boot]
#
# Required env (no defaults on purpose: this repo names no build host):
#   BUILD_HOST            ssh destination of the build host
#   BUILD_HOST_KDIR       remote kbuild output dir for this flavor
#                         (has arch/arm/boot/zImage, arch/arm/boot/dts/amlogic/*.dtb,
#                          include/config/kernel.release)
#   BUILD_HOST_LINUX_DIR  remote kernel source checkout matching BUILD_HOST_KDIR
#                         (the -o/O= source tree for modules_install)
#
# One of, for the boot image:
#   BUILD_HOST_BOOTIMG    remote path to an already-packed tsxboot-emmc.img
#                         for this flavor (skips packing)
#   --pack-boot with:
#   BUILD_HOST_INITRAMFS  remote path to initramfs-switchroot.cpio.gz
#   BUILD_HOST_MKIMAGE    remote path to kernel/mkimage.sh (tsx-xx60-linux; a
#                         version with --board-dtbs when the kernel has the
#                         TSW-760 DTB)
#
# Optional:
#   BUILD_HOST_DOCKER_IMG cross-toolchain docker image on the host, used for
#                         modules_install (needs the ARM strip) and mkimage.sh
#                         (needs python3 + the DT/image tools) (default tsx-mainline)
#   DTB_NAME              TSW-1060 device tree blob file name (default
#                         meson8m2-crestron-tsw1060.dtb)
#   DTB760_NAME           TSW-760 device tree blob file name (default
#                         meson8m2-crestron-tsw760.dtb); used when the kernel
#                         build has it
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
		# mkimage.sh --board-dtbs wants the two DTBs under their build names in one dir
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

# --- pack the bundle (same layout+name the "kbundle" CI job publishes) ---
BUNDLE="tsx-xx60-kernel-$FLAVOR-bundle.tar.zst"
say "packing $BUNDLE"
tar --zstd -cf "$DIST/$BUNDLE" -C "$DIST" \
	zImage $DTBS "modules-$KREL.tar.gz" tsxboot-emmc.img \
	kernel.release kernel.commit CHECKSUMS.sha256
ls -l "$DIST/$BUNDLE"

# --- derive pkgver from the kernelrelease and rewrite the APKBUILD --------
# Scheme: pkgver = <upstream version>_git<YYYYMMDD>, where <upstream version>
# is the dotted release (e.g. 7.2.8, 6.18.54) taken from kernel.release up to
# the first '-', and the date is today (the day this was staged, i.e. the day
# of the commit count + hash that kernel.release also carries -- see
# dist/kernel.release and dist/kernel.commit for the exact commit).
# apk pkgver may not contain '-', hence the switch to a date suffix instead
# of the "-NNNNN-gHASH" git-describe suffix; the exact commit is recorded in
# dist/kernel.release / dist/kernel.commit (shipped nowhere on the panel --
# it is build provenance, not runtime state) for anyone who needs to
# reproduce this exact package.
BASEVER=${KREL%%-*}
PKGVER="${BASEVER}_git$(date +%Y%m%d)"
say "derived pkgver=$PKGVER (from kernel.release $KREL)"

APKBUILD="$PKGDIR/APKBUILD"
# pkgrel: a new kernel release staged on the same day keeps the same pkgver,
# and apk only upgrades to a higher version -- bump pkgrel then. A new
# pkgver starts again at pkgrel 0. Re-staging the same release keeps both.
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
