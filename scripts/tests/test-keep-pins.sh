#!/bin/bash
# Host test of scripts/keep-pins.sh: keep/keep.txt follows the packages.pin of
# a tsx-xx60-linux tag. No network: the tag and the published tree are folders
# behind file:// URLs. No key and no docker.
#   1. A new pin comes from the published tree, a pin that keep.txt has stays
#      (from keep/v3.24/), and a file that no pin names any more goes.
#   2. The comment lines at the top of keep.txt stay.
#   3. A pin that is nowhere stops the script, and keep/ does not change.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
N=0 F=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkidx() {  # mkidx DIR NAME-VER...: an APKINDEX.tar.gz that lists the packages
	local d=$1 p; shift; mkdir -p "$d"
	for p in "$@"; do printf 'P:%s\nV:%s\n\n' "${p%%=*}" "${p#*=}"; done > "$d/APKINDEX"
	tar -czf "$d/APKINDEX.tar.gz" -C "$d" APKINDEX; rm "$d/APKINDEX"
}
# the published tree: board 0.3.8-r0 (xx60), kiosk 0.3.8-r0 and splash 0.2.0-r1 (common)
mkidx "$W/tree/common/armv7" tsx-kiosk=0.3.8-r0 tsx-splash=0.2.0-r1
mkidx "$W/tree/xx60/armv7" tsx-xx60-board=0.3.8-r0
echo kiosk38 > "$W/tree/common/armv7/tsx-kiosk-0.3.8-r0.apk"
echo splash20 > "$W/tree/common/armv7/tsx-splash-0.2.0-r1.apk"
echo board38 > "$W/tree/xx60/armv7/tsx-xx60-board-0.3.8-r0.apk"
# keep/ now: board 0.2.0-r1 and rescue-ui 0.2.0-r1 (not in the published tree any more)
K=$W/keep; mkdir -p "$K/v3.24/xx60/armv7" "$K/v3.24/common/armv7"
echo board20 > "$K/v3.24/xx60/armv7/tsx-xx60-board-0.2.0-r1.apk"
echo rescue20 > "$K/v3.24/common/armv7/tsx-rescue-ui-0.2.0-r1.apk"
{ echo "# header line 1"; echo "# header line 2"
  echo "xx60/armv7/tsx-xx60-board-0.2.0-r1.apk $(sha256sum < "$K/v3.24/xx60/armv7/tsx-xx60-board-0.2.0-r1.apk" | cut -d' ' -f1)"
  echo "common/armv7/tsx-rescue-ui-0.2.0-r1.apk $(sha256sum < "$K/v3.24/common/armv7/tsx-rescue-ui-0.2.0-r1.apk" | cut -d' ' -f1)"; } > "$K/keep.txt"
# keep/keep-alpine.txt and keep/alpine/ (Alpine files) belong to no pin: keep-pins.sh must leave them
mkdir -p "$K/alpine/v3.24/xx60/armv7"
echo alpinefile > "$K/alpine/v3.24/xx60/armv7/chromium-common-152.0.7977.82-r0.apk"
echo "xx60/armv7/chromium-common-152.0.7977.82-r0.apk $(sha256sum < "$K/alpine/v3.24/xx60/armv7/chromium-common-152.0.7977.82-r0.apk" | cut -d' ' -f1)" > "$K/keep-alpine.txt"
alpine_before=$(cat "$K/keep-alpine.txt")
pin() {  # pin TAG LINES...: packages.pin of TAG
	local t=$1; shift; mkdir -p "$W/raw/$t/rootfs/initramfs"
	{ echo "# a comment"; printf '%s\n' "$@"; } > "$W/raw/$t/rootfs/initramfs/packages.pin"
}
run() { PIN_RAW_URL=file://$W/raw PIN_TREE_URL=file://$W/tree TSX_APORTS_KEEP_DIR=$K sh "$HERE/keep-pins.sh" "$@"; }

echo "== 1. the pins of a new tag"
pin v9.0.0 tsx-rescue-ui=0.2.0-r1 tsx-splash=0.2.0-r1 tsx-xx60-board=0.3.8-r0 tsx-kiosk=0.3.8-r0
out=$(run v9.0.0 2>&1); rc=$?
[ $rc = 0 ] && ok "keep-pins.sh v9.0.0 exits 0" || bad "rc $rc: $out"
lines=$(grep -v '^#' "$K/keep.txt" | awk '{ print $1 }' | tr '\n' ' ')
[ "$lines" = "common/armv7/tsx-rescue-ui-0.2.0-r1.apk common/armv7/tsx-splash-0.2.0-r1.apk xx60/armv7/tsx-xx60-board-0.3.8-r0.apk common/armv7/tsx-kiosk-0.3.8-r0.apk " ] \
	&& ok "keep.txt lists the 4 pins in the order of packages.pin" || bad "keep.txt: $lines"
[ "$(cat "$K/v3.24/common/armv7/tsx-rescue-ui-0.2.0-r1.apk")" = rescue20 ] && ok "a pin that keep.txt had stays (not in the tree)" || bad "rescue-ui lost"
[ "$(cat "$K/v3.24/xx60/armv7/tsx-xx60-board-0.3.8-r0.apk")" = board38 ] && ok "a new pin comes from the published tree" || bad "board 0.3.8 missing"
[ ! -e "$K/v3.24/xx60/armv7/tsx-xx60-board-0.2.0-r1.apk" ] && ok "the old board file is gone" || bad "board 0.2.0-r1 still kept"
while read -r rel sum; do
	[ "$(sha256sum < "$K/v3.24/$rel" | cut -d' ' -f1)" = "$sum" ] || bad "sha256 of $rel"
done < <(grep -v '^#' "$K/keep.txt")
ok "every kept file has the sha256 of its line"
[ "$(head -n 2 "$K/keep.txt")" = "$(printf '# header line 1\n# header line 2')" ] && ok "the header stays" || bad "header: $(head -n 2 "$K/keep.txt")"
[ "$(cat "$K/keep-alpine.txt")" = "$alpine_before" ] && [ "$(cat "$K/alpine/v3.24/xx60/armv7/chromium-common-152.0.7977.82-r0.apk")" = alpinefile ] \
	&& ok "keep-alpine.txt and keep/alpine/ stay" || bad "keep-pins.sh changed the kept Alpine files"
echo "== 2. the same tag again"
before=$(cat "$K/keep.txt")
out=$(run v9.0.0 2>&1); rc=$?
[ $rc = 0 ] && [ "$(cat "$K/keep.txt")" = "$before" ] && ok "a second run gives the same keep.txt" || bad "second run: rc $rc, $out"
echo "== 3. a pin that is nowhere"
pin v9.0.1 tsx-rescue-ui=0.2.0-r1 tsx-xx60-board=0.9.9-r0
out=$(run v9.0.1 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q "tsx-xx60-board-0.9.9-r0.apk: not in keep.txt and not in the published tree" && ok "an error names the missing pin" || bad "rc $rc: $out"
[ "$(cat "$K/keep.txt")" = "$before" ] && [ -e "$K/v3.24/xx60/armv7/tsx-xx60-board-0.3.8-r0.apk" ] && ok "keep/ did not change" || bad "keep/ changed after an error"
out=$(run v9.9.9 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q "cannot download packages.pin of v9.9.9" && ok "an unknown tag: an error" || bad "unknown tag: rc $rc, $out"
echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-keep-pins || echo FAIL test-keep-pins
exit $F
