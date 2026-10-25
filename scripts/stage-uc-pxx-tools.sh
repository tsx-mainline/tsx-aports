#!/bin/sh
# Pack the tools bundle of the uc-pxx recipes: uc-pxx-tools-bundle.tar.zst
# with the static aarch64 programs that abuild does not build.
#   uc-pxx-bootctl  the reviewed A/B tool (tools/uc-pxx-bootctl/build.sh of
#                   uc-pxx-linux). Its sha256 must be the pinned one of
#                   uc-pxx/uc-pxx-boot-tools/APKBUILD, or the script stops.
#   uc-pxx-reboot-syscall  tools/uc-pxx-reboot/build.sh of uc-pxx-linux (the
#                   program of the script uc-pxx-reboot)
#   rtl8363-init    tools/rtl8363-init/build.sh of uc-pxx-linux (it links
#                   with the GPL Realtek switch SDK)
#
#   scripts/stage-uc-pxx-tools.sh BOOTCTL REBOOT_SYSCALL RTL8363_INIT [NOTE]
#
# Nothing is compiled. Run the script where the programs are (the build
# host), in the copy of this repository that scripts/build.sh builds from
# (BUILD_DIR). NOTE is one line for SOURCE.txt in the bundle, for example the
# uc-pxx-linux commit of the programs. The script writes the bundle into the
# dist/ folder of each uc-pxx recipe that has it in sha512sums
# (uc-pxx-boot-tools, uc-pxx-board) and its sha512 into those recipes. Copy
# the APKBUILDs back to the workstation after it.
# The bundle is the asset of the tsx-aports release _tbundle_tag of these
# recipes (README.md "uc-pxx packages").
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
BOOTCTL=${1:?usage: stage-uc-pxx-tools.sh BOOTCTL REBOOT_SYSCALL RTL8363_INIT [NOTE]}
REBOOT=${2:?usage: stage-uc-pxx-tools.sh BOOTCTL REBOOT_SYSCALL RTL8363_INIT [NOTE]}
RTL=${3:?usage: stage-uc-pxx-tools.sh BOOTCTL REBOOT_SYSCALL RTL8363_INIT [NOTE]}
NOTE=${4:-}
BUNDLE=uc-pxx-tools-bundle.tar.zst
PIN=$(awk '$2 == "bundle:uc-pxx-bootctl" { print $1 }' "$TOP/uc-pxx/uc-pxx-boot-tools/APKBUILD")
[ ${#PIN} = 64 ] || { echo "stage-uc-pxx-tools.sh: no pin of uc-pxx-bootctl in uc-pxx-boot-tools/APKBUILD" >&2; exit 1; }
# a static aarch64 ELF: magic, 64-bit, little-endian, e_machine 183 (0xb7)
is_arm64() {
	[ "$(od -An -tx1 -N6 "$1" | tr -d ' \n')" = 7f454c460201 ] &&
		[ "$(od -An -tx1 -j18 -N2 "$1" | tr -d ' \n')" = b700 ]
}
for f in "$BOOTCTL" "$REBOOT" "$RTL"; do
	[ -f "$f" ] || { echo "stage-uc-pxx-tools.sh: no file $f" >&2; exit 1; }
	is_arm64 "$f" || { echo "stage-uc-pxx-tools.sh: $f is not an aarch64 ELF program" >&2; exit 1; }
done
GOT=$(sha256sum "$BOOTCTL" | cut -d' ' -f1)
[ "$GOT" = "$PIN" ] || { echo "stage-uc-pxx-tools.sh: $BOOTCTL has sha256 $GOT, the reviewed binary is $PIN. Not staged." >&2; exit 1; }
echo "uc-pxx-bootctl: sha256 $GOT (the reviewed binary)"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir "$W/b"
cp "$BOOTCTL" "$W/b/uc-pxx-bootctl"
cp "$REBOOT" "$W/b/uc-pxx-reboot-syscall"
cp "$RTL" "$W/b/rtl8363-init"
chmod 755 "$W/b/uc-pxx-bootctl" "$W/b/uc-pxx-reboot-syscall" "$W/b/rtl8363-init"
printf '%s\n' "${NOTE:-no note}" > "$W/b/SOURCE.txt"
(cd "$W/b" && sha256sum uc-pxx-bootctl uc-pxx-reboot-syscall rtl8363-init SOURCE.txt > CHECKSUMS.sha256)
cat "$W/b/CHECKSUMS.sha256"
# The same input gives the same bundle: names in order, fixed time and owner.
(cd "$W/b" && tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - \
	CHECKSUMS.sha256 SOURCE.txt rtl8363-init uc-pxx-bootctl uc-pxx-reboot-syscall) | zstd -q -19 > "$W/$BUNDLE"
SUM=$(sha512sum "$W/$BUNDLE" | cut -d' ' -f1)
for p in $(cd "$TOP/uc-pxx" && grep -l "^[0-9a-f]\{128\}  $BUNDLE\$" */APKBUILD | sed 's|/APKBUILD$||'); do
	mkdir -p "$TOP/uc-pxx/$p/dist"
	install -m 644 "$W/$BUNDLE" "$TOP/uc-pxx/$p/dist/$BUNDLE"
	sed -i "s/^[0-9a-f]\{128\}  $BUNDLE\$/$SUM  $BUNDLE/" "$TOP/uc-pxx/$p/APKBUILD"
	grep -q "^$SUM  $BUNDLE\$" "$TOP/uc-pxx/$p/APKBUILD" || { echo "stage-uc-pxx-tools.sh: no sha512sums line for $BUNDLE in $p" >&2; exit 1; }
done
echo "$SUM  $BUNDLE"
