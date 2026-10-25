#!/bin/bash
# Host test of uc-pxx-update-boot (uc-pxx/uc-pxx-boot-tools). It needs python3
# only: no network, no docker, no device. The test makes synthetic boot images
# (package images with a real device tree, stock-like boot_b images of header
# version 0 and 2, resources with the layout of the stock one), a made-up
# /sys/class/block and /dev, and stub wrappers that log their calls.
#
# The tool accepts only the approved resource of each model, and it has no
# option to skip that check. So the tests that write need the real stock
# resource of the UC-P10 (a vendor file, never in a repository):
#   UC_PXX_TEST_STOCK_RESOURCE=/path/to/stock-resource.img
# Without it those tests are skipped and the test says so.
#   1. offline: assemble, extract, inspect, and their refusals (resource not
#      approved, a UC-P8, a token mismatch, an OUT that exists, is a link or
#      is in /dev)
#   2. not a panel: status and --hook read nothing and write nothing
#   3. the run folder: a link, another mode, a planted link
#   4. a made-up panel: --hook, check, write --yes (arm-slot, then flash-boot
#      with the exact file and sha256), a second write, the exit codes of the
#      wrappers, a model mismatch, no --yes without a terminal, the lock, a
#      closed stdout, the terminal signals during the flash
#   5. read only: the device files have mode 0444
#   6. as root only: the UC_PXX_* overrides have no effect (sections 2 to 5
#      need the overrides, so they run only as a normal user)
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)   # scripts/tests -> scripts
REPO=$(cd "$HERE/.." && pwd)
TOOL=$REPO/uc-pxx/uc-pxx-boot-tools/uc-pxx-update-boot
STOCK=${UC_PXX_TEST_STOCK_RESOURCE:-}
STOCK_SHA=290ef40577d434d702c3544076dbebd6ddd17e16087eff0e84c92549d67bb363
N=0 F=0 S=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }
skip() { echo "  SKIP: $*"; S=$((S + 1)); }
fin() { echo "== $N ok, $F failed, $S skipped"; [ $F = 0 ] && echo PASS test-uc-pxx-update-boot || echo FAIL test-uc-pxx-update-boot; exit $F; }
command -v python3 >/dev/null || { echo "no python3: test skipped"; exit 0; }
W=$(mktemp -d); trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
T() { python3 -I "$TOOL" "$@"; }
if [ -n "$STOCK" ]; then
	[ "$(sha256sum "$STOCK" | cut -d' ' -f1)" = "$STOCK_SHA" ] || { echo "UC_PXX_TEST_STOCK_RESOURCE is not the stock resource"; exit 1; }
	cp "$STOCK" "$W/stock.res"
fi

# fixtures: template.img (UC-P10, token ucpxx-test0001), template-p8.img,
# template-badtok.img (bootargs with another token), res-syn.img (a made-up
# resource with the stock layout), and boot_b images with each resource
python3 -I - "$W" <<'PY'
import hashlib, os, struct, sys
W = sys.argv[1]
PAGE = 2048
def fdt(nodes):
    """nodes: list of (path, {prop: bytes}); a minimal real flat device tree."""
    strings, soff = b"", {}
    def s_off(n):
        nonlocal strings
        if n not in soff:
            soff[n] = len(strings); strings += n.encode() + b"\0"
        return soff[n]
    def node(name, props, children):
        b = struct.pack(">I", 1) + name.encode() + b"\0"
        b += b"\0" * ((-len(b)) % 4)
        for k, v in props.items():
            b += struct.pack(">III", 3, len(v), s_off(k)) + v + b"\0" * ((-len(v)) % 4)
        for c in children: b += c
        return b + struct.pack(">I", 2)
    d = dict(nodes)
    st = node("", d["/"], [node("chosen", d.get("/chosen", {}), [])]) + struct.pack(">I", 9)
    off_st = 40 + 16
    off_str = off_st + len(st)
    total = off_str + len(strings)
    hdr = struct.pack(">10I", 0xd00dfeed, total, off_st, off_str, 40, 17, 16, 0, len(strings), len(st))
    return hdr + b"\0" * 16 + st + strings
