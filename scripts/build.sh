#!/bin/bash
# Build one or all tsx-aports packages with abuild, in an Alpine v3.24 armv7
# container (docker --platform linux/arm/v7, qemu-user). Local by default,
# like the main repo's build tools; BUILD_HOST is opt-in (same push/run/pull
# pattern as tsx-xx60-linux's tools/build/remote-build.sh) -- no default
# value, so this repo names no build host.
#
#   scripts/build.sh <PKGDIR>|--all
#   PKGDIR is a package directory relative to the repo root, e.g.
#   common/sendspin-cli or xx60/tsx-xx60-chromium.
#
# Env:
#   TSX_APORTS_KEY   path to the PRIVATE signing key (required), e.g.
#                    tsx-mainline/keys/tsx-mainline-<id>.rsa (this repo's own
#                    keys/ is gitignored and never holds it -- the key lives
#                    outside every repo). Mounted read-only into the
#                    container; never copied into it or into this repo.
#   BUILD_HOST       ssh destination to build on instead of here (opt-in).
#   BUILD_DIR        remote path this repo is mirrored to (required with
#                    BUILD_HOST).
#
# What runs per package: `abuild checksum` (fills in real sha512sums for any
# source= that came from a URL -- e.g. sendspin-cli's pinned tarball; a
# no-op when all sources are already-checksummed local files) then
# `abuild -r` (fetch missing build deps, build, package, sign with
# TSX_APORTS_KEY, index). Output: packages/v3.24/<common|xx60>/armv7/*.apk
# +APKINDEX.tar.gz, here or under BUILD_DIR on the host. If BUILD_HOST was
# used, the (possibly checksum-updated) APKBUILD is synced back too, so the
# real checksum is what ends up committed -- diff it before committing.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
TARGET=${1:?"usage: build.sh <PKGDIR>|--all"}

if [ -n "${BUILD_HOST:-}" ] && [ -z "${ON_HOST:-}" ]; then
	: "${BUILD_DIR:?BUILD_HOST needs BUILD_DIR (remote path this repo is mirrored to)}"
	: "${TSX_APORTS_KEY:?set TSX_APORTS_KEY (local path to the private key)}"
	KEYNAME=$(basename "$TSX_APORTS_KEY")
	echo "[build.sh] pushing $REPO -> $BUILD_HOST:$BUILD_DIR"
	ssh -o BatchMode=yes "$BUILD_HOST" "mkdir -p '$BUILD_DIR'"
	# src/ and pkg/ are abuild's own per-package work dirs (root-owned inside
	# the container, since builds run with abuild -F); never delete or
	# descend into them from here -- they are host-side build state, not
	# part of the pushed source tree.
	rsync -a --delete --exclude packages/ --exclude '.git/' --exclude 'src/' --exclude 'pkg/' --exclude 'extract/' \
		"$REPO/" "$BUILD_HOST:$BUILD_DIR/"
	# Keep the real basename across the push: abuild-sign embeds it in the
	# index's signature entry (.SIGN.RSA.<basename>.pub), and every panel
	# and container trusts the key under ITS real name -- renaming it in
	# transit would sign the index with an identity nothing else knows.
	ssh -o BatchMode=yes "$BUILD_HOST" "mkdir -p '$BUILD_DIR.keys'"
	rsync -a "$TSX_APORTS_KEY" "$BUILD_HOST:$BUILD_DIR.keys/$KEYNAME"
	rsync -a "$TSX_APORTS_KEY.pub" "$BUILD_HOST:$BUILD_DIR.keys/$KEYNAME.pub"
	echo "[build.sh] building on $BUILD_HOST"
	ssh -o BatchMode=yes "$BUILD_HOST" \
		"ON_HOST=1 TSX_APORTS_KEY='$BUILD_DIR.keys/$KEYNAME' '$BUILD_DIR/scripts/build.sh' '$TARGET'"
	echo "[build.sh] pulling packages/ back"
	mkdir -p "$REPO/packages"
	rsync -a "$BUILD_HOST:$BUILD_DIR/packages/" "$REPO/packages/"
	if [ "$TARGET" != --all ]; then
		rsync -a "$BUILD_HOST:$BUILD_DIR/$TARGET/APKBUILD" "$REPO/$TARGET/APKBUILD"
	else
		for CAT in common xx60; do
			for d in "$REPO/$CAT"/*/; do
				p="$CAT/$(basename "$d")/APKBUILD"
				rsync -a "$BUILD_HOST:$BUILD_DIR/$p" "$REPO/$p"
			done
		done
	fi
	ssh -o BatchMode=yes "$BUILD_HOST" "rm -rf '$BUILD_DIR.keys'"
	exit 0
fi

: "${TSX_APORTS_KEY:?set TSX_APORTS_KEY (path to the private signing key)}"
[ -f "$TSX_APORTS_KEY" ] || { echo "build.sh: no such file: $TSX_APORTS_KEY" >&2; exit 1; }
[ -f "$TSX_APORTS_KEY.pub" ] || { echo "build.sh: no such file: $TSX_APORTS_KEY.pub" >&2; exit 1; }
KEYNAME=$(basename "$TSX_APORTS_KEY")

if [ "$TARGET" = --all ]; then
	PKGDIRS=$( (cd "$REPO" && find common xx60 -mindepth 1 -maxdepth 1 -type d) | sort)
else
	[ -f "$REPO/$TARGET/APKBUILD" ] || { echo "build.sh: no $REPO/$TARGET/APKBUILD" >&2; exit 1; }
	PKGDIRS="$TARGET"
fi

for PKGDIR in $PKGDIRS; do
	echo "=== building $PKGDIR ==="
	docker run --rm --platform linux/arm/v7 \
		-v "$REPO:/repo" \
		-v "$TSX_APORTS_KEY:/keys/$KEYNAME:ro" \
		-v "$TSX_APORTS_KEY.pub:/keys/$KEYNAME.pub:ro" \
		alpine:3.24 sh -euc "
			apk update >/dev/null
			# zstd: alpine-sdk's abuild does not pull it in, but its
			# unpack step needs the zstd binary for any .tar.zst
			# source (e.g. the xx60/tsx-xx60-kernel-FLAVOR bundles).
			apk add --no-cache alpine-sdk zstd >/dev/null
			cp /keys/$KEYNAME.pub /etc/apk/keys/
			mkdir -p /root/.abuild
			echo 'PACKAGER_PRIVKEY=/keys/$KEYNAME' > /root/.abuild/abuild.conf
			echo 'PACKAGER=\"unex <7575866+unex@users.noreply.github.com>\"' >> /root/.abuild/abuild.conf
			cd /repo/$PKGDIR
			abuild -F checksum
			abuild -F -r -P /repo/packages/v3.24
		"
done
echo "=== packages/v3.24 ==="
find "$REPO/packages/v3.24" -maxdepth 3 2>/dev/null || true
