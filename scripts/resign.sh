#!/bin/bash
# scripts/resign.sh IN_DIR OUT_DIR: re-sign every IN_DIR/*.apk with the
# real signing key of the project, LOCALLY. With this script, the BUILD_HOST
# path of scripts/build.sh gets a correctly signed package, and the private
# key never reaches the build host. The remote build signs with a throwaway
# key (generated there and deleted after the build). This script does these
# steps:
#   1. It splits each apk into sig, control, and data (scripts/apk-split.py).
#   2. It discards the old (throwaway) signature.
#   3. It re-signs control.tar.gz with the project key in a disposable
#      Alpine container.
#   4. It assembles the apk again.
#   5. It runs `apk verify` against a trust store that holds ONLY the public
#      key of the project. A package with a foreign signature fails here,
#      and the build does not publish it.
#
#   TSX_APORTS_KEY=<path to the private key> scripts/resign.sh IN_DIR OUT_DIR
#
# scripts/build.sh also calls this script after it pulls back a BUILD_HOST
# build. See that script, and README.md "Signing key" and "Building on a
# remote host", for the full flow.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
: "${TSX_APORTS_KEY:?set TSX_APORTS_KEY (path to the private signing key)}"
[ -f "$TSX_APORTS_KEY" ] || { echo "resign.sh: no such file: $TSX_APORTS_KEY" >&2; exit 1; }
[ -f "$TSX_APORTS_KEY.pub" ] || { echo "resign.sh: no such file: $TSX_APORTS_KEY.pub" >&2; exit 1; }
KEYNAME=$(basename "$TSX_APORTS_KEY")

IN=${1:?"usage: resign.sh IN_DIR OUT_DIR"}
OUT=${2:?"usage: resign.sh IN_DIR OUT_DIR"}
[ -d "$IN" ] || { echo "resign.sh: no such directory: $IN" >&2; exit 1; }
IN=$(cd "$IN" && pwd)
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)

shopt -s nullglob
APKS=("$IN"/*.apk)
[ ${#APKS[@]} -gt 0 ] || { echo "resign.sh: no *.apk in $IN" >&2; exit 1; }

WORK=$(mktemp -d "$HERE/.resign-work.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
for f in "${APKS[@]}"; do
	b=$(basename "$f" .apk)
	python3 "$HERE/apk-split.py" "$f" "$WORK/$b"
done

# the container matches the packages' architecture (the last part of IN:
# .../<category>/<arch>); armv7 when IN is named otherwise
case $(basename "$IN") in aarch64) PLATFORM=linux/arm64;; *) PLATFORM=linux/arm/v7;; esac
docker run --rm --platform "$PLATFORM" \
	-v "$WORK:/w" -v "$OUT:/out" \
	-v "$TSX_APORTS_KEY:/keys/$KEYNAME:ro" -v "$TSX_APORTS_KEY.pub:/keys/$KEYNAME.pub:ro" \
	alpine:3.24 sh -euc "
		apk add --no-cache abuild apk-tools >/dev/null
		rm -f /etc/apk/keys/*
		cp /keys/$KEYNAME.pub /etc/apk/keys/
		cd /w
		for d in */; do
			d=\${d%/}
			abuild-sign -q -k /keys/$KEYNAME /w/\$d/control.tar.gz
			cat /w/\$d/control.tar.gz /w/\$d/data.tar.gz > /out/\$d.apk
			apk verify /out/\$d.apk
		done
		chown -R $(id -u):$(id -g) /out
	"
echo "resign.sh: re-signed ${#APKS[@]} package(s) -> $OUT"
