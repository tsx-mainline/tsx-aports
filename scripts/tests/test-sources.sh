#!/bin/bash
# Host test of the sources and the pins of every APKBUILD. It needs no
# network and no docker.
#   1. Each source= item has a sha512sums line, and each sha512sums line has
#      a source= item. A local source file exists next to the APKBUILD.
#   2. The builddir of a recipe that downloads a GitHub tag archive is the
#      top directory of that archive (<repo>-<tag without a leading v>).
#   3. A kernel package names a release (_kbundle_tag), and its
#      _kernelrelease starts with the version of pkgver. An xx70 kernel
#      package names the tsx-aports release xx70-kernel-<date of pkgver>.
#   4. scripts/pin-kernel.sh, against a local server with a fixture bundle:
#      it writes the three values and keep/ (keep-pins.sh), and it refuses
#      a bundle with a wrong kernel.release, a wrong CHECKSUMS.sha256 and a
#      missing release.
#   6. The source policy (scripts/source-policy.sh): a commit source (the
#      GitHub archive of a full sha) is accepted on the testing channel and
#      refused on stable. The channel is TSX_APORTS_CHANNEL, else "testing"
#      on the git branch testing, else stable. A recipe with a commit source
#      has a pkgver with _pre<YYYYMMDD>, so the later tagged release sorts
#      newer, and its builddir is <repo>-<sha>.
#   0. The pkgdesc of each recipe has at most 128 characters (abuild refuses a
#      longer one: "pkgdesc is too long").
#   5. A recipe that keeps the file modes of a tag archive (cp -a or
#      stat -c %a) clears the group and other write bits. A kernel package
#      gives its module tree to root.
# A kernel sha512 of only zeros is a pending pin. The test shows a warning for
# it and does not fail. Run scripts/pin-kernel.sh before the release.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)   # scripts/tests -> scripts
REPO=$(cd "$HERE/.." && pwd)
. "$HERE/source-policy.sh"
if [ -z "${TSX_APORTS_CHANNEL:-}" ] && [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)" = testing ]; then
	TSX_APORTS_CHANNEL=testing
fi
CHANNEL=$(channel_name)
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
		echo "pkgdesclen ${#pkgdesc}"
		echo "builddir ${builddir:-$srcdir/$pkgname-$pkgver}"
		echo "kbundle ${_kbundle_tag:-}"
		echo "kernelrelease ${_kernelrelease:-}"
		for s in $source; do echo "source $s"; done
		echo "$sha512sums" | while read -r sum name; do [ -n "$sum" ] && echo "sum $sum $name"; done
	)
}

echo "== 1/2/3. the recipes =="
for D in "$REPO"/common/*/ "$REPO"/xx60/*/ "$REPO"/xx50/*/ "$REPO"/xx70/*/; do
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
			why=$(source_policy "$CHANNEL" "$u") && ok "$P: source policy ($CHANNEL) accepts $n" || bad "$P: $u: $why (channel $CHANNEL)"
			case "$u" in
			https://github.com/*/archive/[0-9a-f]*.tar.gz)
				if is_commit_source "$u"; then
					r=${u#https://github.com/*/}; repo=${r%%/*}; c=${u##*/archive/}; c=${c%.tar.gz}
					GH="$GH ${repo}-${c}"
					case $PV in *_pre20[0-9][0-9][01][0-9][0-3][0-9]*) ok "$P: commit source, pkgver $PV has _pre<date>";; *) bad "$P: a commit source needs _pre<YYYYMMDD> in pkgver (is $PV)";; esac
				fi;;
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
		pkgdesclen) DL=$a;;
	esac; done <<<"$V"
	[ "${DL:-0}" -le 128 ] && ok "$P: pkgdesc has $DL characters" || bad "$P: pkgdesc has $DL characters, abuild accepts 128"
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
	tsx-xx50-kernel-*)
		# The xx50 kernel release has no git suffix (6.18.54-tsx-xx50).
		case $KB in v[0-9]*) ok "$P: _kbundle_tag $KB";; *) bad "$P: _kbundle_tag is '$KB'";; esac
		case $KR in "${PV%%_*}"-*) ok "$P: _kernelrelease $KR fits pkgver $PV";; *) bad "$P: _kernelrelease '$KR' does not fit pkgver $PV";; esac;;
	tsx-xx70-kernel-*)
		# The bundle is an asset of a tsx-aports release xx70-kernel-<YYYYMMDD>
		# with the date of pkgver.
		case $KB in "xx70-kernel-${PV##*_git}") ok "$P: _kbundle_tag $KB";; *) bad "$P: _kbundle_tag is '$KB', expected xx70-kernel-${PV##*_git}";; esac
		case $KR in "${PV%%_*}"-[0-9]*-g[0-9a-f]*) ok "$P: _kernelrelease $KR fits pkgver $PV";; *) bad "$P: _kernelrelease '$KR' does not fit pkgver $PV";; esac;;
	esac
	if grep -q "^0\{128\}  " "$D/APKBUILD"; then
		case $P in tsx-xx60-kernel-*) ;; *) warn "$P: a sha512 is pending (all zeros): run abuild checksum after the tag or the release";; esac
	fi
