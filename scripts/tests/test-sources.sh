#!/bin/bash
# Host test of the sources and the pins of every APKBUILD. It needs no
# network and no docker.
#   1. Each source= item has a sha512sums line, and each sha512sums line has
#      a source= item. A local source file exists next to the APKBUILD.
#   2. The builddir of a recipe that downloads a GitHub tag archive is the
#      top directory of that archive (<repo>-<tag without a leading v>).
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)   # scripts/tests -> scripts
REPO=$(cd "$HERE/.." && pwd)
N=0 F=0 WARN=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }
warn() { echo "  WARN: $*"; WARN=$((WARN + 1)); }
fin() { echo "== $N ok, $F failed, $WARN warnings"; [ $F = 0 ] && echo PASS test-sources || echo FAIL test-sources; exit $F; }

# recipe_vars APKBUILD-DIR: one "key value" line for each fact of the recipe.
recipe_vars() {
	(
		set +eu
		startdir=$1 srcdir=/s/src pkgdir=/s/pkg
		. "$1/APKBUILD" >/dev/null 2>&1
		echo "pkgname $pkgname"
		echo "pkgver $pkgver"
		echo "builddir ${builddir:-$srcdir/$pkgname-$pkgver}"
		echo "kbundle ${_kbundle_tag:-}"
		echo "kernelrelease ${_kernelrelease:-}"
		for s in $source; do echo "source $s"; done
		echo "$sha512sums" | while read -r sum name; do [ -n "$sum" ] && echo "sum $sum $name"; done
	)
}

echo "== 1/2. the recipes =="
for D in "$REPO"/common/*/ "$REPO"/xx60/*/; do
	[ -f "$D/APKBUILD" ] || continue
	P=$(basename "$D")
	V=$(recipe_vars "${D%/}")
	NAMES=; SUMS=; GH=
	while read -r k a b; do case $k in
		source)
			case "$a" in
			*::*) n=${a%%::*}; u=${a#*::};;
			http://*|https://*) n=$(basename "$a"); u=$a;;
			*) n=$a; u=;;
			esac
			NAMES="$NAMES $n"
			[ -n "$u" ] || [ -f "$D/$n" ] || bad "$P: the local source $n does not exist"
			case "$u" in
			https://github.com/*/archive/refs/tags/*.tar.gz)
				r=${u#https://github.com/*/}; repo=${r%%/*}; t=${u##*/refs/tags/}; t=${t%.tar.gz}
				GH="$GH ${repo}-${t#v}";;
			esac;;
		sum) SUMS="$SUMS $b"
			case $a in *[!0-9a-f]*|"") bad "$P: the sum of $b is not a sha512";; esac
			[ ${#a} = 128 ] || bad "$P: the sum of $b has ${#a} characters, not 128";;
		builddir) BD=$(basename "$a");;
		pkgname) PN=$a;;
		kbundle) KB=$a;;
		kernelrelease) KR=$a;;
		pkgver) PV=$a;;
	esac; done <<<"$V"
	[ -n "$NAMES" ] || continue
	MISSING=; for n in $NAMES; do case " $SUMS " in *" $n "*) ;; *) MISSING="$MISSING $n";; esac; done
	EXTRA=; for n in $SUMS; do case " $NAMES " in *" $n "*) ;; *) EXTRA="$EXTRA $n";; esac; done
	[ -z "$MISSING" ] && [ -z "$EXTRA" ] && ok "$P: sources and sha512sums agree" || bad "$P: no sum for:$MISSING, no source for:$EXTRA"
	if [ -n "$GH" ]; then
		case " $GH " in *" $BD "*) ok "$P: builddir $BD is the top directory of a tag archive";; *) bad "$P: builddir $BD is not in the tag archives (expected one of:$GH)";; esac
	fi
done

fin
