#!/bin/bash
# scripts/resign.sh IN_DIR OUT_DIR: re-sign every IN_DIR/*.apk with the
# project's real signing key, LOCALLY. This is how scripts/build.sh's
# BUILD_HOST path gets a properly-signed package without the private key
# ever touching the build host: the remote build signs with a throwaway key
# (generated there, deleted after the build), and this script splits each
# resulting apk (scripts/apk-split.py) into sig/control/data, throws the old
# (throwaway) signature away, re-signs control.tar.gz with the project key
# inside a disposable Alpine container, reassembles it, and verifies the
# result with `apk verify` -- against a trust store holding ONLY the
# project's public key, so a package that still carried a foreign signature
# would fail right here instead of silently getting published.
#
#   TSX_APORTS_KEY=<path to the private key> scripts/resign.sh IN_DIR OUT_DIR
#
# Also used directly by scripts/build.sh after pulling a BUILD_HOST build
# back; see that script and README.md "Signing key" / "Building on a remote
# host" for the full flow.
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

docker run --rm --platform linux/arm/v7 \
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
