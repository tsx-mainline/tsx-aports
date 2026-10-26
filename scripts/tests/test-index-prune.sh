#!/bin/bash
# Host test of the prune of scripts/index.sh (prune_dir). It needs no
# network, no docker and no key.
#   1. A subpackage does not count as a version of its main package: the
#      prune keeps tsx-xx60-board when tsx-xx60-board-ha and -kiosk exist,
#      and keeps tsx-ledbar when tsx-ledbar-fw exists.
#   2. A package with more than KEEP versions keeps the KEEP newest ones,
#      also when pkgrel has two digits.
#   3. A package name with a dot and a digit (tsx-xx60-wlroots0.20) groups
#      correctly.
#   4. The files of keep/keep.txt are not pruned and do not count. A kept
#      file that the tree lacks comes back from keep/v3.24/. The files in
#      keep/v3.24/ of this repo have the sha256 of the list.
#   5. The same holds for keep/keep-alpine.txt and keep/alpine/v3.24/ (the
#      Alpine packages that Alpine removed). keep-pins.sh does not touch
#      them, so they have their own list and folder.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)   # scripts/tests -> scripts
N=0 F=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }
fin() { echo "== $N ok, $F failed"; [ $F = 0 ] && echo PASS test-index-prune || echo FAIL test-index-prune; exit $F; }

TSX_APORTS_INDEX_SH_SOURCE_ONLY=1 . "$HERE/index.sh"
set +e

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
D=$W/armv7; mkdir -p "$D"
for f in \
	tsx-xx60-board-0.1.5-r0 tsx-xx60-board-0.2.0-r1 \
	tsx-xx60-board-ha-0.1.5-r0 tsx-xx60-board-ha-0.2.0-r1 \
	tsx-xx60-board-kiosk-0.1.5-r0 tsx-xx60-board-kiosk-0.2.0-r1 \
	tsx-ledbar-0.1.0-r0 tsx-ledbar-0.2.0-r1 \
	tsx-ledbar-fw-0.1.3-r0 tsx-ledbar-fw-0.1.4-r0 tsx-ledbar-fw-0.1.5-r0 \
	tsx-xx60-wlroots0.20-0.20.1-r0 tsx-xx60-wlroots0.20-0.20.2-r0 tsx-xx60-wlroots0.20-0.20.2-r1 \
	tsx-xx60-kernel-lts-6.18.54_git20260928-r9 tsx-xx60-kernel-lts-6.18.54_git20260928-r10 \
	tsx-xx60-kernel-lts-6.18.54_git20261004-r1; do
	: > "$D/$f.apk"
done

echo "== apk_names =="
[ "$(apk_names "$D" | awk -F'\t' '$2 == "tsx-xx60-board-ha-0.2.0-r1.apk" { print $1 }')" = tsx-xx60-board-ha ] \
	&& ok "subpackage name" || bad "subpackage name"
[ "$(apk_names "$D" | awk -F'\t' '$2 == "tsx-xx60-wlroots0.20-0.20.2-r1.apk" { print $1 }')" = tsx-xx60-wlroots0.20 ] \
	&& ok "name with a dot and a digit" || bad "name with a dot and a digit"

echo "== prune_dir, KEEP=2 =="
KEEP=2
out=$(prune_dir "$D"); rc=$?
[ $rc = 1 ] && ok "returns 1 after a prune" || bad "return code $rc"
has() { [ -e "$D/$1.apk" ]; }
for f in tsx-xx60-board-0.1.5-r0 tsx-xx60-board-0.2.0-r1 tsx-xx60-board-ha-0.2.0-r1 \
	tsx-xx60-board-kiosk-0.2.0-r1 tsx-ledbar-0.1.0-r0 tsx-ledbar-0.2.0-r1 \
	tsx-ledbar-fw-0.1.4-r0 tsx-ledbar-fw-0.1.5-r0 \
	tsx-xx60-wlroots0.20-0.20.2-r0 tsx-xx60-wlroots0.20-0.20.2-r1 \
	tsx-xx60-kernel-lts-6.18.54_git20260928-r10 tsx-xx60-kernel-lts-6.18.54_git20261004-r1; do
	has "$f" && ok "kept $f" || bad "pruned $f"
done
for f in tsx-ledbar-fw-0.1.3-r0 tsx-xx60-wlroots0.20-0.20.1-r0 tsx-xx60-kernel-lts-6.18.54_git20260928-r9; do
	has "$f" && bad "kept $f" || ok "pruned $f"
