#!/bin/bash
# Host tests for the multi-DTB boot image checks (no panel, no build host):
#   - xx60/tsx-xx60-boot-tools/tsx-update-boot --check / --emmc (run with busybox sh
#     when available): refuses an image without this panel's DTB, before any write
#   - scripts/check-bootimg-dtbs.py (stage-kernel.sh's check of a staged image)
# Fake inputs: minimal FDT blobs that carry the board compatible strings, and
# Android boot images with a plain FDT or an AML_ container in "second".
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
UB=$REPO/xx60/tsx-xx60-boot-tools/tsx-update-boot
CHK=$REPO/scripts/check-bootimg-dtbs.py
SH=sh; command -v busybox >/dev/null && SH="busybox sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

python3 - "$T" <<'PY'
import os, struct, sys
t = sys.argv[1]
def fdt(compat, pad):
    # FDT_PROP token, length, nameoff (low byte '2', as in a real DTB) before the value
    body = b'\0' * 32 + struct.pack('>3I', 3, len(compat) + 18, 0x32) + compat + b'\0amlogic,meson8m2\0' \
        + b'\0\0\0\x03' + compat + b'-panel\0panel-lvds\0' + pad * 40
    return struct.pack('>2I', 0xd00dfeed, 8 + len(body)) + body
d10 = fdt(b'crestron,tsw1060', b'x'); d7 = fdt(b'crestron,tsw760', b'y')
os.makedirs(f'{t}/dtbs'); os.makedirs(f'{t}/dtbs1060')
for d, n, b in ((f'{t}/dtbs', 'meson8m2-crestron-tsw1060.dtb', d10), (f'{t}/dtbs', 'meson8m2-crestron-tsw760.dtb', d7),
                (f'{t}/dtbs1060', 'meson8m2-crestron-tsw1060.dtb', d10)):
    open(f'{d}/{n}', 'wb').write(b)
def swap4(b): return b''.join(b[i:i + 4][::-1] for i in range(0, len(b), 4))
def container(ents):
    hdr = (12 + 56 * len(ents) + 2047) // 2048 * 2048
    out = bytearray(b'AML_' + struct.pack('<2I', 2, len(ents)))
    blobs = b''; off = hdr
    for name, blob in ents:
        ids = name.split('_')
        for i in ids: out += swap4(i.encode().ljust(16, b' '))
        out += struct.pack('<2I', off, len(blob))
        blobs += blob + b'\0' * (-len(blob) % 4); off = hdr + len(blobs)
    return bytes(out.ljust(hdr, b'\0')) + blobs
def bootimg(second):
    ps = 2048; k = os.urandom(5000); r = os.urandom(3000)
    hdr = struct.pack('<8s10I', b'ANDROID!', len(k), 0x10008000, len(r), 0x11000000, len(second), 0x10f00000, 0x100, ps, 0, 0)
    pad = lambda b: b + b'\0' * (-len(b) % ps)
    return pad(hdr) + pad(k) + pad(r) + pad(second)
imgs = {
    'plain1060': bootimg(d10),
    'both': bootimg(container([('yushan_one_10inch', d10), ('yushan_one_7inch', d7), ('yushan_one_old10inch', d10), ('yushan_one_old7inch', d7)])),
    'only10': bootimg(container([('yushan_one_10inch', d10)])),
    'wrong7': bootimg(container([('yushan_one_10inch', d10), ('yushan_one_7inch', d10)])),
}
for n, b in imgs.items(): open(f'{t}/{n}.img', 'wb').write(b)
# a card head with the U-Boot env at 1 MiB (only the aml_dt string matters here)
env = b'\0\0\0\0' + b'bootcmd=x\0aml_dt=yushan_one_7inch\0lcdsize=7inch\0'
open(f'{t}/card7.bin', 'wb').write(b'\0' * 0x100000 + env.ljust(65536, b'\0'))
open(f'{t}/cmdline10', 'w').write('console=x androidboot.lcdsize=10inch androidboot.government=1\n')
PY

