#!/bin/sh
# Keep an Alpine package that Alpine removed from its index.
#
#   scripts/keep-alpine.sh CATEGORY URL
#   CATEGORY  xx60, common, ... (the folder of our tree that lists the file)
#   URL       the .apk on dl-cdn.alpinelinux.org (armv7)
#
# Steps:
#   1. Download the file.
#   2. Run `apk verify` in the armv7 container. The container trusts the Alpine
#      keys only. The file must carry a valid Alpine signature.
#   3. Copy the file to keep/alpine/v3.24/<CATEGORY>/armv7/ and add its line
#      (sha256) to keep/keep-alpine.txt.
# scripts/index.sh then keeps the file in the tree (README.md "Kept packages").
# Run it on the build host. The script does not use the signing key.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/arch-image.sh"
CAT=${1:?usage: keep-alpine.sh CATEGORY URL}
URL=${2:?usage: keep-alpine.sh CATEGORY URL}
KEEP=${TSX_APORTS_KEEP_DIR:-$HERE/../keep}
case $URL in https://dl-cdn.alpinelinux.org/alpine/v3.24/*/armv7/*.apk) ;; *) echo "keep-alpine.sh: the URL must be an armv7 .apk of Alpine v3.24" >&2; exit 1;; esac
F=${URL##*/}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
echo "== download $URL"
curl -fsSL -o "$T/$F" "$URL"
echo "== apk verify (Alpine keys)"
ensure_image armv7; check_image_arch armv7
docker run --rm --platform "$(arch_platform armv7)" -v "$T:/k:ro" "$(arch_image armv7)" apk verify "/k/$F"
SUM=$(sha256sum < "$T/$F" | cut -d' ' -f1)
D=$KEEP/alpine/v3.24/$CAT/armv7
mkdir -p "$D"
cp "$T/$F" "$D/$F"
L=$CAT/armv7/$F
if grep -q "^$L " "$KEEP/keep-alpine.txt" 2>/dev/null; then
	[ "$(awk -v l="$L" '$1 == l { print $2 }' "$KEEP/keep-alpine.txt")" = "$SUM" ] || { echo "keep-alpine.sh: $L is listed with another sha256" >&2; exit 1; }
else
	echo "$L $SUM" >> "$KEEP/keep-alpine.txt"
fi
echo "kept $L $SUM"