def shim(model, rel, token):
    k = bytearray(0x200000)
    d = fdt([("/", {"compatible": model + b"\0rockchip,rk3399\0", "model": b"test\0"}),
             ("/chosen", {"bootargs": b"console=ttyS2,115200n8 panic=30 uc-pxx.id=" + token + b"\0"})])
    k[0x10000:0x10000 + len(d)] = d
    return bytes(k) + b"\0" * 64 + b"Linux version " + rel + b" (build@uc-pxx-build) #1 SMP" + b"\0" * 4000
def pad(b, p=PAGE): return b + b"\0" * ((-len(b)) % p)
def bootimg(kernel, ramdisk, second, name, version=0, dtb=b"", page=PAGE):
    base = 0x10000000
    sa = (base + 0xf00000) if second else 0
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
REL = b"6.18.54-gabcdef123456"
def w(name, data): open(os.path.join(W, name), "wb").write(data)
w("template.img", bootimg(shim(b"crestron,uc-p10", REL, b"ucpxx-test0001"), rd, b"", b"ucpxx-test0001"))
w("template-p8.img", bootimg(shim(b"crestron,uc-p8", REL, b"ucpxx-test0001"), rd, b"", b"ucpxx-test0001"))
w("template-badtok.img", bootimg(shim(b"crestron,uc-p10", REL, b"ucpxx-other001"), rd, b"", b"ucpxx-test0001"))
syn = resource([(b"rk-kernel.dtb", fdt([("/", {"compatible": b"rockchip,rk3399\0"})])), (b"logo.bmp", b"BM" + b"\x11" * 3000)])
w("res-syn.img", syn)
w("res-nodtb.img", resource([(b"logo.bmp", b"BM")]))
stock_kernel = b"\x7fstock kernel" * 5000
w("bootb-syn.img", bootimg(stock_kernel, rd * 50, syn, b""))
p = os.path.join(W, "stock.res")
if os.path.exists(p):
    stock = open(p, "rb").read()
    w("bootb-v0.img", bootimg(stock_kernel, rd * 50, stock, b""))
    w("bootb-v2.img", bootimg(stock_kernel, rd * 50, stock, b"", version=2, dtb=b"\xd0\x0d\xfe\xed" + b"\0" * 60))
    w("template-res.img", bootimg(shim(b"crestron,uc-p10", REL, b"ucpxx-test0001"), rd, stock, b"ucpxx-test0001"))
b = bytearray(open(os.path.join(W, "template.img"), "rb").read()); b[600] ^= 1
w("template-badid.img", bytes(b))
PY

echo "== 1. offline: assemble, extract, inspect =="
OUT=$(T inspect "$W/template.img")
grep -qx 'token=ucpxx-test0001' <<<"$OUT" && grep -qx 'model=crestron,uc-p10' <<<"$OUT" && grep -qx 'release=6.18.54-gabcdef123456' <<<"$OUT" \
	&& ok "inspect: token, model and release" || bad "inspect: $OUT"
T inspect "$W/template-p8.img" | grep -qx 'model=crestron,uc-p8' && ok "inspect: the UC-P8 device tree" || bad "inspect p8"
OUT=$(T inspect "$W/template-badtok.img"); [ $? = 1 ] && grep -q "uc-pxx.id=ucpxx-other001, the header has ucpxx-test0001" <<<"$OUT" \
	&& ok "refuse: uc-pxx.id of the command line differs from the header token" || bad "badtok: $OUT"
OUT=$(T assemble "$W/template.img" "$W/res-syn.img" "$W/x.img"); [ $? = 1 ] && grep -q "not the approved resource of crestron,uc-p10" <<<"$OUT" && [ ! -e "$W/x.img" ] \
	&& ok "refuse: a resource that is not approved (no OUT made)" || bad "syn res: $OUT"
