#!/bin/bash
# Host test of uc-pxx-update-boot (uc-pxx/uc-pxx-boot-tools). It needs python3
# only: no network, no docker, no device. The test makes synthetic boot images
# (the package image without a resource, a stock-like boot_b image of header
# version 0 and 2, a resource with the layout of the stock one), a made-up
# /sys/class/block and /dev, and stub wrappers that log their calls.
#   1. offline: assemble, extract and inspect, and their refusals
#   2. not a panel: status and --hook read nothing and write nothing
#   3. a made-up panel: --hook, check, write --yes (the order arm-slot then
#      flash-boot, the sha256 of the image), a second write does nothing, a
#      failed arm-slot stops the write, a model mismatch, no --yes without a
#      terminal
#   4. the tool opens the device files read only (they have mode 0444)
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)   # scripts/tests -> scripts
REPO=$(cd "$HERE/.." && pwd)
TOOL=$REPO/uc-pxx/uc-pxx-boot-tools/uc-pxx-update-boot
N=0 F=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }
fin() { echo "== $N ok, $F failed"; [ $F = 0 ] && echo PASS test-uc-pxx-update-boot || echo FAIL test-uc-pxx-update-boot; exit $F; }
command -v python3 >/dev/null || { echo "no python3: test skipped"; exit 0; }
W=$(mktemp -d); trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
T() { python3 -I "$TOOL" "$@"; }

# fixtures: template.img (UC-P10, token ucpxx-test0001), template-p8.img,
# res.img (stock layout), bootb-v0.img and bootb-v2.img (res.img as second)
python3 -I - "$W" <<'PY'
import hashlib, struct, sys
W = sys.argv[1]
PAGE = 2048
def fdt(model):
    body = b"compatible\0" + model + b"\0rockchip,rk3399\0"
    blob = bytearray(struct.pack(">II", 0xd00dfeed, 40 + len(body)) + b"\0" * 32) + body
    return bytes(blob)
def shim(model, rel):
    k = bytearray(0x200000)
    d = fdt(model); k[0x10000:0x10000 + len(d)] = d
    return bytes(k) + b"\0" * 64 + b"Linux version " + rel + b" (build@uc-pxx-build) #1 SMP" + b"\0" * 4000
def pad(b, p=PAGE): return b + b"\0" * ((-len(b)) % p)
def bootimg(kernel, ramdisk, second, name, version=0, dtb=b"", second_addr=None, page=PAGE):
    base = 0x10000000
    sa = (base + 0xf00000) if second else 0
    if second_addr is not None: sa = second_addr
    s = hashlib.sha1()
    parts = [kernel, ramdisk, second] + ([b""] if version >= 1 else []) + ([dtb] if version >= 2 else [])
    for p in parts:
        s.update(p); s.update(struct.pack("<I", len(p)))
    h = bytearray(page)
    struct.pack_into("<8s10I16s512s32s", h, 0, b"ANDROID!", len(kernel), base + 0x8000, len(ramdisk), base + 0x1000000,
                     len(second), sa, base + 0x100, page, version, 0, name, b"console=ttyS2", s.digest())
    if version >= 1: struct.pack_into("<IQI", h, 1632, 0, 0, 1660)
    if version >= 2: struct.pack_into("<IQ", h, 1648, len(dtb), base + 0x1f00000)
    out = bytes(h) + pad(kernel, page) + pad(ramdisk, page) + pad(second, page)
    if version >= 2: out += pad(dtb, page)
    return out
def resource(entries):
    hdr = bytearray(512); hdr[0:4] = b"RSCE"
    struct.pack_into("<HHBBB", hdr, 4, 0, 0, 1, 1, 1); struct.pack_into("<I", hdr, 12, len(entries))
    ents, data, off = b"", b"", 1 + len(entries)
    for name, blob in entries:
        e = bytearray(512); e[0:4] = b"ENTR"; e[4:4 + len(name)] = name
        struct.pack_into("<II", e, 260, off, len(blob)); ents += bytes(e)
        data += pad(blob, 512); off += len(pad(blob, 512)) // 512
    return bytes(hdr) + ents + data
