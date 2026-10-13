#!/bin/sh
# Write keep/keep.txt and keep/v3.24/ for a tsx-xx60-linux release tag.
#
#   scripts/keep-pins.sh TAG
#
# The rescue initramfs of tsx-xx60-linux takes its files from the exact
# package versions of rootfs/initramfs/packages.pin. The kernel packages carry
# the initramfs of the release TAG that they pin. The release build of that
# repo needs these versions in the published tree, so scripts/index.sh must
# never prune them (README.md "Kept packages"). scripts/pin-kernel.sh runs this
# script with its TAG.
#
# Steps:
#   1. Download rootfs/initramfs/packages.pin of TAG.
#   2. For each pin, take the file from keep/v3.24/ when keep.txt already has
#      it, else download it from the published tree (common or xx60, armv7),
#      where its signed index lists it.
#   3. Write keep.txt (the comment lines at its top stay) and delete the files
#      of keep/v3.24/ that the new list does not name.
# The script stops at the first problem and then changes nothing.
#
# PIN_RAW_URL replaces https://raw.githubusercontent.com/tsx-mainline/tsx-xx60-linux
# and PIN_TREE_URL replaces https://tsx-aports.unexceptional.net/v3.24 (the
# test uses file:// URLs). TSX_APORTS_KEEP_DIR replaces keep/.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TAG=${1:?usage: keep-pins.sh TAG}
RAW=${PIN_RAW_URL:-https://raw.githubusercontent.com/tsx-mainline/tsx-xx60-linux}
TREE=${PIN_TREE_URL:-https://tsx-aports.unexceptional.net/v3.24}
KEEP=${TSX_APORTS_KEEP_DIR:-$HERE/../keep}
die() { echo "keep-pins.sh: $*" >&2; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
echo "== the pins of $TAG: $RAW/$TAG/rootfs/initramfs/packages.pin"
curl -fsSL -o "$T/packages.pin" "$RAW/$TAG/rootfs/initramfs/packages.pin" || die "cannot download packages.pin of $TAG"
for c in common xx60; do
	curl -fsSL -o "$T/$c.tar.gz" "$TREE/$c/armv7/APKINDEX.tar.gz" || die "cannot download the index of $c"
	tar -xzOf "$T/$c.tar.gz" APKINDEX | awk '/^P:/ { p = substr($0, 3) } /^V:/ { print p "-" substr($0, 3) ".apk" }' > "$T/$c.list"
done
mkdir -p "$T/new"
: > "$T/keep.txt"
grep -v -e '^#' -e '^[[:space:]]*$' "$T/packages.pin" | while IFS='=' read -r n v; do
	f=$n-$v.apk rel=
	old=$( [ -f "$KEEP/keep.txt" ] && awk -v f="$f" '!/^#/ && NF >= 2 { n = split($1, a, "/"); if (a[n] == f) { print $1, $2; exit } }' "$KEEP/keep.txt" || true)
	if [ -n "$old" ]; then
		rel=${old% *}; sum=${old#* }
		[ -f "$KEEP/v3.24/$rel" ] && [ "$(sha256sum < "$KEEP/v3.24/$rel" | cut -d' ' -f1)" = "$sum" ] \
			|| die "keep/v3.24/$rel is missing or not the file of keep.txt"
		mkdir -p "$T/new/$(dirname "$rel")"; cp "$KEEP/v3.24/$rel" "$T/new/$rel"
		echo "   $rel (kept already)"
	else
		for c in common xx60; do grep -qxF "$f" "$T/$c.list" && { rel=$c/armv7/$f; break; }; done
		[ -n "$rel" ] || die "$f: not in keep.txt and not in the published tree"
		mkdir -p "$T/new/$(dirname "$rel")"
		curl -fsSL -o "$T/new/$rel" "$TREE/$rel" || die "cannot download $TREE/$rel"
		sum=$(sha256sum < "$T/new/$rel" | cut -d' ' -f1)
		echo "   $rel (from the published tree)"
	fi
	echo "$rel $sum" >> "$T/keep.txt"
done
[ -s "$T/keep.txt" ] || die "packages.pin of $TAG names no package"
# Every pin must have its line (the loop above runs in a subshell).
[ "$(wc -l < "$T/keep.txt")" = "$(grep -c -v -e '^#' -e '^[[:space:]]*$' "$T/packages.pin")" ] || die "a pin failed (see above)"
mkdir -p "$KEEP"
{ [ -f "$KEEP/keep.txt" ] && awk '/^#/ { print; next } { exit }' "$KEEP/keep.txt"; cat "$T/keep.txt"; } > "$T/keep.full"
rm -rf "$KEEP/v3.24"
mkdir -p "$KEEP/v3.24"
cp -R "$T/new/." "$KEEP/v3.24/"
mv "$T/keep.full" "$KEEP/keep.txt"
echo "   keep.txt: $(wc -l < "$T/keep.txt") kept package(s) for $TAG"