check() {  # check NAME AML_DT WANT(0|1) [env...]
	local n=$1 dt=$2 want=$3; shift 3
	out=$(env TSX_AML_DT="$dt" "$@" $SH "$UB" --check "$T/$n.img" 2>&1); rc=$?
	[ "$rc" = "$want" ] && ok "--check $n on ${dt:-<env>} -> $rc ($out)" || bad "--check $n on ${dt:-<env>} -> $rc, want $want ($out)"
}
check plain1060 yushan_one_10inch 0
check plain1060 yushan_one_7inch 1
check both yushan_one_10inch 0
check both yushan_one_7inch 0
check both yushan_one_old7inch 0
check only10 yushan_one_7inch 1
check only10 yushan_one_10inch 0
check wrong7 yushan_one_7inch 1
check both yushan_one_5inch 1
# aml_dt from the card env block, then from the kernel command line
check plain1060 "" 1 TSX_ENV_DEV="$T/card7.bin" TSX_CMDLINE=/dev/null
check both "" 0 TSX_ENV_DEV="$T/card7.bin" TSX_CMDLINE=/dev/null
check plain1060 "" 0 TSX_ENV_DEV=/dev/null TSX_CMDLINE="$T/cmdline10"
check plain1060 "" 1 TSX_ENV_DEV=/dev/null TSX_CMDLINE=/dev/null

# the write path refuses before it touches any device (no /dev/mmcblk1p7 on a host)
sha=$(sha256sum < "$T/plain1060.img" | cut -d' ' -f1)
out=$(TSX_AML_DT=yushan_one_7inch $SH "$UB" --emmc "$T/plain1060.img" "$sha" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'nothing written' <<<"$out" && ! grep -q 'saving the current' <<<"$out" \
	&& ok "--emmc refuses a TSW-1060-only image on a TSW-760, nothing written" || bad "--emmc on a TSW-760 with a 1060-only image: rc=$rc ($out)"
sha=$(sha256sum < "$T/both.img" | cut -d' ' -f1)
out=$(TSX_AML_DT=yushan_one_7inch $SH "$UB" --emmc "$T/both.img" "$sha" 2>&1); rc=$?
grep -q 'board check: OK' <<<"$out" && grep -q 'not the 32 MiB eMMC boot partition' <<<"$out" \
	&& ok "--emmc passes the board check with the container (then stops: no eMMC here)" || bad "--emmc with the container: rc=$rc ($out)"
out=$(TSX_AML_DT=yushan_one_7inch $SH "$UB" --any-board --emmc "$T/plain1060.img" "$(sha256sum < "$T/plain1060.img" | cut -d' ' -f1)" 2>&1)
grep -q 'board check skipped' <<<"$out" && ok "--any-board skips the check" || bad "--any-board ($out)"

# stage-kernel.sh's check of a staged image
cpy() { python3 "$CHK" "$T/$1.img" "$T/$2" >/dev/null 2>&1; echo $?; }
[ "$(cpy both dtbs)" = 0 ] && ok "check-bootimg-dtbs: container with both DTBs" || bad "check-bootimg-dtbs: container with both DTBs"
[ "$(cpy plain1060 dtbs)" = 1 ] && ok "check-bootimg-dtbs: plain FDT refused when the kernel has the TSW-760 DTB" || bad "check-bootimg-dtbs: plain FDT with a TSW-760 DTB"
[ "$(cpy wrong7 dtbs)" = 1 ] && ok "check-bootimg-dtbs: wrong 7inch entry refused" || bad "check-bootimg-dtbs: wrong 7inch entry"
[ "$(cpy plain1060 dtbs1060)" = 0 ] && ok "check-bootimg-dtbs: plain TSW-1060 FDT for a kernel without the TSW-760 DTB" || bad "check-bootimg-dtbs: plain 1060"
[ "$(cpy both dtbs1060)" = 1 ] && ok "check-bootimg-dtbs: container refused for a 1060-only kernel (not what mkimage.sh packs)" || bad "check-bootimg-dtbs: container for 1060-only"

echo "===== $PASS passed, $FAIL failed ====="
[ "$FAIL" = 0 ]