rd = b"\x1f\x8b" + b"\0" * 18
open(W + "/template.img", "wb").write(bootimg(shim(b"crestron,uc-p10", b"6.18.54-gabcdef123456"), rd, b"", b"ucpxx-test0001"))
open(W + "/template-p8.img", "wb").write(bootimg(shim(b"crestron,uc-p8", b"6.18.54-gabcdef123456"), rd, b"", b"ucpxx-test0001"))
res = resource([(b"rk-kernel.dtb", fdt(b"rockchip,rk3399-stock")), (b"logo.bmp", b"BM" + b"\x11" * 3000), (b"logo_kernel.bmp", b"BM" + b"\x22" * 3000)])
open(W + "/res.img", "wb").write(res)
open(W + "/res-nodtb.img", "wb").write(resource([(b"logo.bmp", b"BM")]))
stock_kernel = b"\x7fstock kernel" * 5000
open(W + "/bootb-v0.img", "wb").write(bootimg(stock_kernel, rd * 50, res, b"", page=PAGE))
open(W + "/bootb-v2.img", "wb").write(bootimg(stock_kernel, rd * 50, res, b"", version=2, dtb=fdt(b"x"), page=PAGE))
# a template that already has a second part, and one with a wrong id
open(W + "/template-res.img", "wb").write(bootimg(shim(b"crestron,uc-p10", b"6.18.54-gabcdef123456"), rd, res, b"ucpxx-test0001"))
b = bytearray(open(W + "/template.img", "rb").read()); b[600] ^= 1
open(W + "/template-badid.img", "wb").write(bytes(b))
PY

echo "== 1. offline: assemble, extract, inspect =="
OUT=$(T inspect "$W/template.img")
grep -qx 'token=ucpxx-test0001' <<<"$OUT" && grep -qx 'model=crestron,uc-p10' <<<"$OUT" && grep -qx 'release=6.18.54-gabcdef123456' <<<"$OUT" \
	&& ok "inspect: token, model and release" || bad "inspect: $OUT"
T inspect "$W/template-p8.img" | grep -qx 'model=crestron,uc-p8' && ok "inspect: the UC-P8 device tree" || bad "inspect p8"
T assemble "$W/template.img" "$W/res.img" "$W/a.img" >/dev/null && ok "assemble" || bad "assemble failed"
python3 -I - "$W" <<'PY' && ok "the new image: second part, second_addr, id, length, the rest unchanged" || bad "the new image is wrong"
import hashlib, struct, sys
W = sys.argv[1]
a = open(W + "/a.img", "rb").read(); t = open(W + "/template.img", "rb").read(); r = open(W + "/res.img", "rb").read()
f = struct.unpack_from("<8s10I16s512s32s", a, 0)
ks, rs, ss, sa, page = f[1], f[3], f[5], f[6], f[8]
pg = lambda n: (n + page - 1) // page
so = page * (1 + pg(ks) + pg(rs))
assert ss == len(r) and sa == 0x10f00000, (ss, hex(sa))
assert a[so:so + ss] == r and len(a) == so + pg(ss) * page
s = hashlib.sha1()
for o, n in ((page, ks), (page * (1 + pg(ks)), rs), (so, ss)):
    s.update(a[o:o + n]); s.update(struct.pack("<I", n))
assert f[13][:20] == s.digest()
assert a[32:576] == t[32:576] and a[608:so] == t[608:so]
PY
T extract "$W/a.img" "$W/r-back.img" >/dev/null && cmp -s "$W/r-back.img" "$W/res.img" && ok "extract gives the resource back" || bad "extract"
T extract "$W/bootb-v2.img" "$W/r-v2.img" >/dev/null && cmp -s "$W/r-v2.img" "$W/res.img" && ok "extract from a header version 2 image" || bad "extract v2"
OUT=$(T assemble "$W/template-res.img" "$W/res.img" "$W/x.img"); [ $? = 1 ] && grep -q "already has a second part" <<<"$OUT" && ok "refuse: the template already has a resource" || bad "template-res: $OUT"
OUT=$(T assemble "$W/template-badid.img" "$W/res.img" "$W/x.img"); [ $? = 1 ] && grep -q "id field" <<<"$OUT" && ok "refuse: a template with a wrong id" || bad "badid: $OUT"
OUT=$(T assemble "$W/template.img" "$W/res-nodtb.img" "$W/x.img"); [ $? = 1 ] && grep -q "rk-kernel.dtb" <<<"$OUT" && ok "refuse: a resource without rk-kernel.dtb" || bad "nodtb: $OUT"
OUT=$(T assemble "$W/template.img" "$W/template.img" "$W/x.img"); [ $? = 1 ] && grep -q "RSCE" <<<"$OUT" && ok "refuse: a resource without RSCE" || bad "norsce: $OUT"

