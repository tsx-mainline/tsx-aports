# Shared by tsx-kernel-flavor (the tsx-xx60-kernel-* install/upgrade hook):
# is this an installed xx60 panel with an eMMC boot partition, running from
# its eMMC root -- and not a chroot or container (an abuild/apk test run,
# e.g. under docker --platform linux/arm/v7, or a rootfs build's
# `apk add --root`)? Source this file, then check the exit status of
# tsx_is_installed_panel.
#
# The test is "/ IS the eMMC root partition (mmcblk1p8)": the device number
# of / must equal the one of /dev/mmcblk1p8. apk-tools 3 runs package scripts
# in their own PID/mount namespace, so /proc/1 there is not the panel's init
# and a "/ vs /proc/1/root" comparison cannot tell a chroot from the real
# system; the device number needs no /proc at all.
tsx_is_installed_panel() {
	[ -e /etc/tsx/emmc-root.info ] || return 1
	[ -b /dev/mmcblk1p7 ] && [ -b /dev/mmcblk1p8 ] || return 1
	[ -e /.dockerenv ] && return 1

	root=$(stat -c %d / 2>/dev/null) || return 1
	maj=$(stat -c %t /dev/mmcblk1p8 2>/dev/null) || return 1
	min=$(stat -c %T /dev/mmcblk1p8 2>/dev/null) || return 1
	maj=$((0x$maj)) min=$((0x$min))
	# Linux dev_t encoding (new_encode_dev), as stat %d prints it
	[ "$root" = "$(( (min & 255) | (maj << 8) | ((min & ~255) << 12) ))" ]
}
