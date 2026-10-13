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
echo "== the kept files of this repo =="
KEEPDIR=$HERE/../keep
while read -r rel sum; do
	[ "$(sha256sum < "$KEEPDIR/v3.24/$rel" | cut -d' ' -f1)" = "$sum" ] && ok "keep/v3.24/$rel has its sha256" || bad "keep/v3.24/$rel: sha256 differs or the file is missing"
done < <(kept_list)

fin
