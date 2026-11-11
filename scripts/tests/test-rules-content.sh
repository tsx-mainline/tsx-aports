#!/bin/bash
# Host test for scripts/check-rules-content.sh (the content check of a built
# .apk against uc-pxx/RULES-PINS) and its call in scripts/build.sh.
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
S=$HERE/scripts/check-rules-content.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
printf 'bootctl\n' > "$T/bootctl"; printf 'other\n' > "$T/other"
B=$(sha256sum "$T/bootctl" | cut -d' ' -f1)
# a boot image: header with kernel_size and page 2048, a 2 MiB shim, the "Linux Image"
python3 -I - "$T/img" <<'PY'
import struct, sys
page, shim, linux = 2048, b"\0" * 0x200000, b"LINUX IMAGE"
h = bytearray(page); h[0:8] = b"ANDROID!"; struct.pack_into("<I", h, 8, len(shim) + len(linux)); struct.pack_into("<I", h, 36, page)
open(sys.argv[1], "wb").write(bytes(h) + shim + linux)
PY
L=$(printf 'LINUX IMAGE' | sha256sum | cut -d' ' -f1)
printf '%s usr/sbin/uc-pxx-bootctl # test\n%s linux-image:boot/uc-pxx-lts.img # test\n' "$B" "$L" > "$T/list"
export TSX_RULES_PINS=$T/list
mk() { rm -rf "$T/r"; mkdir -p "$T/r"; "$@"; tar -czf "$T/p.apk" -C "$T/r" .; }
put() { mkdir -p "$T/r/$(dirname "$2")"; cp "$1" "$T/r/$2"; }
mk put "$T/bootctl" usr/sbin/uc-pxx-bootctl
sh "$S" "$T/p.apk" >/dev/null 2>&1 && ok "a listed bootctl passes" || bad "a listed bootctl refused"
mk put "$T/other" usr/sbin/uc-pxx-bootctl
sh "$S" "$T/p.apk" >/dev/null 2>&1 && bad "an unlisted bootctl passed" || ok "an unlisted bootctl refused (whatever the recipe declares)"
TSX_ALLOW_UNREVIEWED_PINS=1 sh "$S" "$T/p.apk" 2>&1 | grep -q WARNING && ok "the override warns" || bad "no warning with the override"
mk put "$T/other" usr/sbin/uc-pxx-arm-slot
sh "$S" "$T/p.apk" >/dev/null 2>&1 && bad "an unlisted arm-slot passed" || ok "an unlisted arm-slot refused"
mk put "$T/other" usr/local/sbin/uc-pxx-led
sh "$S" "$T/p.apk" >/dev/null 2>&1 && ok "a package without guarded files passes" || bad "an unguarded package refused"
mk put "$T/img" boot/uc-pxx-lts.img
sh "$S" "$T/p.apk" >/dev/null 2>&1 && ok "a listed kernel Image passes" || bad "a listed kernel Image refused"
python3 -I -c 'import sys; d = bytearray(open(sys.argv[1], "rb").read()); d[2048 + 0x200000] ^= 1; open(sys.argv[1], "wb").write(d)' "$T/img"; mk put "$T/img" boot/uc-pxx-lts.img
sh "$S" "$T/p.apk" >/dev/null 2>&1 && bad "an unlisted kernel Image passed" || ok "an unlisted kernel Image refused"
mk put "$T/other" usr/libexec/uc-pxx-step2/uc-pxx-step2
TSX_ALLOW_UNREVIEWED_PINS=1 sh "$S" "$T/p.apk" >/dev/null 2>&1 && bad "a step-2 file in a package passed" || ok "uc-pxx-step2 is never in a package, also with the override"
mk put "$T/other" usr/sbin/uc-pxx-bootctl-inst
TSX_ALLOW_UNREVIEWED_PINS=1 sh "$S" "$T/p.apk" >/dev/null 2>&1 && bad "bootctl-inst in a package passed" || ok "uc-pxx-bootctl-inst is never in a package"
mk sh -c "mkdir -p $T/r/usr/sbin; ln -s /bin/true $T/r/usr/sbin/uc-pxx-bootctl"
sh "$S" "$T/p.apk" >/dev/null 2>&1 && bad "a link at a guarded path passed" || ok "a link at a guarded path refused"
unset TSX_RULES_PINS
grep -q 'check-rules-content.sh" "$APKF"' "$HERE/scripts/build.sh" && ok "build.sh runs it on every built package" || bad "build.sh does not run it"
echo "$N ok, $F failed"
[ "$F" = 0 ]