OUT=$(T assemble "$W/template-badid.img" "$W/res-syn.img" "$W/x.img"); [ $? = 1 ] && grep -q "id field" <<<"$OUT" && ok "refuse: a template with a wrong id" || bad "badid: $OUT"
OUT=$(T assemble "$W/template.img" "$W/res-nodtb.img" "$W/x.img"); [ $? = 1 ] && grep -q "rk-kernel.dtb" <<<"$OUT" && ok "refuse: a resource without rk-kernel.dtb" || bad "nodtb: $OUT"
OUT=$(T assemble "$W/template.img" "$W/template.img" "$W/x.img"); [ $? = 1 ] && grep -q "RSCE" <<<"$OUT" && ok "refuse: a resource without RSCE" || bad "norsce: $OUT"
OUT=$(T extract "$W/bootb-syn.img" "$W/r-syn.img"); [ $? = 0 ] && cmp -s "$W/r-syn.img" "$W/res-syn.img" && grep -q "NOT approved for any model" <<<"$OUT" \
	&& ok "extract: writes the resource and says that it is not approved" || bad "extract syn: $OUT"
OUT=$(T extract "$W/bootb-syn.img" "$W/r-syn.img"); [ $? = 1 ] && grep -q "exists" <<<"$OUT" && ok "refuse: extract to an OUT that exists" || bad "exists: $OUT"
echo keep > "$W/victim"; ln -s "$W/victim" "$W/link.img"
OUT=$(T extract "$W/bootb-syn.img" "$W/link.img"); [ $? = 1 ] && [ "$(cat "$W/victim")" = keep ] && ok "refuse: extract to a link (the target stays)" || bad "link: $OUT"
OUT=$(T extract "$W/bootb-syn.img" /dev/null); [ $? = 1 ] && grep -q "in /dev" <<<"$OUT" && ok "refuse: extract to a path in /dev" || bad "dev: $OUT"
OUT=$(T extract "$W/bootb-syn.img" /dev/shm/uc-pxx-test-$$); RC=$?; rm -f /dev/shm/uc-pxx-test-$$
[ $RC = 1 ] && ok "refuse: extract to a new file in /dev" || bad "dev new: $OUT"
if [ -n "$STOCK" ]; then
	T assemble "$W/template.img" "$W/stock.res" "$W/a.img" >/dev/null && ok "assemble with the approved resource" || bad "assemble failed"
	python3 -I - "$W" <<'PY' && ok "the new image: second part, second_addr, id, length, the rest unchanged" || bad "the new image is wrong"
import hashlib, struct, sys
W = sys.argv[1]
a = open(W + "/a.img", "rb").read(); t = open(W + "/template.img", "rb").read(); r = open(W + "/stock.res", "rb").read()
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
	OUT=$(T assemble "$W/template.img" "$W/stock.res" "$W/a.img"); [ $? = 1 ] && grep -q exists <<<"$OUT" && ok "refuse: assemble to an OUT that exists" || bad "assemble exists: $OUT"
	OUT=$(T assemble "$W/template-p8.img" "$W/stock.res" "$W/p8.img"); [ $? = 1 ] && grep -q "no resource is approved for crestron,uc-p8" <<<"$OUT" \
		&& ok "refuse: a UC-P8 image (no approved resource)" || bad "p8: $OUT"
	OUT=$(T assemble "$W/template-res.img" "$W/stock.res" "$W/x2.img"); [ $? = 1 ] && grep -q "already has a second part" <<<"$OUT" && ok "refuse: the template already has a resource" || bad "template-res: $OUT"
	T extract "$W/bootb-v2.img" "$W/r-v2.img" | grep -q "approved for crestron,uc-p10" && cmp -s "$W/r-v2.img" "$W/stock.res" && ok "extract from a header version 2 image" || bad "extract v2"