done
n=$(printf '%s\n' "$out" | grep -c 'pruning')
[ "$n" = 3 ] && ok "3 files pruned" || bad "$n files pruned: $out"

echo "== prune_dir again =="
prune_dir "$D" >/dev/null; rc=$?
[ $rc = 0 ] && ok "nothing more to prune" || bad "second prune returned $rc"

echo "== prune in apk order (not sort -V): _pre, _rc, letters =="
# sort -V puts x-0.4.0-r0 before x-0.4.0_pre20261026-r0. apk puts it after.
P1=$W/pre1; mkdir -p "$P1"; : > "$P1/tsx-a-0.4.0_pre20261026-r0.apk"; : > "$P1/tsx-a-0.4.0-r0.apk"
KEEP=1; prune_dir "$P1" >/dev/null
[ -e "$P1/tsx-a-0.4.0-r0.apk" ] && [ ! -e "$P1/tsx-a-0.4.0_pre20261026-r0.apk" ] && ok "KEEP=1: the release 0.4.0 stays, the _pre is pruned" || bad "KEEP=1 kept: $(ls "$P1")"
P2=$W/pre2; mkdir -p "$P2"; for v in 0.4.0_pre20261026-r0 0.4.0_pre20261101-r0 0.4.0-r0; do : > "$P2/tsx-a-$v.apk"; done
KEEP=2; prune_dir "$P2" >/dev/null
[ -e "$P2/tsx-a-0.4.0-r0.apk" ] && [ -e "$P2/tsx-a-0.4.0_pre20261101-r0.apk" ] && [ ! -e "$P2/tsx-a-0.4.0_pre20261026-r0.apk" ] \
	&& ok "KEEP=2: the release and the newest _pre stay" || bad "KEEP=2 kept: $(ls "$P2")"
P3=$W/rc; mkdir -p "$P3"; for v in 1.0_rc1-r0 1.0-r0 1.0a-r0 1.0_alpha-r0; do : > "$P3/tsx-b-$v.apk"; done
KEEP=1; prune_dir "$P3" >/dev/null
[ "$(ls "$P3")" = "tsx-b-1.0a-r0.apk" ] && ok "KEEP=1: 1.0a is newer than 1.0, 1.0_rc1 and 1.0_alpha" || bad "letter/rc kept: $(ls "$P3")"
KEEP=2

echo "== kept files (keep/keep.txt): not pruned, not counted, restored =="
K=$W/keep; T=$W/tree/v3.24; mkdir -p "$K/v3.24/xx60/armv7" "$T/xx60/armv7" "$T/common/armv7"
echo "board 0.2.0-r1" > "$K/v3.24/xx60/armv7/tsx-xx60-board-0.2.0-r1.apk"
SUM=$(sha256sum < "$K/v3.24/xx60/armv7/tsx-xx60-board-0.2.0-r1.apk" | cut -d' ' -f1)
printf '# comment\nxx60/armv7/tsx-xx60-board-0.2.0-r1.apk %s\n' "$SUM" > "$K/keep.txt"
TSX_APORTS_KEEP_DIR=$K
KEEPDIR=$K
for f in tsx-xx60-board-0.3.6-r0 tsx-xx60-board-0.3.7-r0 tsx-xx60-board-0.3.8-r0; do : > "$T/xx60/armv7/$f.apk"; done
out=$(restore_kept "$T"); rc=$?
[ $rc = 0 ] && cmp -s "$T/xx60/armv7/tsx-xx60-board-0.2.0-r1.apk" "$K/v3.24/xx60/armv7/tsx-xx60-board-0.2.0-r1.apk" \
	&& ok "a kept file that the tree lacks is restored from keep/v3.24" || bad "restore: rc $rc, $out"
