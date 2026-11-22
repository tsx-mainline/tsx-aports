#!/bin/bash
# Host test: the tsx-base floor of uc-pxx-board (BRIGHTNESS-CURVE-LEARN
# 2026-11-21, review MAJOR-1). The board with the stock curve needs the
# tsx_brightness.py 083e2cae... of tsx-linux-common 7d0e4a8 or later. The
# recipe names that tsx-base in _tsx_base_floor, and depends uses it. Until the
# release integration sets the version, the value is a placeholder and this
# test FAILS on purpose. It needs no network and no docker. With apk on the
# host (Alpine) it also checks that the floor is a valid version above
# 0.3.13_pre20261113 (the tsx-base of unit 2 before the change, d526aa34...).
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
R=$REPO/uc-pxx/uc-pxx-board/APKBUILD
N=0 F=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }
floor=$(sed -n 's/^_tsx_base_floor=//p' "$R" | tr -d "\"'")
deps=$(awk '/^depends="/ { d = 1 } d { print } d && /"$/ && NR > 0 && !/^depends="[^"]*$/ { exit }' "$R" | tr '\n' ' ')
[ -n "$floor" ] && ok "the recipe sets _tsx_base_floor ($floor)" || bad "no _tsx_base_floor in $R"
case $deps in *'tsx-base>=$_tsx_base_floor'*) ok "depends uses it: tsx-base>=\$_tsx_base_floor";;
	*) bad "depends does not use _tsx_base_floor: $deps";; esac
grep -q '083e2caeebd47289df1607906fe1fe7092d32e39b9789bc36ff5b1d7feb77dde' "$R" \
	&& ok "the recipe names the tsx_brightness.py that the floor must carry" || bad "the recipe does not name 083e2cae..."
case $floor in
*PLACEHOLDER*) bad "_tsx_base_floor is still the placeholder: the release integration sets the first tsx-base with tsx_brightness.py 083e2cae... (pkgver-rpkgrel)";;
*)
	if printf '%s' "$floor" | grep -Eq '^[0-9]+(\.[0-9]+)*(_(pre|p|rc)[0-9]+)*(-r[0-9]+)?$'; then ok "the floor has the form of an apk version"; else bad "the floor is not a version: $floor"; fi
	if command -v apk >/dev/null 2>&1; then
		apk version -c "$floor" >/dev/null 2>&1 && ok "apk accepts the floor" || bad "apk version -c refuses $floor"
		[ "$(apk version -t "$floor" 0.3.13_pre20261113-r0)" = ">" ] && ok "the floor is above 0.3.13_pre20261113-r0" || bad "the floor is not above 0.3.13_pre20261113-r0"
	else
		echo "  SKIPPED: no apk on this host (the apk version checks)"
	fi;;
esac
echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-board-tsx-base-floor || { echo FAIL test-board-tsx-base-floor; exit 1; }