else
	skip "assemble with the approved resource (no UC_PXX_TEST_STOCK_RESOURCE)"
fi

# a made-up panel: sysfs, /dev, root, stubs. The run folder is not made here.
mkpanel() {   # BOOTB_FILE MODEL
	rm -rf "$W/p"; mkdir -p "$W/p/sys" "$W/p/dev" "$W/p/root" "$W/p/usr"
	local n num name size
	for n in 9:misc:2048 13:boot_a:131072 14:boot_b:131072 22:system_a:3670016; do
		IFS=: read -r num name size <<<"$n"
		mkdir -p "$W/p/sys/mmcblk0p$num"
		printf 'MAJOR=179\nMINOR=%s\nDEVNAME=mmcblk0p%s\nDEVTYPE=partition\nPARTN=%s\nPARTNAME=%s\n' "$num" "$num" "$num" "$name" > "$W/p/sys/mmcblk0p$num/uevent"
		echo "$size" > "$W/p/sys/mmcblk0p$num/size"
		echo "179:$num" > "$W/p/sys/mmcblk0p$num/dev"
	done
	python3 -I -c 'import os,sys; st=os.stat(sys.argv[1]).st_dev; print("%d:%d" % (os.major(st), os.minor(st)))' "$W/p/root" > "$W/p/sys/mmcblk0p22/dev"
	head -c $((64 * 1024 * 1024)) /dev/zero > "$W/p/dev/mmcblk0p13"
	printf 'ANDROID!' | dd of="$W/p/dev/mmcblk0p13" conv=notrunc 2>/dev/null
	printf 'ucpxx-old00000' | dd of="$W/p/dev/mmcblk0p13" bs=1 seek=48 conv=notrunc 2>/dev/null
	head -c 1048576 /dev/zero > "$W/p/dev/mmcblk0p9"
	cp "$1" "$W/p/dev/mmcblk0p14"
	chmod 444 "$W/p/dev/mmcblk0p13" "$W/p/dev/mmcblk0p14" "$W/p/dev/mmcblk0p9"
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
echo "flash-start \$1 \$2 \$(sha256sum "\$1" | cut -d' ' -f1)" >> "$W/p/calls"
[ -n "\${FLASH_SLEEP:-}" ] && sleep "\$FLASH_SLEEP"
chmod u+w "$W/p/dev/mmcblk0p13"; dd if="\$1" of="$W/p/dev/mmcblk0p13" conv=notrunc 2>/dev/null; chmod 444 "$W/p/dev/mmcblk0p13"
echo "flash-end" >> "$W/p/calls"
exit \${FLASH_RC:-0}
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
miscsum() { sha256sum "$W/p/dev/mmcblk0p9" | cut -d' ' -f1; }

# The made-up panel needs the UC_PXX_* paths, and the tool ignores them as
# root. So sections 2 to 5 run only as a normal user.
if [ "$(id -u)" = 0 ]; then
	skip "sections 2 to 5 (made-up panel): the tool ignores the UC_PXX_* paths as root"
else
echo "== 2. not a panel =="
mkpanel "$W/bootb-syn.img" crestron,uc-p10
echo "1:1" > "$W/p/sys/mmcblk0p22/dev"   # / is not system_a
OUT=$(P --hook); RC=$?
[ $RC = 0 ] && grep -q "not on an installed UC-P panel" <<<"$OUT" && [ ! -s "$W/p/calls" ] && [ ! -e "$W/p/run" ] && ok "--hook in a chroot: exit 0, nothing called, no run folder" || bad "hook chroot: $RC $OUT"
OUT=$(P status); [ $? = 0 ] && grep -q "not on an installed UC-P panel" <<<"$OUT" && ok "status in a chroot" || bad "status chroot: $OUT"
OUT=$(P write --yes); [ $? = 1 ] && [ ! -s "$W/p/calls" ] && ok "write in a chroot: exit 1, nothing called" || bad "write chroot: $OUT"
mkpanel "$W/bootb-syn.img" crestron,uc-p10; : > "$W/p/root/.dockerenv"
OUT=$(P write --yes); [ $? = 1 ] && grep -q "in a container" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "write in a container: refused" || bad "write docker: $OUT"

echo "== 3. the run folder =="
mkpanel "$W/bootb-syn.img" crestron,uc-p10
ln -s "$W/p/dev" "$W/p/run"
OUT=$(P check); [ $? = 1 ] && grep -q "not a folder" <<<"$OUT" && [ -z "$(find "$W/p/dev" -newer "$W/p/calls" -type f)" ] && ok "refuse: the run folder is a link" || bad "run link: $OUT"
rm "$W/p/run"; mkdir -m 755 "$W/p/run"
OUT=$(P check); [ $? = 1 ] && grep -q "has mode 755, not 700" <<<"$OUT" && ok "refuse: the run folder has mode 755" || bad "run mode: $OUT"
rmdir "$W/p/run"
OUT=$(P check); [ -d "$W/p/run" ] && [ "$(stat -c %a "$W/p/run")" = 700 ] && ok "the tool makes the run folder with mode 700" || bad "run made: $OUT"
if [ -n "$STOCK" ]; then
	mkpanel "$W/bootb-v0.img" crestron,uc-p10; mkdir -m 700 "$W/p/run"
	M0=$(miscsum)
	ln -s "$W/p/dev/mmcblk0p9" "$W/p/run/boot-assembled.img.new"; ln -s "$W/p/dev/mmcblk0p9" "$W/p/run/boot-assembled.img"
	OUT=$(P check); [ $? = 0 ] && [ "$(miscsum)" = "$M0" ] && [ ! -L "$W/p/run/boot-assembled.img.new" ] && ok "planted links in the run folder: removed, the target is unchanged" || bad "planted: $OUT"
else
	skip "planted links (no UC_PXX_TEST_STOCK_RESOURCE)"
fi

echo "== 4. a made-up panel =="
mkpanel "$W/bootb-syn.img" crestron,uc-p10
OUT=$(P --hook); [ $? = 0 ] && grep -q "boot_a has token ucpxx-old00000" <<<"$OUT" && grep -q "uc-pxx-update-boot write" <<<"$OUT" && [ ! -s "$W/p/calls" ] \
	&& ok "--hook: says how to write, calls nothing" || bad "hook: $OUT"
OUT=$(P write --yes); [ $? = 1 ] && grep -q "not the approved resource" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "write: a boot_b resource that is not approved: exit 1, nothing called" || bad "write syn: $OUT"
OUT=$(P check); [ $? = 1 ] && grep -q "not the approved resource" <<<"$OUT" && [ -z "$(ls "$W/p/run" | grep -v '^lock$')" ] && ok "check: the same, no image file" || bad "check syn: $OUT"
if [ -z "$STOCK" ]; then
	skip "the write paths with the approved resource (no UC_PXX_TEST_STOCK_RESOURCE)"
else
	mkpanel "$W/bootb-v0.img" crestron,uc-p10
	OUT=$(P check); RC=$?; IMG=$(ls "$W/p/run"/boot-*.img 2>/dev/null)
	[ $RC = 0 ] && [ -n "$IMG" ] && [ ! -s "$W/p/calls" ] && ok "check: the image in the run folder, nothing called" || bad "check: $OUT"
	T assemble "$W/template.img" "$W/stock.res" "$W/want.img" >/dev/null
	cmp -s "$IMG" "$W/want.img" && ok "check: the image has the resource of boot_b" || bad "check: wrong image"
	WANT=$(sha256sum "$W/want.img" | cut -d' ' -f1)
	OUT=$(P write); [ $? = 1 ] && grep -q "use --yes" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "write without --yes and a terminal: refused" || bad "write no tty: $OUT"
	OUT=$(P write --yes); RC=$?
	FP=$(sed -n 's/^flash-start \([^ ]*\) .*/\1/p' "$W/p/calls")
	EXP="arm-slot
flash-start $FP $WANT $WANT
flash-end"
	[ $RC = 0 ] && [ "$(cat "$W/p/calls")" = "$EXP" ] && case $FP in "$W/p/run/boot-"*.img) true;; *) false;; esac \
		&& ok "write --yes: arm-slot, then flash-boot with a unique file of the run folder and its sha256" || bad "write: rc $RC, calls: $(cat "$W/p/calls") / $OUT"
	[ ! -e "$FP" ] && ok "write: the image file is gone after the write" || bad "image left"
	: > "$W/p/calls"
	OUT=$(P write --yes); [ $? = 0 ] && grep -q "already holds this image" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "a second write does nothing" || bad "second write: $OUT"
	OUT=$(P --hook); grep -q "already holds this kernel" <<<"$OUT" && ok "--hook after the write: boot_a holds the kernel" || bad "hook after: $OUT"
	for c in "1 11" "3 13"; do
		set -- $c; mkpanel "$W/bootb-v2.img" crestron,uc-p10
		OUT=$(ARM_RC=$1 P write --yes); RC=$?
		[ $RC = "$2" ] && [ "$(cat "$W/p/calls")" = arm-slot ] && grep -q "boot_a was not written" <<<"$OUT" && ok "arm-slot exit $1: exit $2, no flash (boot_b of header version 2)" || bad "arm $1: $RC $(cat "$W/p/calls") $OUT"
	done
	grep -q "do NOT reboot" <<<"$OUT" && ok "arm-slot exit 3: says do not reboot" || bad "arm 3 message"
	for c in "1 21" "4 24"; do
		set -- $c; mkpanel "$W/bootb-v0.img" crestron,uc-p10
		OUT=$(FLASH_RC=$1 P write --yes); RC=$?
		[ $RC = "$2" ] && grep -q "Slot A was armed (trying)" <<<"$OUT" && ok "flash-boot exit $1: exit $2 and the slot state" || bad "flash $1: $RC $OUT"
	done
	mkpanel "$W/bootb-v0.img" crestron,uc-p8
	OUT=$(P write --yes); [ $? = 1 ] && grep -q "is for crestron,uc-p10, this unit is crestron,uc-p8" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "a model mismatch: refused" || bad "model: $OUT"
	mkpanel "$W/template.img" crestron,uc-p10
	OUT=$(P write --yes); [ $? = 1 ] && grep -q "no usable second part" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "boot_b without a resource: refused" || bad "no res: $OUT"
	mkpanel "$W/bootb-v0.img" crestron,uc-p10; echo 6.18.99-gffffffffffff > "$W/p/usr/kernel-lts.release"
	OUT=$(P write --yes); [ $? = 1 ] && grep -q "kernel-lts.release says" <<<"$OUT" && ok "a release file of another kernel: refused" || bad "release: $OUT"
	mkpanel "$W/bootb-v0.img" crestron,uc-p10; mkdir -m 700 "$W/p/run"
	python3 -I -c 'import fcntl,os,sys,time; fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT, 0o600); fcntl.flock(fd, fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(5)' "$W/p/run/lock" "$W/p/locked" &
	LP=$!; for _ in $(seq 50); do [ -e "$W/p/locked" ] && break; sleep 0.1; done
	OUT=$(P write --yes); RC=$?; kill $LP 2>/dev/null; wait $LP 2>/dev/null
	[ $RC = 1 ] && grep -q "another uc-pxx-update-boot runs" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "a second run while the lock is held: refused" || bad "lock: $RC $OUT"
	mkpanel "$W/bootb-v0.img" crestron,uc-p10
	P write --yes 2>"$W/err" | head -n 1 >/dev/null; RC=${PIPESTATUS[0]}
	[ "$RC" = 0 ] && ! grep -q Traceback "$W/err" && grep -q flash-end "$W/p/calls" && ok "a closed stdout (| head -n 1): no traceback, the write completes" || bad "pipe: rc $RC $(cat "$W/err")"
	mkpanel "$W/bootb-v0.img" crestron,uc-p10
	FLASH_SLEEP=3 setsid bash -c 'exec "$@" </dev/null' _ env UC_PXX_SYSBLOCK="$W/p/sys" UC_PXX_DEVDIR="$W/p/dev" UC_PXX_ROOT="$W/p/root" \
		UC_PXX_DT_COMPATIBLE="$W/p/compatible" UC_PXX_RUNDIR="$W/p/run" UC_PXX_BOOT_IMAGE="$W/p/usr/uc-pxx-lts.img" \
		UC_PXX_RELEASE_FILE="$W/p/usr/kernel-lts.release" UC_PXX_ARM_SLOT="$W/p/arm" UC_PXX_FLASH_BOOT="$W/p/flash" \
		UC_PXX_BOOTCTL="$W/p/bootctl" UC_PXX_TEST_NONROOT=1 python3 -I "$TOOL" write --yes > "$W/sig.out" 2>&1 &
	SP=$!
	for _ in $(seq 100); do grep -q flash-start "$W/p/calls" && break; sleep 0.1; done
	kill -INT -- -$SP 2>/dev/null; kill -HUP -- -$SP 2>/dev/null; kill -TERM -- -$SP 2>/dev/null; kill -INT $SP 2>/dev/null
	wait $SP; RC=$?
	[ $RC = 0 ] && grep -q flash-end "$W/p/calls" && ok "SIGINT, SIGHUP and SIGTERM during the flash: the wrapper ends its work, exit 0" || bad "signals: rc $RC $(cat "$W/p/calls") $(cat "$W/sig.out")"
