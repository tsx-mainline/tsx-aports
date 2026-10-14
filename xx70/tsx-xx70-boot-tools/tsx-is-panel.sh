# Shared by tsx-kernel-flavor (the tsx-xx70-kernel-* install and upgrade
# hook): is this an installed xx70 panel that runs from its system_b root,
# and not a chroot or a container (an abuild test run, or a rootfs build
# with `apk add --root`)? Source this file, then check the exit status of
# tsx_is_installed_panel.
#
# The test is "/ IS the system_b partition": the device number of / must
# equal the one in sysfs for the partition named system_b. apk-tools 3 runs
# package scripts in their own PID and mount namespace, so a comparison with
# /proc/1/root cannot tell a chroot from the real system. The device number
# needs no /proc. TSX_SYSBLOCK and TSX_DEVDIR are test hooks.

# tsx_part_name NAME: print the kernel name of the eMMC partition with the
# GPT name NAME (for example boot_b), or fail.
tsx_part_name() {
	for u in "${TSX_SYSBLOCK:-/sys/class/block}"/mmcblk*p*/uevent; do
		[ -r "$u" ] || continue
		grep -qx "PARTNAME=$1" "$u" || continue
		d=${u%/uevent}; echo "${d##*/}"; return 0
	done
	return 1
}

tsx_is_installed_panel() {
	[ -e /.dockerenv ] && return 1
	boot=$(tsx_part_name boot_b) || return 1
	sys=$(tsx_part_name system_b) || return 1
	[ -b "${TSX_DEVDIR:-/dev}/$boot" ] || [ -f "${TSX_DEVDIR:-/dev}/$boot" ] || return 1
	root=$(stat -c %d / 2>/dev/null) || return 1
	mm=$(cat "${TSX_SYSBLOCK:-/sys/class/block}/$sys/dev" 2>/dev/null) || return 1
	maj=${mm%%:*} min=${mm##*:}
	# Linux dev_t encoding (new_encode_dev), as stat %d prints it
	[ "$root" = "$(( (min & 255) | (maj << 8) | ((min & ~255) << 12) ))" ]
}
