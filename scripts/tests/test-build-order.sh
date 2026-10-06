#!/bin/bash
# Host test of the build order of scripts/build.sh (order_dirs). It needs no
# network and no docker.
#   1. A fixture tree: a package comes after the packages that it depends on
#      or makes depends on, also through a subpackage and a provides, and also
#      from the other category. Unrelated packages keep their order. A cycle
#      stops with a message.
#   2. The real tree, for armv7 and aarch64: no package is built before one of
#      its depends or makedepends that a recipe of the same pass makes. The
#      known chains are also checked (for example tsx-base before
#      tsx-autoupdate, tsx-kiosk and tsx-setup before tsx-ha).
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)   # scripts/tests -> scripts
REPO=$(cd "$HERE/.." && pwd)
N=0 F=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }
fin() { echo "== $N ok, $F failed"; [ $F = 0 ] && echo PASS test-build-order || echo FAIL test-build-order; exit $F; }

# src_build ROOT: load the functions of ROOT/scripts/build.sh. The script sets
# REPO from $0, so set it again for ROOT.
src_build() { TSX_APORTS_BUILD_SH_SOURCE_ONLY=1 . "$1/scripts/build.sh"; REPO=$1; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

echo "== 1. fixture tree =="
R=$W/repo; mkdir -p "$R/scripts"; cp "$HERE/build.sh" "$HERE/arch-image.sh" "$R/scripts/"
mk() {   # DIR NAME DEPENDS MAKEDEPENDS [SUBPACKAGES] [PROVIDES]
	mkdir -p "$R/$1"
	printf 'pkgname=%s\npkgver=1\npkgrel=0\narch=noarch\ndepends="%s"\nmakedepends="%s"\nsubpackages="%s"\nprovides="%s"\n' "$2" "$3" "$4" "${5:-}" "${6:-}" > "$R/$1/APKBUILD"
}
mk common/a a "b>=1 busybox so:libc.so cmd:x" ""
mk common/b b "" "" "b-sub:_sub"
mk common/c c "b-sub" ""
mk common/d d "" "e"
mk common/e e "" "" "" "ee=1"
mk common/f f "ee" ""
mk common/g g "" ""
mk xx60/h h "a g" ""
mk xx60/i i "" ""
ORDER=$( (src_build "$R"; printf '%s\n' common/a common/b common/c common/d common/e common/f common/g xx60/h xx60/i | order_dirs) | tr '\n' ' ')
EXP="common/b common/a common/c common/e common/d common/f common/g xx60/h xx60/i "
[ "$ORDER" = "$EXP" ] && ok "dependency order, subpackage, provides, cross category, stable for the rest" || bad "order: $ORDER (expected $EXP)"
ORDER=$( (src_build "$R"; printf '%s\n' xx60/h common/a | order_dirs) | tr '\n' ' ')
case "$ORDER" in "common/a xx60/h ") ok "a dependency that is not in the list is not built (b is missing here)";; *) bad "partial list: $ORDER";; esac
mk common/a a "b" ""; mk common/b b "a" ""
OUT=$( (src_build "$R"; printf '%s\n' common/a common/b | order_dirs) 2>&1); RC=$?
[ $RC != 0 ] && case "$OUT" in *"dependency cycle"*) ok "a cycle stops with a message";; *) bad "cycle message: $OUT";; esac || bad "cycle accepted: $OUT"

echo "== 2. the real tree =="
for A in armv7 aarch64; do
	LIST=$(cd "$REPO" && src_build "$REPO" && case $A in armv7) CATS="common xx60";; *) CATS=common;; esac
		for D in $( (for c in $CATS; do find "$c" -mindepth 1 -maxdepth 1 -type d; done) | sort); do [ -n "$(pkg_arch "$D" "$A")" ] && echo "$D"; done)
	ORDERED=$(cd "$REPO" && src_build "$REPO" && printf '%s\n' "$LIST" | order_dirs)
	[ "$(echo "$LIST" | sort)" = "$(echo "$ORDERED" | sort)" ] && ok "$A: the order holds the same $(echo "$LIST" | wc -l) packages" || bad "$A: the order lost or added a package"
	# independent check: every local dependency comes before its package
	BADN=$(cd "$REPO" && src_build "$REPO" && {
		declare -A owner=() pos=(); i=0
		for D in $ORDERED; do pos[$D]=$i; i=$((i+1)); mapfile -t g < <(apkbuild_graph "$D"); for n in ${g[0]}; do owner[$n]=$D; done; done
		for D in $ORDERED; do mapfile -t g < <(apkbuild_graph "$D")
			for x in ${g[1]}; do n=${x%%[<>=~]*}; n=${n#!}; case $n in ""|*:*) continue;; esac
				o=${owner[$n]:-}; { [ -n "$o" ] && [ "$o" != "$D" ]; } || continue
				[ "${pos[$o]}" -lt "${pos[$D]}" ] || echo "$D needs $o"
			done
		done; })
	[ -z "$BADN" ] && ok "$A: every package comes after the packages it needs" || bad "$A: $BADN"
	pos() { echo "$ORDERED" | grep -nx "$1" | cut -d: -f1; }
	before() { [ -n "$(pos "$1")" ] && [ -n "$(pos "$2")" ] && [ "$(pos "$1")" -lt "$(pos "$2")" ]; }
	for pair in "common/tsx-base common/tsx-autoupdate" "common/tsx-kiosk common/tsx-ha" "common/tsx-setup common/tsx-ha" "common/tsx-idled common/tsx-kiosk" "common/tsx-splash common/tsx-kiosk" \
		"common/tensorflow-lite-c common/tsx-ha" "common/sendspin-cli common/tsx-ha" "common/tsx-base common/tsx-buttons"; do
		set -- $pair; before "$1" "$2" && ok "$A: $1 before $2" || bad "$A: $1 is not before $2"
	done
	if [ $A = armv7 ]; then
		for pair in "common/tsx-ha xx60/tsx-xx60-ha" "xx60/tsx-xx60-board xx60/tsx-xx60-console" "xx60/tsx-xx60-console xx60/tsx-xx60-kiosk" "xx60/tsx-xx60-board xx60/tsx-xx60-ha" \
			"xx60/tsx-xx60-kiosk xx60/tsx-xx60-ha" "xx60/tsx-xx60-chromium xx60/tsx-xx60-kiosk" "xx60/tsx-xx60-wlroots0.20 xx60/tsx-xx60-kiosk" "xx60/tsx-xx60-boot-tools xx60/tsx-xx60-kernel-lts" "common/tsx-ledbar xx60/tsx-xx60-console"; do
			set -- $pair; before "$1" "$2" && ok "$A: $1 before $2" || bad "$A: $1 is not before $2"
		done
	fi
done
fin