# a made-up panel: sysfs, /dev, root, stubs
mkpanel() {   # BOOTB_FILE MODEL
	rm -rf "$W/p"; mkdir -p "$W/p/sys" "$W/p/dev" "$W/p/root" "$W/p/run" "$W/p/usr"
	local n name size
	for n in 13:boot_a:131072 14:boot_b:131072 22:system_a:3670016; do
		IFS=: read -r num name size <<<"$n"
		mkdir -p "$W/p/sys/mmcblk0p$num"
		printf 'MAJOR=179\nMINOR=%s\nDEVNAME=mmcblk0p%s\nDEVTYPE=partition\nPARTN=%s\nPARTNAME=%s\n' "$num" "$num" "$num" "$name" > "$W/p/sys/mmcblk0p$num/uevent"
		echo "$size" > "$W/p/sys/mmcblk0p$num/size"
		echo "179:$num" > "$W/p/sys/mmcblk0p$num/dev"
	done
	# system_a is the made-up root: its dev is the device of the root folder
	python3 -I -c 'import os,sys; st=os.stat(sys.argv[1]).st_dev; print("%d:%d" % (os.major(st), os.minor(st)))' "$W/p/root" > "$W/p/sys/mmcblk0p22/dev"
	head -c $((64 * 1024 * 1024)) /dev/zero > "$W/p/dev/mmcblk0p13"
	printf 'ANDROID!' | dd of="$W/p/dev/mmcblk0p13" conv=notrunc 2>/dev/null
	printf 'ucpxx-old00000' | dd of="$W/p/dev/mmcblk0p13" bs=1 seek=48 conv=notrunc 2>/dev/null
	cp "$1" "$W/p/dev/mmcblk0p14"
	chmod 444 "$W/p/dev/mmcblk0p13" "$W/p/dev/mmcblk0p14"
	printf '%s\0rockchip,rk3399\0' "$2" > "$W/p/compatible"
	cp "$W/template.img" "$W/p/usr/uc-pxx-lts.img"
	echo 6.18.54-gabcdef123456 > "$W/p/usr/kernel-lts.release"
	: > "$W/p/calls"
	cat > "$W/p/arm" <<EOF
#!/bin/sh
echo arm-slot >> "$W/p/calls"
exit \${ARM_RC:-0}
EOF
	cat > "$W/p/flash" <<EOF
#!/bin/sh
echo "flash-boot \$1 \$2 \$(sha256sum "\$1" | cut -d' ' -f1)" >> "$W/p/calls"
chmod u+w "$W/p/dev/mmcblk0p13"; dd if="\$1" of="$W/p/dev/mmcblk0p13" conv=notrunc 2>/dev/null; chmod 444 "$W/p/dev/mmcblk0p13"
EOF
	printf '#!/bin/sh\necho "current: A{prio 1 tries 0 succ 1}"\n' > "$W/p/bootctl"
	chmod 755 "$W/p/arm" "$W/p/flash" "$W/p/bootctl"
}
P() {
	UC_PXX_SYSBLOCK=$W/p/sys UC_PXX_DEVDIR=$W/p/dev UC_PXX_ROOT=$W/p/root UC_PXX_DT_COMPATIBLE=$W/p/compatible \
	UC_PXX_RUNDIR=$W/p/run UC_PXX_BOOT_IMAGE=$W/p/usr/uc-pxx-lts.img UC_PXX_RELEASE_FILE=$W/p/usr/kernel-lts.release \
	UC_PXX_ARM_SLOT=$W/p/arm UC_PXX_FLASH_BOOT=$W/p/flash UC_PXX_BOOTCTL=$W/p/bootctl UC_PXX_TEST_NONROOT=1 \
	python3 -I "$TOOL" "$@" </dev/null
}

echo "== 2. not a panel =="
mkpanel "$W/bootb-v0.img" crestron,uc-p10
echo "1:1" > "$W/p/sys/mmcblk0p22/dev"   # / is not system_a
OUT=$(P --hook); RC=$?
[ $RC = 0 ] && grep -q "not on an installed UC-P panel" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "--hook in a chroot: exit 0, nothing called" || bad "hook chroot: $RC $OUT"
OUT=$(P status); [ $? = 0 ] && grep -q "not on an installed UC-P panel" <<<"$OUT" && ok "status in a chroot" || bad "status chroot: $OUT"
OUT=$(P write --yes); [ $? = 1 ] && [ ! -s "$W/p/calls" ] && ok "write in a chroot: refused, nothing called" || bad "write chroot: $OUT"
mkpanel "$W/bootb-v0.img" crestron,uc-p10; : > "$W/p/root/.dockerenv"
OUT=$(P write --yes); [ $? = 1 ] && grep -q "in a container" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "write in a container: refused" || bad "write docker: $OUT"

