#!/bin/bash
# Host test of the sources and the pins of every APKBUILD. It needs no
# network and no docker.
#   1. Each source= item has a sha512sums line, and each sha512sums line has
#      a source= item. A local source file exists next to the APKBUILD.
#   2. The builddir of a recipe that downloads a GitHub tag archive is the
#      top directory of that archive (<repo>-<tag without a leading v>).
#   3. A kernel package names a release (_kbundle_tag), and its
#      _kernelrelease starts with the version of pkgver.
#   4. scripts/pin-kernel.sh, against a local server with a fixture bundle:
#      it writes the three values, and it refuses a bundle with a wrong
#      kernel.release, a wrong CHECKSUMS.sha256 and a missing release.
# A kernel sha512 of only zeros is a pending pin. The test shows a warning for
# it and does not fail. Run scripts/pin-kernel.sh before the release.
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

echo "== 1/2/3. the recipes =="
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
	case $P in tsx-xx60-kernel-*)
		case $KB in v[0-9]*) ok "$P: _kbundle_tag $KB";; *) bad "$P: _kbundle_tag is '$KB'";; esac
		case $KR in "${PV%%_*}"-[0-9]*-g[0-9a-f]*) ok "$P: _kernelrelease $KR fits pkgver $PV";; *) bad "$P: _kernelrelease '$KR' does not fit pkgver $PV";; esac
		if grep -q "^0\{128\}  " "$D/APKBUILD"; then warn "$P: the sha512 of the bundle is pending (run scripts/pin-kernel.sh $KB)"; fi;;
	esac
done

echo "== 4. pin-kernel.sh with a fixture release =="
if ! command -v zstd >/dev/null; then echo "  no zstd: section skipped"; fin; fi
W=$(mktemp -d); SRV=
trap '[ -n "$SRV" ] && kill $SRV 2>/dev/null; rm -rf "$W"' EXIT
R=$W/repo; mkdir -p "$R/scripts"
cp "$HERE/pin-kernel.sh" "$R/scripts/"
mkrepo() {   # FLAVOR
	local d=$R/xx60/tsx-xx60-kernel-$1; mkdir -p "$d"
	cat > "$d/APKBUILD" <<APKBUILD
pkgname=tsx-xx60-kernel-$1
pkgver=9.9.9_git20260101
pkgrel=1
_kernelrelease=9.9.9-00001-gaaaaaaaaaaaa
_kbundle_tag=UNRELEASED
sha512sums="
$(printf '0%.0s' $(seq 128))  tsx-xx60-kernel-$1-bundle.tar.zst
"
APKBUILD
}
# mkbundle TAG FLAVOR RELEASE [bad]: a fixture release asset
mkbundle() {
	local b=$W/b-$1-$2; rm -rf "$b"; mkdir -p "$b" "$W/rel/$1"
	echo "$3" > "$b/kernel.release"; echo "${3##*-g}0000000000000000000000000000" > "$b/kernel.commit"
	echo zimage > "$b/zImage"; echo mod > "$b/modules-$3.tar.gz"
	(cd "$b" && sha256sum zImage "modules-$3.tar.gz" > CHECKSUMS.sha256)
	[ "${4:-}" = bad ] && echo tampered > "$b/zImage"
	tar --zstd -cf "$W/rel/$1/tsx-xx60-kernel-$2-bundle.tar.zst" -C "$b" .
}
mkdir -p "$W/rel"
python3 -u -m http.server 0 --bind 127.0.0.1 -d "$W/rel" >"$W/srv.log" 2>&1 & SRV=$!
for _ in $(seq 50); do PORT=$(grep -oE 'port [0-9]+' "$W/srv.log" | head -1 | cut -d' ' -f2); [ -n "$PORT" ] && break; sleep 0.1; done
PIN() { (cd "$R" && PIN_BASE_URL="http://127.0.0.1:$PORT" scripts/pin-kernel.sh "$@" 2>&1); }

mkrepo lts; mkrepo stable
mkbundle v1.0.0 lts 9.9.9-00005-gbbbbbbbbbbbb; mkbundle v1.0.0 stable 9.9.9-00006-gcccccccccccc
if OUT=$(PIN v1.0.0); then
	A=$R/xx60/tsx-xx60-kernel-lts/APKBUILD
	grep -qx '_kbundle_tag=v1.0.0' "$A" && ok "_kbundle_tag written" || bad "tag: $(cat "$A")"
	grep -qx '_kernelrelease=9.9.9-00005-gbbbbbbbbbbbb' "$A" && ok "_kernelrelease taken from the bundle" || bad "release: $(cat "$A")"
	SUM=$(sha512sum "$W/rel/v1.0.0/tsx-xx60-kernel-lts-bundle.tar.zst" | cut -d' ' -f1)
	grep -qx "$SUM  tsx-xx60-kernel-lts-bundle.tar.zst" "$A" && ok "sha512 of the bundle written" || bad "sum: $(cat "$A")"
	grep -qx 'pkgrel=1' "$A" && ok "pkgrel untouched" || bad "pkgrel changed"
	cmp -s "$R/xx60/tsx-xx60-kernel-lts/dist/tsx-xx60-kernel-lts-bundle.tar.zst" "$W/rel/v1.0.0/tsx-xx60-kernel-lts-bundle.tar.zst" && ok "bundle copied to dist/" || bad "no dist copy"
	grep -qx '_kernelrelease=9.9.9-00006-gcccccccccccc' "$R/xx60/tsx-xx60-kernel-stable/APKBUILD" && ok "stable pinned too" || bad "stable not pinned"
else bad "pin v1.0.0: $OUT"; fi

mkrepo lts
mkbundle v1.0.1 lts 8.8.8-00005-gbbbbbbbbbbbb
OUT=$(PIN v1.0.1 lts); RC=$?
[ $RC != 0 ] && case "$OUT" in *"does not fit pkgver"*) ok "a kernel.release of another version is refused";; *) bad "wrong version message: $OUT";; esac || bad "wrong version accepted: $OUT"
grep -qx '_kbundle_tag=UNRELEASED' "$R/xx60/tsx-xx60-kernel-lts/APKBUILD" && ok "  ... the APKBUILD is unchanged" || bad "  ... the APKBUILD changed"
mkbundle v1.0.2 lts 9.9.9-00005-gbbbbbbbbbbbb bad
OUT=$(PIN v1.0.2 lts); RC=$?
[ $RC != 0 ] && case "$OUT" in *"CHECKSUMS.sha256"*) ok "a bundle with a wrong CHECKSUMS.sha256 is refused";; *) bad "checksums message: $OUT";; esac || bad "tampered bundle accepted: $OUT"
OUT=$(PIN v9.9.9 lts); RC=$?
[ $RC != 0 ] && case "$OUT" in *"cannot download"*) ok "a release that does not exist is refused";; *) bad "404 message: $OUT";; esac || bad "missing release accepted: $OUT"
fin