fi

echo "== 5. read only =="
if [ -n "$STOCK" ]; then
	mkpanel "$W/bootb-v0.img" crestron,uc-p10; M0=$(miscsum)
	P status >/dev/null && P check >/dev/null && P --hook >/dev/null && [ "$(stat -c %a "$W/p/dev/mmcblk0p13")" = 444 ] && [ "$(miscsum)" = "$M0" ] \
		&& ok "status, check and --hook work with read-only device files" || bad "read-only devices"
else
	skip "read-only device files (no UC_PXX_TEST_STOCK_RESOURCE)"
fi
if grep -n "O_WRONLY\|O_RDWR\|\"wb\"\|'wb'" "$TOOL" | grep -v -e 'os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600' \
	-e 'with os.fdopen(fd, "wb")' -e 'os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o644' -e 'return os.fdopen(fd, "wb")'; then
	bad "the tool opens another file for writing"
else ok "the only files the tool opens for writing: the lock, the mkstemp image, and a new OUT (O_EXCL, O_NOFOLLOW)"; fi

fi

echo "== 6. as root: no overrides =="
if [ "$(id -u)" = 0 ]; then
	OUT=$(UC_PXX_BOOT_IMAGE=$W/template.img python3 -I "$TOOL" status)
	! grep -q "$W/template.img" <<<"$OUT" && ok "root: UC_PXX_BOOT_IMAGE has no effect" || bad "root override: $OUT"
	OUT=$(UC_PXX_TEST_NONROOT=1 UC_PXX_ARM_SLOT=/bin/true UC_PXX_FLASH_BOOT=/bin/true UC_PXX_SYSBLOCK=$W/p/sys UC_PXX_ROOT=$W/p/root \
		python3 -I "$TOOL" write --yes); RC=$?
	[ $RC = 1 ] && ! grep -q "arming slot A" <<<"$OUT" && ok "root: write uses the fixed paths and refuses here (not a panel)" || bad "root write: $RC $OUT"
else
	skip "root section (the test does not run as root)"
fi
fin