done

echo "== 5. file modes =="
# A GitHub tag archive has group-writable files. tsx-config and the plugin
# loader of tsx-ha refuse a group-writable plugin. The bundle of a kernel
# release has the user of the CI runner as the owner of its files.
for D in "$REPO"/common/*/ "$REPO"/xx60/*/ "$REPO"/xx50/*/ "$REPO"/xx70/*/; do
	A=$D/APKBUILD; [ -f "$A" ] || continue; P=$(basename "$D")
	if grep -qE 'cp -a "\$builddir"|stat -c %a' "$A"; then
		grep -q 'chmod -R go-w "$pkgdir"$' "$A" && ok "$P: no group-writable files" || bad "$P: keeps the modes of the archive without chmod -R go-w"
	fi
	case $P in tsx-xx60-kernel-*|tsx-xx50-kernel-*|tsx-xx70-kernel-*)
		grep -q 'chown -R 0:0 "$pkgdir"/lib$' "$A" && grep -q 'chmod -R go-w "$pkgdir"/lib$' "$A" \
			&& ok "$P: root owns the module tree, no group-writable files" || bad "$P: the module tree keeps the owner or the modes of the bundle";;
	esac
done

echo "== 6. the source policy for commit sources =="
SHA=0123456789abcdef0123456789abcdef01234567
TAGU=https://github.com/o/r/archive/refs/tags/v1.0.0.tar.gz
COMU=https://github.com/o/r/archive/$SHA.tar.gz
source_policy stable "$TAGU" >/dev/null && ok "stable accepts a tag archive" || bad "stable refuses a tag"
source_policy testing "$TAGU" >/dev/null && ok "testing accepts a tag archive" || bad "testing refuses a tag"
source_policy testing "$COMU" >/dev/null && ok "testing accepts a full commit sha" || bad "testing refuses a commit"
W6=$(source_policy stable "$COMU") && bad "stable accepts a commit source" || ok "stable refuses a commit source: $W6"
for u in https://github.com/o/r/archive/main.tar.gz https://github.com/o/r/archive/refs/heads/main.tar.gz \
	https://github.com/o/r/archive/${SHA:0:12}.tar.gz https://github.com/o/r/archive/${SHA}0.tar.gz https://github.com/o/r/archive/${SHA^^}.tar.gz; do
	source_policy testing "$u" >/dev/null && bad "testing accepts $u" || ok "testing refuses ${u#https://github.com/o/r/archive/}"
done
# D7: forms that a glob let through
for u in "https://github.com/o/r/archive/refs/tags/x/../../../$SHA.tar.gz" "https://github.com/o/r/archive/refs/tags/v1.tar.gz?x=1" \
	"https://github.com/o/r/archive/refs/tags/v1%2e%2e/x.tar.gz" "http://github.com/o/r/archive/refs/tags/v1.tar.gz" \
	"https://github.com/o/r/archive/refs/tags/a/b.tar.gz"; do
	source_policy stable "$u" >/dev/null && bad "stable accepts $u" || ok "stable refuses ${u#https://github.com/o/r/archive/}"
	source_policy testing "$u" >/dev/null && bad "testing accepts $u" || ok "testing refuses ${u#https://github.com/o/r/archive/}"
done
for u in "https://codeload.github.com/o/r/tar.gz/$SHA" "https://raw.githubusercontent.com/o/r/$SHA/file"; do
	source_policy stable "$u" >/dev/null && bad "stable accepts $u" || ok "stable refuses ${u%%/o/r*}/... at a commit"
	source_policy testing "$u" >/dev/null && ok "testing accepts ${u%%/o/r*}/... at a commit" || bad "testing refuses $u"
