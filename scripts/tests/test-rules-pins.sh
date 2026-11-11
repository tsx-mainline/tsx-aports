#!/bin/bash
# Host test for scripts/check-rules-pins.sh and its call in scripts/build.sh.
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
S=$HERE/scripts/check-rules-pins.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
mk() { mkdir -p "$T/$1"; printf '%s\n' 'pkgname=x' '_pins="' "$2" '"' > "$T/$1/APKBUILD"; }
L=$HERE/uc-pxx/RULES-PINS
[ -f "$L" ] && ok "uc-pxx/RULES-PINS exists" || bad "no uc-pxx/RULES-PINS"
grep -v '^#' "$L" | awk 'NF < 2 || $1 !~ /^[0-9a-f]{64}$/ { e = 1 } END { exit e }' && ok "every RULES-PINS line is SHA256 PATH" || bad "a bad RULES-PINS line"
mk none ''
sh "$S" "$T/none/APKBUILD" >/dev/null 2>&1 && ok "a recipe without _pins passes" || bad "a recipe without _pins refused"
mk listed "a512a311af2ddfa8a08be74cb19c7aebee8d4de773f59e5c98885dc3924836f3 tag:x usr/sbin/uc-pxx-post-update"
sh "$S" "$T/listed/APKBUILD" >/dev/null 2>&1 && ok "a listed sha passes" || bad "a listed sha refused"
mk path "a512a311af2ddfa8a08be74cb19c7aebee8d4de773f59e5c98885dc3924836f3 tag:x usr/sbin/other"
sh "$S" "$T/path/APKBUILD" >/dev/null 2>&1 && bad "a listed sha with another path passed" || ok "a listed sha with another path refused"
mk new "26c3f1c0a375674f8a80b2536ed6765f85ae6b13724770767039a271650f786e tag:x usr/sbin/uc-pxx-arm-slot"
sh "$S" "$T/new/APKBUILD" >/dev/null 2>&1 && bad "an unlisted sha passed" || ok "an unlisted sha refused"
TSX_ALLOW_UNREVIEWED_PINS=1 sh "$S" "$T/new/APKBUILD" 2>&1 | grep -q WARNING && ok "TSX_ALLOW_UNREVIEWED_PINS=1 warns and passes" || bad "no warning with the override"
TSX_ALLOW_UNREVIEWED_PINS=yes sh "$S" "$T/new/APKBUILD" >/dev/null 2>&1 && bad "an override other than 1 passed" || ok "only the value 1 overrides"
sh "$S" "$HERE/uc-pxx/uc-pxx-boot-tools/APKBUILD" >/dev/null 2>&1 && st=pass || st=refused
v=$(sed -n 's/^pkgver=//p' "$HERE/uc-pxx/uc-pxx-boot-tools/APKBUILD")
case $v:$st in 0.1.*:pass|0.2.0:refused) ok "uc-pxx-boot-tools $v: $st (as the rules stand)";; *) bad "uc-pxx-boot-tools $v: $st";; esac
grep -qF 'check-rules-pins.sh" "$REPO/$PKGDIR/APKBUILD" || exit 1' "$HERE/scripts/build.sh" && ok "build.sh runs it before abuild" || bad "build.sh does not run it"
echo "$N ok, $F failed"
[ "$F" = 0 ]
