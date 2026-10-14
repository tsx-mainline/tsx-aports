#!/bin/bash
# Host test of xx70/tsx-xx70-boot-tools: tsx-kernel-flavor and tsx-update-boot
# against a fake sysfs and a file in place of boot_b. Writes nothing outside
# a temporary directory. No build host and no docker needed.
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
BT=$REPO/xx70/tsx-xx70-boot-tools
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

mkdir -p "$T/sys/mmcblk0p20" "$T/sys/mmcblk0p29" "$T/dev" "$T/data" "$T/boot" "$T/share" "$T/lib"
printf 'PARTNAME=boot_b\n' > "$T/sys/mmcblk0p20/uevent"
echo 1052672 > "$T/sys/mmcblk0p20/start"; echo 131072 > "$T/sys/mmcblk0p20/size"
printf 'PARTNAME=system_b\n' > "$T/sys/mmcblk0p29/uevent"
truncate -s 64M "$T/dev/mmcblk0p20"
# an image: lk2nd part, then an Android boot image with the board compatible
mkimg() {  # mkimg OUT TAG
	{ printf 'ANDROID!'; head -c 524280 /dev/zero; printf 'ANDROID!%s' "$2"; printf 'crestron,tswxx70\0'; } > "$1"
}
mkimg "$T/boot/tsx-xx70-lts.img" lts
mkimg "$T/boot/tsx-xx70-stable.img" stable
echo 6.18.54-00067-gaaaa > "$T/share/kernel-lts.release"
echo 7.2.8-00063-gbbbb > "$T/share/kernel-stable.release"
# the real detection needs a real panel: the test says "installed"
printf 'tsx_is_installed_panel() { return 0; }\ntsx_part_name() { for u in "$TSX_SYSBLOCK"/mmcblk*p*/uevent; do grep -qx "PARTNAME=$1" "$u" && { d=${u%%/uevent}; echo "${d##*/}"; return 0; }; done; return 1; }\n' > "$T/lib/tsx-is-panel.sh"

export TSX_LIBDIR=$T/lib TSX_BOOTDIR=$T/boot TSX_SHAREDIR=$T/share TSX_SYSBLOCK=$T/sys TSX_DEVDIR=$T/dev \
	TSX_DATA=$T/data TSX_NO_MOUNTCHECK=1
export TSX_UPDATE_BOOT=$BT/tsx-update-boot
KF=$BT/tsx-kernel-flavor

# 0. only lts installed, the panel runs stable, no KERNEL_FLAVOR: no flavor
#    is selected and the lts hook must not change the panel to lts
mv "$T/share/kernel-stable.release" "$T/stable.release"
out=$(TSX_UNAME_R=7.2.8-00078-gcccc sh "$KF" | head -1)
case $out in *"selected: none"*) ok "stable running, only lts installed: none selected";; *) bad "selected: $out";; esac
out=$(TSX_UNAME_R=7.2.8-00078-gcccc sh "$KF" --hook lts)
echo "$out" | grep -q 'nothing written' && [ -z "$(head -c 8 "$T/dev/mmcblk0p20" | tr -d '\0')" ] &&
	ok "lts hook on a stable panel: nothing written" || bad "lts hook on a stable panel: $out"
mv "$T/stable.release" "$T/share/kernel-stable.release"

# 1. the running kernel has the lts series: lts is selected
export TSX_UNAME_R=6.18.54-00082-gdddd
out=$(sh "$KF" | head -1)
case $out in *lts) ok "running 6.18: lts selected";; *) bad "running 6.18: $out";; esac
out=$(TSX_UNAME_R=7.2.8-00078-gcccc sh "$KF" | head -1)
case $out in *stable) ok "running 7.2: stable selected";; *) bad "running 7.2: $out";; esac

# 2. the hook of the selected flavor writes boot_b and keeps the old image
out=$(sh "$KF" --hook lts)
echo "$out" | grep -q 'reboot to use the lts kernel' && ok "hook writes the selected flavor" || bad "hook write: $out"
cmp -n "$(stat -c %s "$T/boot/tsx-xx70-lts.img")" "$T/boot/tsx-xx70-lts.img" "$T/dev/mmcblk0p20" && ok "boot_b holds the lts image" || bad "boot_b content"
[ -f "$T/data/tsx/boot_b.prev.img" ] && ok "previous image kept" || bad "no previous image"

# 3. the hook of the other flavor writes nothing
out=$(sh "$KF" --hook stable)
echo "$out" | grep -q 'nothing written' && ok "hook skips the other flavor" || bad "hook other: $out"
cmp -n "$(stat -c %s "$T/boot/tsx-xx70-lts.img")" "$T/boot/tsx-xx70-lts.img" "$T/dev/mmcblk0p20" && ok "boot_b unchanged" || bad "boot_b changed"

# 4. the hook again: boot_b already holds the image
out=$(sh "$KF" --hook lts)
echo "$out" | grep -q 'already holds' && ok "no second write" || bad "second write: $out"

# 5. an image without the board compatible is refused
head -c 600000 /dev/zero | tr '\0' 'x' > "$T/boot/tsx-xx70-stable.img"
out=$(sh "$KF" --hook lts; TSX_FORCE=1 sh "$BT/tsx-update-boot" --check "$T/boot/tsx-xx70-stable.img" 2>&1 || true)
echo "$out" | grep -q 'does not start with an Android' && ok "bad image refused" || bad "bad image: $out"

# 6. outside a panel nothing is written (the real detection, no fake lib)
out=$(TSX_LIBDIR=$BT sh "$KF" --hook lts)
echo "$out" | grep -q 'not on an installed xx70 panel' && ok "container: nothing written" || bad "container: $out"

busybox sh -n "$KF" && busybox sh -n "$BT/tsx-update-boot" && busybox sh -n "$BT/tsx-bootrec" && busybox sh -n "$BT/tsx-is-panel.sh" && ok "busybox sh -n" || bad "sh -n"
exit $fail
