#!/bin/bash
# Host test of the two-tree site (scripts/assemble-site.sh with the real
# scripts/index.sh and scripts/carry-forward.py). Packaging only: the fixture
# packages hold one text file. It builds them with abuild in a disposable
# Alpine container (like test-ci-pages.sh), signs with a throwaway fixture key,
# and walks through the deploys of the workflow:
#   1. stable deploy: both trees in the artifact, testing = stable.
#   2. testing deploy: the stable tree is byte-identical (also the indexes);
#      testing = stable + the newer testing packages; both trees verify.
#   3. promote: the exact bytes of the tested apk reach stable; promoted.txt
#      records name and sha256; stable is signed again; testing still complete.
#   4. a stable deploy that builds a newer version: testing drops its old copy.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1   # no .pyc in the work tree
HERE=$(cd "$(dirname "$0")/.." && pwd)
N=0 F=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }
fin() { echo "== $N ok, $F failed"; [ $F = 0 ] && echo PASS test-site || echo FAIL test-site; exit $F; }
command -v docker >/dev/null || { echo "no docker: skipped"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
openssl genrsa -out "$W/project.rsa" 4096 >/dev/null 2>&1
openssl rsa -in "$W/project.rsa" -pubout -out "$W/project.rsa.pub" >/dev/null 2>&1
mkdir -p "$W/keys" && cp "$W/project.rsa.pub" "$W/keys/"

# mkpkg NAME REL DESTDIR
mkpkg() {
	local b="$W/b-$1-$2"; mkdir -p "$b/common/$1"
	cat > "$b/common/$1/APKBUILD" <<APKBUILD
pkgname=$1
pkgver=1
pkgrel=$2
pkgdesc="test-site.sh fixture"
url="https://example.invalid"
arch=noarch
license="GPL-2.0-or-later"
package() { mkdir -p "\$pkgdir"/usr/share/$1; echo $2 > "\$pkgdir"/usr/share/$1/rel; }
APKBUILD
	docker run --rm --platform linux/arm/v7 -v "$b:/b" -v "$3:/out" -v "$W/project.rsa:/keys/project.rsa:ro" \
		-v "$W/project.rsa.pub:/keys/project.rsa.pub:ro" alpine:3.24 sh -euc '
		apk add --no-cache alpine-sdk >/dev/null
		cp /keys/project.rsa.pub /etc/apk/keys/
		mkdir -p /root/.abuild; echo PACKAGER_PRIVKEY=/keys/project.rsa > /root/.abuild/abuild.conf
		cd /b/common/'"$1"' && abuild -F -r -P /out
		chown -R '"$(id -u):$(id -g)"' /out /b' >"$W/mkpkg.log" 2>&1
}
STG=$W/built-stable; mkdir -p "$STG"
mkpkg tsx-fix 0 "$STG"; mkpkg tsx-fix 1 "$STG"
[ -f "$STG/common/armv7/tsx-fix-1-r1.apk" ] || { echo "  SKIPPED: could not build the fixture packages"; tail -n 15 "$W/mkpkg.log"; exit 0; }
TST=$W/built-testing; mkdir -p "$TST"; mkpkg tsx-fix 2 "$TST"; mkpkg tsx-new 1 "$TST"

# Scripts as in a checkout (index.sh finds keep/ next to itself: none here).
R=$W/repo; mkdir -p "$R/scripts"
cp "$HERE/index.sh" "$HERE/arch-image.sh" "$HERE/assemble-site.sh" "$HERE/channels.py" "$HERE/carry-forward.py" "$HERE/manifest.py" "$R/scripts/"
export TSX_APORTS_KEY=$W/project.rsa KEYS_DIR=$W/keys SITE_DOMAIN=site.example.invalid
CF="$R/scripts/carry-forward.py --keys $W/keys"
CH="$R/scripts/channels.py"
list() { (cd "$1" 2>/dev/null && ls common/armv7/*.apk 2>/dev/null | sed 's#.*/##' | tr '\n' ' '); }
# Run one deploy: DEPLOY MODE OUTDIR, with the inputs that the workflow makes.
site() { (cd "$R" && MANIFEST_FILE=${MF:-} PACKAGES_DIR=$P WORK_DIR=$K OUT_DIR=$1 scripts/assemble-site.sh "$2" >"$W/site.log" 2>&1); }

echo "== 1. stable deploy =="
P=$W/p1; K=$W/k1; mkdir -p "$P" "$K"; cp -r "$STG/." "$P/"
if site "$W/live1" stable; then
	[ -f "$W/live1/manifest.txt" ] && ! grep -q ' manifest.txt$' "$W/live1/manifest.txt" && grep -q ' v3.24/common/armv7/tsx-fix-1-r1.apk$' "$W/live1/manifest.txt" && grep -q ' testing/v3.24/common/armv7/APKINDEX.tar.gz$' "$W/live1/manifest.txt" \
		&& ok "manifest.txt lists the files of both trees" || bad "manifest: $(head -3 "$W/live1/manifest.txt")"
	[ -f "$W/live1/CNAME" ] && [ -f "$W/live1/promoted.txt" ] && ok "CNAME and promoted.txt in the artifact" || bad "CNAME or promoted.txt missing"
	[ "$(list "$W/live1/v3.24")" = "tsx-fix-1-r0.apk tsx-fix-1-r1.apk " ] && ok "stable keeps 2 versions: $(list "$W/live1/v3.24")" || bad "stable: $(list "$W/live1/v3.24")"
	[ "$(list "$W/live1/testing/v3.24")" = "tsx-fix-1-r1.apk " ] && ok "testing is complete (newest of stable): $(list "$W/live1/testing/v3.24")" || bad "testing: $(list "$W/live1/testing/v3.24")"
	cmp -s "$W/live1/v3.24/common/armv7/tsx-fix-1-r1.apk" "$W/live1/testing/v3.24/common/armv7/tsx-fix-1-r1.apk" && ok "the same bytes in both trees" || bad "bytes differ"
	$CF --from "$W/live1" --dest "$W/v1s" >/dev/null 2>&1 && $CF --from "$W/live1/testing" --dest "$W/v1t" >/dev/null 2>&1 && ok "both indexes verify against the key" || bad "index verify"
else bad "stable deploy: $(tail -5 "$W/site.log")"; fi

echo "== 2. testing deploy =="
# The workflow carries the live trees: stable to work/stable, testing to the build base.
K=$W/k2; P=$W/p2; mkdir -p "$K" "$P"
$CF --from "$W/live1" --dest "$K/stable" >/dev/null 2>&1; $CF --from "$W/live1/testing" --dest "$P" >/dev/null 2>&1
cp -r "$TST/." "$P/"      # the new builds (tsx-fix r2, tsx-new r1) arrive next to the testing base
cp "$W/live1/promoted.txt" "$K/promoted.txt"
# D3: a bad fetch of stable (an index that is not the live one) must stop a testing deploy,
# although the copy equals itself. The manifest of the last deploy is the truth.
cp "$K/stable/common/armv7/APKINDEX.tar.gz" "$W/idx.keep"; echo tampered >> "$K/stable/common/armv7/APKINDEX.tar.gz"
MF=$W/live1/manifest.txt site "$W/live2bad" testing && bad "a testing deploy accepted a stable index that is not the live one" || ok "a testing deploy stops when the fetched stable differs from the manifest"
cp "$W/idx.keep" "$K/stable/common/armv7/APKINDEX.tar.gz"; rm -rf "$W/live2bad"
MF=$W/live1/manifest.txt
if site "$W/live2" testing; then
	"$CH" same "$W/live1/v3.24" "$W/live2/v3.24" >/dev/null 2>&1 && ok "stable tree byte-identical before and after (apks and indexes)" || bad "stable changed: $("$CH" same "$W/live1/v3.24" "$W/live2/v3.24" 2>&1 | head -5)"
	[ "$(list "$W/live2/testing/v3.24")" = "tsx-fix-1-r2.apk tsx-new-1-r1.apk " ] && ok "testing has the newer r2: $(list "$W/live2/testing/v3.24")" || bad "testing: $(list "$W/live2/testing/v3.24")"
	[ -f "$W/live2/testing/v3.24/common/armv7/tsx-new-1-r1.apk" ] && ok "testing-only package present" || bad "tsx-new missing"
	[ ! -f "$W/live2/v3.24/common/armv7/tsx-new-1-r1.apk" ] && ok "stable has no testing package" || bad "tsx-new leaked into stable"
	$CF --from "$W/live2/testing" --dest "$W/v2t" >/dev/null 2>&1 && ok "testing index verifies and lists what is there" || bad "testing verify"
else bad "testing deploy: $(tail -5 "$W/site.log")"; fi

MF=
echo "== 3. promote =="
K=$W/k3; P=$W/p3; mkdir -p "$K" "$P"
$CF --from "$W/live2" --dest "$K/stable" >/dev/null 2>&1; $CF --from "$W/live2/testing" --dest "$K/testing-live" >/dev/null 2>&1
cp "$W/live2/promoted.txt" "$K/promoted.txt"
(cd "$R" && PROMOTE="tsx-fix" RUN_ID=77 PACKAGES_DIR=$P WORK_DIR=$K OUT_DIR=$W/live3 scripts/assemble-site.sh promote >"$W/site.log" 2>&1) && PR=ok || PR=bad
if [ $PR = ok ]; then
	cmp -s "$W/live3/v3.24/common/armv7/tsx-fix-1-r2.apk" "$W/live2/testing/v3.24/common/armv7/tsx-fix-1-r2.apk" && ok "stable has the exact bytes of the tested apk" || bad "promoted bytes differ"
	H=$(sha256sum "$W/live3/v3.24/common/armv7/tsx-fix-1-r2.apk" | cut -d' ' -f1)
	grep -q " 77 common/armv7/tsx-fix-1-r2.apk $H\$" "$W/live3/promoted.txt" && ok "promoted.txt records the name and the sha256" || bad "promoted.txt: $(cat "$W/live3/promoted.txt")"
	[ "$(list "$W/live3/v3.24")" = "tsx-fix-1-r1.apk tsx-fix-1-r2.apk " ] && ok "stable is indexed again: $(list "$W/live3/v3.24")" || bad "stable: $(list "$W/live3/v3.24")"
	$CF --from "$W/live3" --dest "$W/v3s" >/dev/null 2>&1 && ok "stable index verifies" || bad "stable verify"
	[ -f "$W/live3/testing/v3.24/common/armv7/tsx-new-1-r1.apk" ] && [ -f "$W/live3/testing/v3.24/common/armv7/tsx-fix-1-r2.apk" ] && ok "testing still complete (tsx-fix r2 from stable, tsx-new)" || bad "testing after promote: $(list "$W/live3/testing/v3.24")"
	cmp -s "$W/live3/testing/v3.24/common/armv7/tsx-fix-1-r2.apk" "$W/live3/v3.24/common/armv7/tsx-fix-1-r2.apk" && ok "the testing copy is the stable copy now" || bad "testing r2 differs"
	[ ! -f "$W/live3/testing/v3.24/common/armv7/tsx-fix-1-r1.apk" ] && ok "older version pruned from testing (keep 1)" || bad "r1 left in testing"
else bad "promote: $(tail -5 "$W/site.log")"; fi
(cd "$R" && PROMOTE="nothing-like-this" PACKAGES_DIR=$P WORK_DIR=$K OUT_DIR=$W/live3b scripts/assemble-site.sh promote >"$W/site.log" 2>&1) && bad "a bad promote name deployed" || ok "a bad promote name fails before any output"

echo "== 4. stable deploy builds a newer version =="
K=$W/k4; P=$W/p4; mkdir -p "$K" "$P"
$CF --from "$W/live3" --dest "$P" >/dev/null 2>&1; $CF --from "$W/live3/testing" --dest "$K/testing-live" >/dev/null 2>&1
cp "$W/live3/promoted.txt" "$K/promoted.txt"; mkpkg tsx-fix 3 "$P"
if site "$W/live4" stable; then
	[ "$(list "$W/live4/testing/v3.24")" = "tsx-fix-1-r3.apk tsx-new-1-r1.apk " ] && ok "testing = new stable r3 + the testing-only package" || bad "testing: $(list "$W/live4/testing/v3.24")"
	cmp -s "$W/live4/promoted.txt" "$W/live3/promoted.txt" && ok "promoted.txt carried forward" || bad "promoted.txt changed"
else bad "stable deploy 2: $(tail -5 "$W/site.log")"; fi
fin
