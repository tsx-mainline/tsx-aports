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
mk new "fe581cf2212d8bc01ff54d1b88dc7d03601af075f56e74fb0d3edf2553a08056 tag:x etc/uc-pxx-mark-boot.sh"
sh "$S" "$T/new/APKBUILD" >/dev/null 2>&1 && bad "an unlisted sha passed" || ok "an unlisted sha refused"
TSX_ALLOW_UNREVIEWED_PINS=1 sh "$S" "$T/new/APKBUILD" 2>&1 | grep -q WARNING && ok "TSX_ALLOW_UNREVIEWED_PINS=1 warns and passes" || bad "no warning with the override"
TSX_ALLOW_UNREVIEWED_PINS=yes sh "$S" "$T/new/APKBUILD" >/dev/null 2>&1 && bad "an override other than 1 passed" || ok "only the value 1 overrides"
sh "$S" "$HERE/uc-pxx/uc-pxx-boot-tools/APKBUILD" >/dev/null 2>&1 && st=pass || st=refused
v=$(sed -n 's/^pkgver=//p' "$HERE/uc-pxx/uc-pxx-boot-tools/APKBUILD")
# From 0.2.1 (the arm-only-restart set: arm-slot 818e5d1b; 0.2.3 the kernel
# flavor; 0.2.4 also the reliable-write boot tools) the recipe passes only when
# RULES-PINS lists every one of its pins (sha256 and path), else the checker
# refuses it.
want=pass
case $v in
0.2.1|0.2.3|0.2.4)
	awk 'NF == 3 && $1 ~ /^[0-9a-f]{64}$/ { print $1, $3 }' "$HERE/uc-pxx/uc-pxx-boot-tools/APKBUILD" > "$T/pins"
	[ "$(wc -l < "$T/pins")" = 8 ] && ok "uc-pxx-boot-tools $v: eight pins" || bad "uc-pxx-boot-tools $v: not eight pins"
	while read -r s p; do
		awk -v s="$s" -v p="$p" '$1 == s && $2 == p { f = 1 } END { exit !f }' "$L" || want=refused
	done < "$T/pins";;
esac
case $v:$st in 0.1.*:pass|0.2.0:pass|0.2.1:"$want"|0.2.3:"$want"|0.2.4:"$want") ok "uc-pxx-boot-tools $v: $st (as the rules stand)";; *) bad "uc-pxx-boot-tools $v: $st";; esac
# The kernel packages have no _pins: scripts/check-rules-content.sh checks the
# Linux Image of each built kernel package against a linux-image line. From
# 7.3.5_git20261121 the rules name the Image of uc-pxx-kernel-stable, and the
# package needs the first boot tools that read KERNEL_FLAVOR (0.2.4).
grep -v '^#' "$L" | awk '$2 ~ /^linux-image:/ && $2 != "linux-image:boot/uc-pxx-lts.img" && $2 != "linux-image:boot/uc-pxx-stable.img" { e = 1 } END { exit e }' \
	&& ok "every linux-image line names boot/uc-pxx-lts.img or boot/uc-pxx-stable.img" || bad "a linux-image line with another path"
K=$HERE/uc-pxx/uc-pxx-kernel-stable/APKBUILD
if [ -f "$K" ]; then
	grep -qx 'depends="uc-pxx-boot-tools>=0.2.4-r0"' "$K" && ok "uc-pxx-kernel-stable depends on uc-pxx-boot-tools>=0.2.4-r0" || bad "uc-pxx-kernel-stable: not the depends on uc-pxx-boot-tools>=0.2.4-r0"
	grep -v '^#' "$L" | awk '$2 == "linux-image:boot/uc-pxx-stable.img" { f = 1 } END { exit !f }' \
		&& ok "uc-pxx-kernel-stable: RULES-PINS has a stable linux-image line (as the rules stand)" || bad "uc-pxx-kernel-stable: no stable linux-image line in RULES-PINS"
fi
grep -qF 'check-rules-pins.sh" "$REPO/$PKGDIR/APKBUILD" || exit 1' "$HERE/scripts/build.sh" && ok "build.sh runs it before abuild" || bad "build.sh does not run it"
echo "$N ok, $F failed"
[ "$F" = 0 ]
