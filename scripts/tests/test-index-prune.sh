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

fin