echo "== 3. a made-up panel =="
mkpanel "$W/bootb-v0.img" crestron,uc-p10
OUT=$(P --hook); [ $? = 0 ] && grep -q "boot_a has token ucpxx-old00000" <<<"$OUT" && grep -q "uc-pxx-update-boot write" <<<"$OUT" && [ ! -s "$W/p/calls" ] \
	&& ok "--hook: says how to write, calls nothing" || bad "hook: $OUT"
OUT=$(P check); [ $? = 0 ] && [ -s "$W/p/run/boot-assembled.img" ] && [ ! -s "$W/p/calls" ] && ok "check: the image in the run folder, nothing called" || bad "check: $OUT"
T assemble "$W/template.img" "$W/res.img" "$W/want.img" >/dev/null
cmp -s "$W/p/run/boot-assembled.img" "$W/want.img" && ok "check: the image has the resource of boot_b" || bad "check: wrong image"
WANT=$(sha256sum "$W/want.img" | cut -d' ' -f1)
OUT=$(P write); [ $? = 1 ] && grep -q "use --yes" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "write without --yes and a terminal: refused" || bad "write no tty: $OUT"
OUT=$(P write --yes); RC=$?
EXP="arm-slot
flash-boot $W/p/run/boot-assembled.img $WANT $WANT"
[ $RC = 0 ] && [ "$(cat "$W/p/calls")" = "$EXP" ] && ok "write --yes: arm-slot, then flash-boot IMAGE SHA256" || bad "write: rc $RC, calls: $(cat "$W/p/calls") / $OUT"
[ ! -e "$W/p/run/boot-assembled.img" ] && ok "write: the image in the run folder is gone after the write" || bad "image left"
: > "$W/p/calls"
OUT=$(P write --yes); [ $? = 0 ] && grep -q "already holds this image" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "a second write does nothing" || bad "second write: $OUT"
OUT=$(P --hook); grep -q "already holds this kernel" <<<"$OUT" && ok "--hook after the write: boot_a holds the kernel" || bad "hook after: $OUT"
mkpanel "$W/bootb-v2.img" crestron,uc-p10
OUT=$(ARM_RC=1 P write --yes); RC=$?
[ $RC = 1 ] && [ "$(cat "$W/p/calls")" = arm-slot ] && grep -q "boot_a was not written" <<<"$OUT" && ok "a failed arm-slot stops the write (boot_b of header version 2)" || bad "arm fail: $RC $(cat "$W/p/calls") $OUT"
: > "$W/p/calls"
OUT=$(ARM_RC=3 P write --yes); RC=$?
[ $RC = 3 ] && grep -q "do NOT reboot" <<<"$OUT" && ! grep -q flash "$W/p/calls" && ok "arm-slot exit 3: exit 3, do not reboot, no flash" || bad "arm 3: $RC $OUT"
mkpanel "$W/bootb-v0.img" crestron,uc-p8
OUT=$(P write --yes); [ $? = 1 ] && grep -q "is for crestron,uc-p10, this unit is crestron,uc-p8" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "a model mismatch: refused" || bad "model: $OUT"
mkpanel "$W/template.img" crestron,uc-p10
OUT=$(P write --yes); [ $? = 1 ] && grep -q "no usable second part" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "boot_b without a resource: refused" || bad "no res: $OUT"
mkpanel "$W/bootb-v0.img" crestron,uc-p10; echo 6.18.99-gffffffffffff > "$W/p/usr/kernel-lts.release"
OUT=$(P write --yes); [ $? = 1 ] && grep -q "kernel-lts.release says" <<<"$OUT" && ok "a release file of another kernel: refused" || bad "release: $OUT"

echo "== 4. read only =="
mkpanel "$W/bootb-v0.img" crestron,uc-p10
P status >/dev/null && P check >/dev/null && P --hook >/dev/null && [ "$(stat -c %a "$W/p/dev/mmcblk0p13")" = 444 ] \
	&& ok "status, check and --hook work with read-only device files" || bad "read-only devices"
if grep -n "O_WRONLY\|O_RDWR\|\"wb\"\|'wb'" "$TOOL" | grep -v -e 'fd = os.open(tmp, os.O_WRONLY' -e 'with os.fdopen(fd, "wb")' -e 'with open(out, "wb")'; then
	bad "the tool opens another file for writing"
else ok "the only files the tool writes: the image in the run folder and the OUT of assemble and extract"; fi
fin
