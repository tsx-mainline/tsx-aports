#!/bin/bash
# Build a PRIVATE apk repository for panels on a LAN, from sources that are not
# published (a commit of tsx-linux-common and of uc-pxx-linux), signed with a
# private LAN key. Nothing goes to GitHub or to the public site. README.md
# "Private LAN repository" tells the whole procedure.
#
#   scripts/lan-repo.sh common  COMMON_TGZ VERSION   set the LAN version of the common recipes
#   scripts/lan-repo.sh build   [PKGDIR...]          build the LAN packages (default: all of LAN_PKGS)
#   scripts/lan-repo.sh publish REPO_DIR             copy, index and sign the repository
#
# Run the script on the build host, in a COPY of this repository (the
# BUILD_DIR of scripts/build.sh). The commands "common" and "build" change the
# recipes of that copy, so the script refuses to run in a git checkout.
#
# common   COMMON_TGZ is `git archive --prefix=tsx-linux-common-VERSION/` of a
#          tsx-linux-common commit, gzip. VERSION must be newer than the
#          published common packages (for example 0.3.12_pre2026102501). Each
#          recipe of LAN_COMMON gets pkgver=VERSION, pkgrel=0, SRCDEST=dist and
#          the archive in its dist/. build.sh writes the sums (abuild checksum).
# build    runs scripts/build.sh --arch aarch64 for each package, with the
#          published common repository as an extra repository for the build
#          dependencies that are not rebuilt (LAN_EXTRA_REPO). The uc-pxx
#          recipes need their staged files in dist/ first (scripts/uc-pxx-source.sh,
#          scripts/stage-uc-pxx-tools.sh, scripts/stage-kernel-uc-pxx.sh).
# publish  makes REPO_DIR/v3.24/common/aarch64 and REPO_DIR/v3.24/uc-pxx/aarch64:
#          the newest built package of each name, and the exact files of
#          LAN_KEEP from LAN_KEEP_DIR (published packages that the panels have
#          and that are not rebuilt, with their own signatures). Then it writes
#          and signs APKINDEX.tar.gz of each folder with LAN_KEY and checks it
#          with apk verify against the LAN key and the project key only.
#
# Environment:
#   LAN_KEY         the PRIVATE LAN key (required for build and publish). Its
#                   .pub must be next to it. It is not the project key.
#   LAN_PKGS        the recipes to build (default: LAN_COMMON and the uc-pxx recipes)
#   LAN_COMMON      the common recipes of the LAN version (default below)
#   LAN_EXTRA_REPO  default https://tsx-aports.unexceptional.net/v3.24/common
#   LAN_KEEP        file names to copy into common (default below)
#   LAN_KEEP_DIR    a folder that holds the LAN_KEEP files (required for publish)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
ALPINE=v3.24
LAN_COMMON=${LAN_COMMON:-"tsx-base tsx-autoupdate tsx-buttons tsx-idled tsx-splash tsx-kiosk tsx-setup tsx-sendspin tsx-ha tsx-panel-app"}
UC_PXX="uc-pxx-boot-tools uc-pxx-kernel-lts uc-pxx-leds uc-pxx-board uc-pxx-console uc-pxx-kiosk uc-pxx-ha"
LAN_KEEP=${LAN_KEEP:-"tsx-keys-1-r0.apk sendspin-cli-0.3.0-r2.apk tensorflow-lite-c-2.17.1-r1.apk"}
LAN_EXTRA_REPO=${LAN_EXTRA_REPO:-https://tsx-aports.unexceptional.net/$ALPINE/common}
say() { echo "[lan-repo] $*"; }
die() { echo "lan-repo: $*" >&2; exit 1; }

if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
	die "$REPO is a git checkout. Run this script in a copy (BUILD_DIR), because it changes the recipes."
fi
need_key() {
	: "${LAN_KEY:?set LAN_KEY (the private LAN key)}"
	[ -f "$LAN_KEY" ] && [ -f "$LAN_KEY.pub" ] || die "no $LAN_KEY or $LAN_KEY.pub"
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case $cmd in
common)
	TGZ=${1:?usage: lan-repo.sh common COMMON_TGZ VERSION}
	VER=${2:?usage: lan-repo.sh common COMMON_TGZ VERSION}
	top=$(tar -tzf "$TGZ" | sed -n 1p)
	[ "$top" = "tsx-linux-common-$VER/" ] || die "$TGZ has the top folder $top, expected tsx-linux-common-$VER/"
	Z=$(printf '0%.0s' $(seq 128))
	for p in $LAN_COMMON; do
		A=$REPO/common/$p/APKBUILD
		[ -f "$A" ] || die "no $A"
		sed -i -e "s/^pkgver=.*/pkgver=$VER/" -e "s/^pkgrel=.*/pkgrel=0/" \
			-e "s/^[0-9a-f]\{128\}  tsx-linux-common-.*\.tar\.gz\$/$Z  tsx-linux-common-$VER.tar.gz/" "$A"
		grep -q '^SRCDEST=' "$A" || sed -i '1i SRCDEST="$startdir/dist"  # LAN build: the local archive (scripts/lan-repo.sh)' "$A"
		grep -q "  tsx-linux-common-$VER.tar.gz\$" "$A" || die "$p has no source tsx-linux-common-\$pkgver.tar.gz"
		mkdir -p "$REPO/common/$p/dist"
		cp "$TGZ" "$REPO/common/$p/dist/tsx-linux-common-$VER.tar.gz"
		say "$p: pkgver $VER"
	done;;
build)
	need_key
	PKGS=${*:-${LAN_PKGS:-$(for p in $LAN_COMMON; do echo common/$p; done; for p in $UC_PXX; do echo uc-pxx/$p; done)}}
	# The order of the list matters: a package comes after the packages it needs.
	for d in $PKGS; do
		say "=== $d"
		TSX_APORTS_KEY=$LAN_KEY "$HERE/build.sh" --arch aarch64 --extra-repo "$LAN_EXTRA_REPO" "$d"
	done;;
