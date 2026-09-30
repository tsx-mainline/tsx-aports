# tsx-kernel-flavor (the install and upgrade hook of the tsx-xx60-kernel-*
# packages) uses this file. It answers one question: is this an installed
# xx60 panel with an eMMC boot partition that runs from its eMMC root? A
# chroot or container is not such a panel. This includes an abuild or apk test
# run (for example under docker --platform linux/arm/v7) and the
# `apk add --root` of a rootfs build. Source this file, then check the exit
# status of tsx_is_installed_panel.
#
# The test is "/ IS the eMMC root partition (mmcblk1p8)". The device number of
# / must equal the device number of /dev/mmcblk1p8. apk-tools 3 runs package
# scripts in their own PID and mount namespace. There, /proc/1 is not the init
# of the panel, so a comparison of "/" and "/proc/1/root" cannot tell a chroot
# from the real system. The device number does not need /proc.
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
