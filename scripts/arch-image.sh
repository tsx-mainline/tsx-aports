# The container image of each architecture. scripts/build.sh, scripts/index.sh
# and scripts/resign.sh source this file. Do not run it.
#
# The tag alpine:3.24 holds only one platform in the classic image store of
# docker. A pull of linux/arm64 after a pull of linux/arm/v7 moves the tag.
# Then `docker run --platform linux/arm64 alpine:3.24` runs the armv7 image
# that is already there, and only prints a warning. A 32-bit build then runs
# with the settings of the 64-bit pass. So each architecture has its own tag,
# made right after the pull of its platform:
#   ensure_image ARCH       pull the platform of ARCH and give it its own tag
#   check_image_arch ARCH   stop unless a container of that tag reports ARCH
#   arch_image ARCH         print the tag (no docker call)
# This works the same on an arm64 host (native) and on any other host
# (qemu-user).

ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.24}

# arch_platform ARCH: the docker platform for an apk architecture.
arch_platform() {
	case $1 in
	armv7) echo linux/arm/v7;;
	aarch64) echo linux/arm64;;
	*) echo "arch-image: unsupported architecture: $1" >&2; return 1;;
	esac
}

# arch_image ARCH: the local tag of the image for ARCH, for example
# tsx-aports-alpine:3.24-armv7.
arch_image() {
	echo "tsx-aports-alpine:${ALPINE_IMAGE##*:}-$1"
}

# ensure_image ARCH: pull ALPINE_IMAGE for the platform of ARCH and tag it at
# once. If the pull fails, an earlier tag for ARCH is still good (an offline
# build). check_image_arch then tests it.
ensure_image() {
	local platform tag
	platform=$(arch_platform "$1") || return 1
	tag=$(arch_image "$1")
	if docker pull -q --platform "$platform" "$ALPINE_IMAGE" >/dev/null; then
		docker tag "$ALPINE_IMAGE" "$tag"
	elif docker image inspect "$tag" >/dev/null 2>&1; then
		echo "arch-image: cannot pull $ALPINE_IMAGE for $platform, using the local $tag" >&2
	else
		echo "arch-image: cannot pull $ALPINE_IMAGE for $platform, and $tag does not exist" >&2
		return 1
	fi
}

# check_image_arch ARCH: run the image of ARCH and compare its apk architecture
# with ARCH. It prints "ARCH container: <what apk says>". It returns 1 with a
# message when the two differ.
check_image_arch() {
	local tag got
	tag=$(arch_image "$1")
	got=$(docker run --rm --platform "$(arch_platform "$1")" "$tag" apk --print-arch) || {
		echo "arch-image: cannot run the $1 container ($tag)" >&2; return 1; }
	echo "$1 container: $got"
	if [ "$got" != "$1" ]; then
		echo "arch-image: the $1 container ($tag) says $got. Remove the tag ('docker rmi $tag') and run again." >&2
		return 1
	fi
}
