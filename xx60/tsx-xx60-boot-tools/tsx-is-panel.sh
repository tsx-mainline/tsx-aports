# Shared by tsx-xx60-kernel-*'s post-install/post-upgrade: is this an
# installed xx60 panel with an eMMC boot partition, and not a chroot or
# container (an abuild/apk test run, e.g. under docker --platform linux/arm/v7)?
# Source this file, then check the exit status of tsx_is_installed_panel.
tsx_is_installed_panel() {
	[ -e /etc/tsx/emmc-root.info ] || return 1
	[ -e /dev/mmcblk1p7 ] || return 1

	# chroot check: / and what PID 1 sees as its root must be the same inode.
	# In a container PID 1 IS the entrypoint, so this also catches most of
	# those; the two checks below catch the rest.
	if [ -d /proc/1/root ] && [ -r /proc/1/root ]; then
		mine=$(stat -c '%d:%i' / 2>/dev/null) || mine=
		pid1=$(stat -c '%d:%i' /proc/1/root 2>/dev/null) || pid1=
		[ -n "$mine" ] && [ "$mine" = "$pid1" ] || return 1
	fi

	[ -e /.dockerenv ] && return 1
	if [ -r /proc/1/cgroup ] && grep -qE 'docker|containerd|libpod|lxc' /proc/1/cgroup 2>/dev/null; then
		return 1
	fi
	return 0
}