publish)
	need_key
	OUT=${1:?usage: lan-repo.sh publish REPO_DIR}
	: "${LAN_KEEP_DIR:?set LAN_KEEP_DIR (a folder with the LAN_KEEP files)}"
	KEYNAME=$(basename "$LAN_KEY")
	. "$HERE/arch-image.sh"
	ensure_image aarch64
	IMAGE=$(arch_image aarch64)
	for cat in common uc-pxx; do
		src=$REPO/packages/$ALPINE/$cat/aarch64
		dst=$OUT/$ALPINE/$cat/aarch64
		[ -d "$src" ] || die "no built packages in $src"
		mkdir -p "$OUT"
		new=$(mktemp -d "$OUT/.new-$cat.XXXXXX")
		cp "$src"/*.apk "$new"/
		if [ "$cat" = common ]; then
			for k in $LAN_KEEP; do
				[ -f "$LAN_KEEP_DIR/$k" ] || die "no $LAN_KEEP_DIR/$k"
				cp "$LAN_KEEP_DIR/$k" "$new/"
			done
		fi
		# one file for each package name (build in a fresh copy, see README.md)
		dup=$(cd "$new" && ls *.apk | sed -E 's/-[0-9][^-]*-r[0-9]+\.apk$//' | sort | uniq -d)
		[ -z "$dup" ] || { rm -rf "$new"; die "$cat has more than one version of: $dup"; }
		docker run --rm --platform linux/arm64 -v "$new:/d" -v "$LAN_KEY:/k/$KEYNAME:ro" -v "$LAN_KEY.pub:/k/$KEYNAME.pub:ro" \
			-v "$REPO/common/tsx-keys:/tk:ro" "$IMAGE" sh -euc "
			apk add -q abuild >/dev/null
			cp /k/$KEYNAME.pub /tk/*.rsa.pub /etc/apk/keys/
			cd /d
			for f in *.apk; do apk verify \"\$f\" >/dev/null 2>&1 || { echo \"not signed by the LAN or the project key: \$f\"; exit 1; }; done
			apk index -q --rewrite-arch aarch64 -o APKINDEX.tar.gz *.apk 2>/dev/null
			abuild-sign -q -k /k/$KEYNAME APKINDEX.tar.gz
			apk verify APKINDEX.tar.gz >/dev/null
			chown -R $(id -u):$(id -g) /d"
		chmod 755 "$new"; chmod 644 "$new"/*
		mkdir -p "$(dirname "$dst")"
		rm -rf "$dst.old"; [ -d "$dst" ] && mv "$dst" "$dst.old"
		mv "$new" "$dst"; rm -rf "$dst.old"
		say "$cat: $(ls "$dst" | grep -c '\.apk$') packages, index signed with $KEYNAME"
		(cd "$dst" && sha256sum *.apk APKINDEX.tar.gz) > "$dst.sha256"
	done;;
*) sed -n '2,40p' "$0" >&2; exit 2;;
esac