done
source_policy stable "https://codeload.github.com/o/r/tar.gz/main" >/dev/null && bad "a branch at codeload accepted" || ok "a branch name at codeload is refused"
source_policy stable "HTTPS://GITHUB.com/o/r/archive/refs/tags/v1.tar.gz" >/dev/null && ok "scheme and host are compared in lower case" || bad "upper-case host refused"
source_policy stable "https://github.com/o/tsx-aports/releases/download/xx60-kernel-20261024/b.tar.zst" >/dev/null && ok "a release asset is allowed on stable" || bad "release asset refused"
# D7: the host must be exactly one of the three GitHub hosts
for u in "https://github.com:443/o/r/archive/refs/tags/v1.tar.gz" "https://github.com./o/r/archive/refs/tags/v1.tar.gz" \
	"https://user@github.com/o/r/archive/refs/tags/v1.tar.gz" "https://www.github.com/o/r/archive/refs/tags/v1.tar.gz" \
	"https://github.com.example.org/o/r/archive/refs/tags/v1.tar.gz" "https://raw.githubusercontent.com:443/o/r/$SHA/f"; do
	source_policy testing "$u" >/dev/null && bad "testing accepts the host of $u" || ok "a host that is not exactly a GitHub host is refused: ${u%%/o/r*}"
done
source_policy stable "https://example.org/x.tar.gz" >/dev/null && ok "an unrelated host is not checked" || bad "other host refused"
source_policy stable https://example.org/x.tar.gz >/dev/null && ok "a source that is not a GitHub archive is not checked" || bad "other URL refused"
# build.sh refuses a commit-source recipe before it builds anything.
T6=$(mktemp -d)
mkdir -p "$T6/scripts" "$T6/common/tsx-fixture-commit" "$T6/bin"
cp "$HERE/build.sh" "$HERE/arch-image.sh" "$HERE/source-policy.sh" "$T6/scripts/"
printf 'pkgname=tsx-fixture-commit\npkgver=1.1_pre20261026\npkgrel=0\narch=armv7\nsource="https://github.com/o/r/archive/%s.tar.gz"\n' "$SHA" > "$T6/common/tsx-fixture-commit/APKBUILD"
printf '#!/bin/sh\ncase "$1" in pull|tag|image) exit 0;; esac\ncase "$*" in *"apk --print-arch"*) echo armv7; exit 0;; esac\necho DOCKER-CALLED\n' > "$T6/bin/docker"; chmod +x "$T6/bin/docker"
touch "$T6/k" "$T6/k.pub"
B6() { (cd "$T6" && PATH="$T6/bin:$PATH" TSX_APORTS_KEY="$T6/k" TSX_APORTS_CHANNEL=$1 scripts/build.sh --all 2>&1); }
OUT=$(B6 stable) && bad "build.sh (stable) accepted a commit source" || case "$OUT" in *"testing branch only"*) ok "build.sh on stable refuses the commit source, no docker call";; *) bad "build.sh stable: $OUT";; esac
case "$OUT" in *DOCKER-CALLED*) bad "docker ran before the refusal";; esac
OUT=$(B6 testing); case "$OUT" in *"testing branch only"*) bad "build.sh on testing refused: $OUT";; *) ok "build.sh on testing passes the source policy";; esac
rm -rf "$T6"

echo "== 4. pin-kernel.sh with a fixture release =="
if ! command -v zstd >/dev/null; then echo "  no zstd: section skipped"; fin; fi
W=$(mktemp -d); SRV=
trap '[ -n "$SRV" ] && kill $SRV 2>/dev/null; rm -rf "$W"' EXIT
R=$W/repo; mkdir -p "$R/scripts"
cp "$HERE/pin-kernel.sh" "$HERE/keep-pins.sh" "$R/scripts/"
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
PIN() { (cd "$R" && PIN_BASE_URL="http://127.0.0.1:$PORT" PIN_RAW_URL="http://127.0.0.1:$PORT/raw" \
	PIN_TREE_URL="http://127.0.0.1:$PORT/tree" scripts/pin-kernel.sh "$@" 2>&1); }
# the packages.pin of the tag and a published tree with the pinned package (keep-pins.sh)
mkdir -p "$W/rel/raw/v1.0.0/rootfs/initramfs" "$W/rel/tree/common/armv7" "$W/rel/tree/xx60/armv7"
echo "tsx-splash=0.2.0-r1" > "$W/rel/raw/v1.0.0/rootfs/initramfs/packages.pin"
echo splash > "$W/rel/tree/common/armv7/tsx-splash-0.2.0-r1.apk"
printf 'P:tsx-splash\nV:0.2.0-r1\n\n' > "$W/APKINDEX"; tar -czf "$W/rel/tree/common/armv7/APKINDEX.tar.gz" -C "$W" APKINDEX
: > "$W/APKINDEX"; tar -czf "$W/rel/tree/xx60/armv7/APKINDEX.tar.gz" -C "$W" APKINDEX

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
	grep -q '^common/armv7/tsx-splash-0.2.0-r1.apk ' "$R/keep/keep.txt" 2>/dev/null && [ -s "$R/keep/v3.24/common/armv7/tsx-splash-0.2.0-r1.apk" ] \
		&& ok "keep/ follows the packages.pin of the tag (keep-pins.sh)" || bad "keep/ not written: $OUT"
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