out=$(restore_kept "$T"); rc=$?
[ $rc = 0 ] && [ -z "$out" ] && ok "a second restore does nothing" || bad "second restore: rc $rc, $out"
prune_dir "$T/xx60/armv7/" >/dev/null
has2() { [ -e "$T/xx60/armv7/$1.apk" ]; }
has2 tsx-xx60-board-0.2.0-r1 && ok "the kept 0.2.0-r1 is not pruned" || bad "the kept 0.2.0-r1 was pruned"
has2 tsx-xx60-board-0.3.8-r0 && has2 tsx-xx60-board-0.3.7-r0 && ok "the 2 newest stay (the kept file does not count)" || bad "a newest version was pruned"
has2 tsx-xx60-board-0.3.6-r0 && bad "0.3.6-r0 was kept" || ok "0.3.6-r0 is pruned"
: > "$T/common/armv7/tsx-xx60-board-0.2.0-r1.apk"; : > "$T/common/armv7/tsx-xx60-board-0.3.7-r0.apk"; : > "$T/common/armv7/tsx-xx60-board-0.3.8-r0.apk"
prune_dir "$T/common/armv7" >/dev/null
[ ! -e "$T/common/armv7/tsx-xx60-board-0.2.0-r1.apk" ] && ok "the keep list names a category and arch: the same file name elsewhere is pruned" || bad "kept in another category"
echo "changed" > "$T/xx60/armv7/tsx-xx60-board-0.2.0-r1.apk"
out=$(restore_kept "$T" 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q "is not the kept file" && ok "a kept file with another sha256 in the tree: an error" || bad "mismatch: rc $rc, $out"
rm -f "$T/xx60/armv7/tsx-xx60-board-0.2.0-r1.apk" "$K/v3.24/xx60/armv7/tsx-xx60-board-0.2.0-r1.apk"
out=$(restore_kept "$T" 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q "neither the tree nor" && ok "a kept file that is nowhere: an error" || bad "missing: rc $rc, $out"
echo "== kept Alpine files (keep/keep-alpine.txt) =="
K=$W/keep2; T=$W/tree2/v3.24; mkdir -p "$K/alpine/v3.24/xx60/armv7" "$T/xx60/armv7"
echo "alpine chromium-common" > "$K/alpine/v3.24/xx60/armv7/chromium-common-152.0.7977.82-r0.apk"
SUM=$(sha256sum < "$K/alpine/v3.24/xx60/armv7/chromium-common-152.0.7977.82-r0.apk" | cut -d' ' -f1)
printf '# comment\nxx60/armv7/chromium-common-152.0.7977.82-r0.apk %s\n' "$SUM" > "$K/keep-alpine.txt"
KEEPDIR=$K
[ "$(kept_list)" = "xx60/armv7/chromium-common-152.0.7977.82-r0.apk $SUM" ] && ok "kept_list reads keep-alpine.txt when keep.txt is absent" || bad "kept_list: $(kept_list)"
out=$(restore_kept "$T"); rc=$?
[ $rc = 0 ] && cmp -s "$T/xx60/armv7/chromium-common-152.0.7977.82-r0.apk" "$K/alpine/v3.24/xx60/armv7/chromium-common-152.0.7977.82-r0.apk" \
	&& ok "an Alpine file that the tree lacks is restored from keep/alpine/v3.24" || bad "restore alpine: rc $rc, $out"
: > "$T/xx60/armv7/chromium-common-152.0.7977.83-r0.apk"; : > "$T/xx60/armv7/chromium-common-152.0.7977.84-r0.apk"; : > "$T/xx60/armv7/chromium-common-152.0.7977.85-r0.apk"
prune_dir "$T/xx60/armv7/" >/dev/null
[ -e "$T/xx60/armv7/chromium-common-152.0.7977.82-r0.apk" ] && [ ! -e "$T/xx60/armv7/chromium-common-152.0.7977.83-r0.apk" ] \
	&& ok "the kept Alpine file is not pruned and does not count" || bad "prune of the kept Alpine file"
printf 'xx60/armv7/tsx-xx60-board-0.2.0-r1.apk %s\n' "$SUM" > "$K/keep.txt"
[ "$(kept_list | wc -l)" = 2 ] && ok "kept_list joins keep.txt and keep-alpine.txt" || bad "kept_list join"
rm -f "$K/keep.txt"
echo "changed" > "$T/xx60/armv7/chromium-common-152.0.7977.82-r0.apk"
out=$(restore_kept "$T" 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q "is not the kept file" && ok "an Alpine file with another sha256 in the tree: an error" || bad "alpine mismatch: rc $rc, $out"
echo "== the kept files of this repo =="
KEEPDIR=$HERE/../keep
while read -r rel sum; do
	f=$(kept_source "$rel")
	[ -f "$f" ] && [ "$(sha256sum < "$f" | cut -d' ' -f1)" = "$sum" ] && ok "$rel has its sha256" || bad "$rel: sha256 differs or the file is missing"
done < <(kept_list)

fin
