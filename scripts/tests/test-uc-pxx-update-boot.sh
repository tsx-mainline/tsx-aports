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
#      and 7 need the overrides, so they run only as a normal user)
#   7. the kernel flavor (KERNEL_FLAVOR of panel.conf): the parse (also
#      against cfg_get of the real tsx-config when TSX_COMMON or
#      ../tsx-linux-common has it), an unknown value refused before anything
#      runs, a switch lts -> stable -> lts on the made-up panel (the stable
#      image with the same checks), the fallback to lts when the stable image
#      is not installed (never to stable), the hooks of both packages
#   8. the board step: the real uc-pxx-post-update of uc-pxx-linux
#      (UC_PXX_LINUX, default ../uc-pxx-linux; skipped when its TOOL_SHA is
#      not this tool) with this tool and stub wrappers that keep an A/B
#      state: a switch each way, an unknown flavor (no arm), a power cut at
#      four points of a switch (B stays successful; boot_a changes only while
#      A is trying; the next run finishes the switch), two runs at once
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
SREL = b"7.3.5-g1217d359257b"
w("template-stable.img", bootimg(shim(b"crestron,uc-p10", SREL, b"ucpxx-stab0001"), rd, b"", b"ucpxx-stab0001"))
w("template-stable-p8.img", bootimg(shim(b"crestron,uc-p8", SREL, b"ucpxx-stab0001"), rd, b"", b"ucpxx-stab0001"))
b = bytearray(open(os.path.join(W, "template-stable.img"), "rb").read()); b[600] ^= 1
w("template-stable-badid.img", bytes(b))
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
	UC_PXX_RUNDIR=$W/p/run UC_PXX_BOOT_DIR=$W/p/usr UC_PXX_SHARE_DIR=$W/p/usr UC_PXX_PANEL_CONF=$W/p/panel.conf \
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
		UC_PXX_DT_COMPATIBLE="$W/p/compatible" UC_PXX_RUNDIR="$W/p/run" UC_PXX_BOOT_DIR="$W/p/usr" \
		UC_PXX_SHARE_DIR="$W/p/usr" UC_PXX_PANEL_CONF="$W/p/panel.conf" UC_PXX_ARM_SLOT="$W/p/arm" UC_PXX_FLASH_BOOT="$W/p/flash" \
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

echo "== 7. the kernel flavor =="
# The parse: `flavor` reads only panel.conf and /boot (no device, no panel).
# It needs UC_PXX_PANEL_CONF and UC_PXX_BOOT_DIR, which root ignores.
if [ "$(id -u)" = 0 ]; then
	skip "the flavor parse with the UC_PXX_* paths (the tool ignores them as root)"
else
FL() { UC_PXX_PANEL_CONF=$W/fl.conf UC_PXX_BOOT_DIR=$W/flboot UC_PXX_SHARE_DIR=$W/flboot python3 -I "$TOOL" flavor; }
mkdir -p "$W/flboot"; cp "$W/template.img" "$W/flboot/uc-pxx-lts.img"; cp "$W/template-stable.img" "$W/flboot/uc-pxx-stable.img"
flc() {  # flc 'CONTENT' WANT DESC: WANT = lts, stable or refuse
	printf "$1" > "$W/fl.conf"
	OUT=$(FL); RC=$?
	case $2 in
	refuse) [ $RC = 1 ] && grep -q "is not lts, stable or empty. Nothing written" <<<"$OUT" && ok "flavor: $3: refused" || bad "flavor: $3: rc $RC $OUT";;
	*) [ $RC = 0 ] && grep -q "^uc-pxx-update-boot: kernel flavor: $2 (" <<<"$OUT" && ok "flavor: $3: $2" || bad "flavor: $3: rc $RC $OUT";;
	esac
}
rm -f "$W/fl.conf"
OUT=$(FL); [ $? = 0 ] && grep -q "kernel flavor: lts (KERNEL_FLAVOR not set in" <<<"$OUT" && grep -q "image $W/flboot/uc-pxx-lts.img" <<<"$OUT" \
	&& ok "flavor: no panel.conf: lts" || bad "flavor: no panel.conf: $OUT"
flc '' lts "an empty panel.conf"
flc 'PANEL_NAME="x"\n' lts "no KERNEL_FLAVOR line"
flc 'KERNEL_FLAVOR=""\n' lts "an empty value (quoted)"
flc 'KERNEL_FLAVOR=\n' lts "an empty value"
flc 'KERNEL_FLAVOR="lts"\n' lts "lts"
flc 'KERNEL_FLAVOR="stable"\n' stable "stable (the form of tsx-config set)"
flc "KERNEL_FLAVOR='stable'\n" stable "single quotes"
flc 'KERNEL_FLAVOR=stable' stable "no quotes, no newline at the end"
flc '  KERNEL_FLAVOR="stable"  \r\n' stable "spaces and a CR around the line"
flc 'KERNEL_FLAVOR="stable"\nKERNEL_FLAVOR="lts"\n' lts "two lines: the last one wins"
flc 'KERNEL_FLAVOR="lts"\n# KERNEL_FLAVOR="stable"\n#KERNEL_FLAVOR=beta\n' lts "comment lines are skipped"
flc 'KERNEL_FLAVOR = stable\n' lts "a space before = is not the key (as cfg_get)"
flc 'XKERNEL_FLAVOR="stable"\n' lts "another key that ends with the name"
flc 'KERNEL_FLAVOR="beta"\n' refuse "an unknown value"
flc 'KERNEL_FLAVOR="LTS"\n' refuse "capitals"
flc 'KERNEL_FLAVOR="stable" # x\n' refuse "a trailing comment (cfg_get keeps it in the value)"
flc 'KERNEL_FLAVOR="stable\n' refuse "an open quote"
flc 'KERNEL_FLAVOR="lts"\nKERNEL_FLAVOR=next\n' refuse "an unknown value in the last line"
rm -f "$W/fl.conf"; mkdir "$W/fl.conf"
OUT=$(FL); [ $? = 1 ] && grep -q "is not a regular file" <<<"$OUT" && ok "flavor: panel.conf is a folder: refused" || bad "flavor: folder: $OUT"
rmdir "$W/fl.conf"; head -c $((1024 * 1024 + 1)) /dev/zero | tr '\0' '#' > "$W/fl.conf"
OUT=$(FL); [ $? = 1 ] && grep -q "more than 1048576" <<<"$OUT" && ok "flavor: a panel.conf of more than 1 MiB: refused" || bad "flavor: big: $OUT"
if [ "$(id -u)" != 0 ]; then
	printf 'KERNEL_FLAVOR="lts"\n' > "$W/fl.conf"; chmod 000 "$W/fl.conf"
	OUT=$(FL); [ $? = 1 ] && grep -q "cannot read" <<<"$OUT" && ok "flavor: an unreadable panel.conf: refused (not read as not set)" || bad "flavor: unreadable: $OUT"
	chmod 644 "$W/fl.conf"
fi
rm -f "$W/flboot/uc-pxx-stable.img"
printf 'KERNEL_FLAVOR="stable"\n' > "$W/fl.conf"
OUT=$(FL); [ $? = 0 ] && grep -q "kernel flavor: lts (KERNEL_FLAVOR stable in" <<<"$OUT" && grep -q "uc-pxx-kernel-stable is not installed): the lts kernel is used" <<<"$OUT" \
	&& ok "flavor: stable without the stable image: lts, and it says so" || bad "flavor: stable missing: $OUT"
ln -s "$W/nothing" "$W/flboot/uc-pxx-stable.img"
OUT=$(FL); [ $? = 0 ] && grep -q "kernel flavor: stable (" <<<"$OUT" && ok "flavor: a dangling link at the stable image is not 'not installed' (a write then refuses)" || bad "flavor: dangling: $OUT"
rm -f "$W/flboot/uc-pxx-stable.img"; rm -f "$W/flboot/uc-pxx-lts.img"; cp "$W/template-stable.img" "$W/flboot/uc-pxx-stable.img"
printf 'KERNEL_FLAVOR="lts"\n' > "$W/fl.conf"
OUT=$(FL); [ $? = 0 ] && grep -q "kernel flavor: lts (" <<<"$OUT" && ok "flavor: lts without the lts image stays lts (never falls to stable)" || bad "flavor: lts missing: $OUT"
fi

# The parse against cfg_get of the real tsx-config (tsx-linux-common).
COMMON=${TSX_COMMON:-$REPO/../tsx-linux-common}
TCFG=$COMMON/base/usr/local/sbin/tsx-config
if [ -f "$TCFG" ] && grep -q '^cfg_get()' "$TCFG"; then
	: > "$W/board-empty.sh"; mkdir -p "$W/nop"
	d=0 nd=0
	for c in '' 'KERNEL_FLAVOR="stable"\n' "KERNEL_FLAVOR='lts'\n" 'KERNEL_FLAVOR=\n' '  KERNEL_FLAVOR="stable"  \r\n' \
		'KERNEL_FLAVOR="stable"\nKERNEL_FLAVOR="lts"\n' '#KERNEL_FLAVOR="stable"\n' 'KERNEL_FLAVOR = stable\n' \
		'KERNEL_FLAVOR="sta\\"ble"\n' 'KERNEL_FLAVOR="stable" # x\n' 'KERNEL_FLAVOR="stable\n' '\tKERNEL_FLAVOR=stable\t\n' \
		'KERNEL_FLAVOR="\\\\lts"\n' 'KERNEL_FLAVOR=""\n'; do
		printf "$c" > "$W/fl.conf"; nd=$((nd + 1))
		want=$(TSX_CONF=$W/fl.conf TSX_BOARD_CONF=$W/board-empty.sh TSX_CONFIG_PLUGIN_DIR=$W/nop sh "$TCFG" get KERNEL_FLAVOR 2>/dev/null) || want="<unset>"
		got=$(python3 -I - "$TOOL" "$W/fl.conf" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("ub", sys.argv[1])
spec = importlib.util.spec_from_loader("ub", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
v = m.conf_value(open(sys.argv[2], "rb").read().decode("latin-1"), "KERNEL_FLAVOR")
print("<unset>" if v is None else v)
PY
)
		[ "$got" = "$want" ] || { d=$((d + 1)); echo "    differs for $(printf '%s' "$c"): tool '$got', cfg_get '$want'"; }
	done
	[ $d = 0 ] && ok "the parse equals cfg_get of tsx-config for $nd panel.conf forms" || bad "the parse differs from cfg_get in $d of $nd forms"
else
	skip "the parse against cfg_get (no tsx-config in $COMMON; set TSX_COMMON)"
fi

if [ "$(id -u)" = 0 ]; then
	skip "the made-up panel with flavors (the tool ignores the UC_PXX_* paths as root)"
elif [ -z "$STOCK" ]; then
	OUT=$(UC_PXX_PANEL_CONF=$W/none UC_PXX_BOOT_DIR=$W/flboot python3 -I "$TOOL" --hook stable); [ $? = 0 ] && ok "--hook stable: exit 0" || bad "--hook stable: $OUT"
	skip "the switch on the made-up panel (no UC_PXX_TEST_STOCK_RESOURCE)"
else
	addstable() { cp "${1:-$W/template-stable.img}" "$W/p/usr/uc-pxx-stable.img"; echo 7.3.5-g1217d359257b > "$W/p/usr/kernel-stable.release"; }
	T assemble "$W/template.img" "$W/stock.res" "$W/want-lts.img" >/dev/null 2>&1 || true
	T assemble "$W/template-stable.img" "$W/stock.res" "$W/want-st.img" >/dev/null
	WL=$(sha256sum "$W/want-lts.img" | cut -d' ' -f1); WS=$(sha256sum "$W/want-st.img" | cut -d' ' -f1)
	[ "$WL" != "$WS" ] && ok "the two predicted boot_a images differ" || bad "the predicted images are the same"
	headsum() { head -c "$(stat -c %s "$1")" "$W/p/dev/mmcblk0p13" | sha256sum | cut -d' ' -f1; }
	flash_sha() { sed -n 's/^flash-start [^ ]* \([^ ]*\) .*/\1/p' "$W/p/calls"; }

	echo "  -- lts -> stable"
	mkpanel "$W/bootb-v0.img" crestron,uc-p10; addstable
	printf 'KERNEL_FLAVOR="stable"\n' > "$W/p/panel.conf"
	OUT=$(P status); grep -q "kernel flavor: stable (KERNEL_FLAVOR stable" <<<"$OUT" && grep -qx 'uc-pxx-update-boot: boot_a does NOT hold the kernel of the package' <<<"$OUT" \
		&& ok "status: flavor stable, and the exact line of board.sh (boot_a does NOT hold ...)" || bad "status stable: $OUT"
	OUT=$(P check); RC=$?; IMG=$(ls "$W/p/run"/boot-*.img 2>/dev/null)
	[ $RC = 0 ] && cmp -s "$IMG" "$W/want-st.img" && [ ! -s "$W/p/calls" ] && ok "check: the stable image with the resource of boot_b, nothing called" || bad "check stable: $RC $OUT"
	OUT=$(P write --yes); RC=$?
	[ $RC = 0 ] && [ "$(head -n 1 "$W/p/calls")" = arm-slot ] && [ "$(flash_sha)" = "$WS" ] && [ "$(headsum "$W/want-st.img")" = "$WS" ] \
		&& grep -q "flavor stable). Slot A is trying" <<<"$OUT" && ok "write --yes: arm-slot, then flash-boot of the stable image; boot_a holds it" || bad "write stable: $RC $(cat "$W/p/calls") $OUT"
	: > "$W/p/calls"
	OUT=$(P write --yes); [ $? = 0 ] && grep -q "already holds this image" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "a second write (stable) does nothing" || bad "second stable: $OUT"
	OUT=$(P status); grep -qx 'uc-pxx-update-boot: boot_a holds the kernel of the package' <<<"$OUT" && ok "status: boot_a holds the stable kernel" || bad "status after: $OUT"
	OUT=$(P --hook stable); grep -q "already holds this kernel (token ucpxx-stab0001)" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "--hook stable: boot_a holds it, nothing called" || bad "hook stable: $OUT"
	OUT=$(P --hook); grep -q "uc-pxx-kernel-lts: the update path writes the stable kernel, not this one. Nothing written." <<<"$OUT" && [ ! -s "$W/p/calls" ] \
		&& ok "--hook (the lts package) with stable selected: nothing written" || bad "hook lts: $OUT"

	echo "  -- stable -> lts"
	printf 'KERNEL_FLAVOR="lts"\n' > "$W/p/panel.conf"
	OUT=$(P status); grep -qx 'uc-pxx-update-boot: boot_a does NOT hold the kernel of the package' <<<"$OUT" && ok "status after KERNEL_FLAVOR=lts: boot_a does NOT hold (the board.sh line)" || bad "status lts: $OUT"
	OUT=$(P --hook stable); grep -q "uc-pxx-kernel-stable: the update path writes the lts kernel, not this one" <<<"$OUT" && grep -q "To switch: tsx-config set KERNEL_FLAVOR stable" <<<"$OUT" \
		&& [ ! -s "$W/p/calls" ] && ok "--hook stable with lts selected: nothing written, says how to switch" || bad "hook stable/lts: $OUT"
	OUT=$(P write --yes); RC=$?
	[ $RC = 0 ] && [ "$(head -n 1 "$W/p/calls")" = arm-slot ] && [ "$(flash_sha)" = "$WL" ] && [ "$(headsum "$W/want-lts.img")" = "$WL" ] \
		&& ok "write --yes: arm-slot, then flash-boot of the LTS image; boot_a holds it" || bad "write lts: $RC $(cat "$W/p/calls") $OUT"
	rm -f "$W/p/panel.conf"; : > "$W/p/calls"
	OUT=$(P write --yes); [ $? = 0 ] && grep -q "already holds this image" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "KERNEL_FLAVOR not set = lts: nothing to do" || bad "unset: $OUT"

	echo "  -- refusals before anything runs"
	for v in beta LTS "stable # x"; do
		mkpanel "$W/bootb-v0.img" crestron,uc-p10; addstable; B0=$(sha256sum < "$W/p/dev/mmcblk0p13")
		printf 'KERNEL_FLAVOR="%s"\n' "$v" > "$W/p/panel.conf"
		OUT=$(P write --yes); RC=$?
		[ $RC = 1 ] && [ ! -s "$W/p/calls" ] && [ "$(sha256sum < "$W/p/dev/mmcblk0p13")" = "$B0" ] && grep -q "is not lts, stable or empty. Nothing written" <<<"$OUT" \
			&& ok "write with KERNEL_FLAVOR '$v': exit 1, nothing called, boot_a unchanged" || bad "write '$v': $RC $(cat "$W/p/calls") $OUT"
	done
	OUT=$(P check); [ $? = 1 ] && [ -z "$(ls "$W/p/run" 2>/dev/null | grep -v '^lock$')" ] && ok "check with an unknown flavor: exit 1, no image file" || bad "check unknown: $OUT"
	OUT=$(P status); [ $? = 0 ] && grep -q "is not lts, stable or empty" <<<"$OUT" && ! grep -q "boot_a does NOT hold" <<<"$OUT" && ok "status with an unknown flavor: shows the refusal" || bad "status unknown: $OUT"
	OUT=$(P --hook); [ $? = 0 ] && [ ! -s "$W/p/calls" ] && ok "--hook with an unknown flavor: exit 0, nothing called" || bad "hook unknown: $OUT"
	OUT=$(P flavor); [ $? = 1 ] && ok "flavor with an unknown value: exit 1" || bad "flavor unknown: $OUT"

	echo "  -- the stable image gets the same checks"
	for c in "$W/template-stable-badid.img:id field" "$W/template-stable-p8.img:is for crestron,uc-p8, this unit is crestron,uc-p10" "$W/template-res.img:already has a second part" "$W/template-badtok.img:uc-pxx.id=ucpxx-other001"; do
		f=${c%%:*} m=${c#*:}
		mkpanel "$W/bootb-v0.img" crestron,uc-p10; addstable "$f"; printf 'KERNEL_FLAVOR="stable"\n' > "$W/p/panel.conf"
		OUT=$(P write --yes); [ $? = 1 ] && grep -q -- "$m" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "a bad stable image ($(basename "$f")): refused, no fallback to lts, nothing called" || bad "bad stable $f: $OUT"
	done
	mkpanel "$W/bootb-v0.img" crestron,uc-p10; addstable; echo 7.3.6-gffffffffffff > "$W/p/usr/kernel-stable.release"; printf 'KERNEL_FLAVOR=stable\n' > "$W/p/panel.conf"
	OUT=$(P write --yes); [ $? = 1 ] && grep -q "kernel-stable.release says 7.3.6" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "a stable release file of another kernel: refused" || bad "stable release: $OUT"
	mkpanel "$W/bootb-syn.img" crestron,uc-p10; addstable; printf 'KERNEL_FLAVOR=stable\n' > "$W/p/panel.conf"
	OUT=$(P write --yes); [ $? = 1 ] && grep -q "not the approved resource" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "stable with a boot_b resource that is not approved: refused" || bad "stable syn: $OUT"
	mkpanel "$W/bootb-v0.img" crestron,uc-p10; addstable; printf 'KERNEL_FLAVOR=stable\n' > "$W/p/panel.conf"
	echo 1000 > "$W/p/sys/mmcblk0p13/size"
	OUT=$(P write --yes); [ $? = 1 ] && grep -q "larger than boot_a" <<<"$OUT" && [ ! -s "$W/p/calls" ] && ok "stable image larger than boot_a: refused" || bad "stable size: $OUT"

	echo "  -- the fallback: stable selected, the stable image not installed"
	mkpanel "$W/bootb-v0.img" crestron,uc-p10; printf 'KERNEL_FLAVOR="stable"\n' > "$W/p/panel.conf"
	OUT=$(P write --yes); RC=$?
	[ $RC = 0 ] && [ "$(flash_sha)" = "$WL" ] && grep -q "uc-pxx-kernel-stable is not installed): the lts kernel is used" <<<"$OUT" \
		&& ok "write: the LTS image, and it says why" || bad "fallback: $RC $(cat "$W/p/calls") $OUT"
	mkpanel "$W/bootb-v0.img" crestron,uc-p10; addstable; rm -f "$W/p/usr/uc-pxx-lts.img"; printf 'KERNEL_FLAVOR="lts"\n' > "$W/p/panel.conf"
	OUT=$(P write --yes); [ $? = 1 ] && grep -q "cannot read $W/p/usr/uc-pxx-lts.img (is uc-pxx-kernel-lts installed?)" <<<"$OUT" && [ ! -s "$W/p/calls" ] \
		&& ok "lts selected, the lts image missing: refused (never the stable image)" || bad "lts missing: $OUT"

	echo "  -- a change of KERNEL_FLAVOR while a write runs"
	mkpanel "$W/bootb-v0.img" crestron,uc-p10; addstable; printf 'KERNEL_FLAVOR="stable"\n' > "$W/p/panel.conf"
	FLASH_SLEEP=2 P write --yes > "$W/race.out" 2>&1 &
	RP=$!; for _ in $(seq 100); do grep -q flash-start "$W/p/calls" && break; sleep 0.1; done
	printf 'KERNEL_FLAVOR="beta"\n' > "$W/p/panel.conf"
	wait $RP; RC=$?
	[ $RC = 0 ] && [ "$(flash_sha)" = "$WS" ] && [ "$(headsum "$W/want-st.img")" = "$WS" ] && ok "the write uses the flavor of its own check (the stable image), a later change does not reach it" || bad "race: $RC $(cat "$W/race.out")"
	OUT=$(P write --yes); [ $? = 1 ] && grep -q "is not lts, stable or empty" <<<"$OUT" && ok "the next write refuses the new value" || bad "race next: $OUT"
fi

echo "== 8. the board step: uc-pxx-post-update with this tool =="
ULX=${UC_PXX_LINUX:-$REPO/../uc-pxx-linux}
PUS=$ULX/rootfs/overlay/usr/sbin/uc-pxx-post-update
TSHA=$(sha256sum "$TOOL" | cut -d' ' -f1)
if [ "$(id -u)" = 0 ]; then
	skip "the board step (the tool ignores the UC_PXX_* paths as root)"
elif [ -z "$STOCK" ]; then
	skip "the board step (no UC_PXX_TEST_STOCK_RESOURCE)"
elif [ ! -f "$PUS" ] || ! grep -qx "TOOL_SHA=$TSHA" "$PUS"; then
	skip "the board step (no uc-pxx-post-update with TOOL_SHA=$TSHA in $ULX; set UC_PXX_LINUX)"
else
	# The A/B model: the file ab holds "A=prio,tries,succ B=prio,tries,succ". The arm (the stub
	# uc-pxx-arm-slot, and the arms in the stub uc-pxx-flash-boot) sets A=15,7,0 by a rename. KILL_AT=POINT
	# ends the run there as a power cut does: SIGKILL to every process of the run and of the wrapper session.
	mkstubs() {
		cat > "$W/p/arm" <<STUB
#!/bin/bash
echo arm-slot >> "$W/p/calls"
[ "\${KILL_AT:-}" = arm0 ] && { pkill -9 -s "\$(cat "$W/p/sid")"; kill -9 0; }
sed 's/^A=[^ ]*/A=15,7,0/' "$W/p/ab" > "$W/p/ab.new" && mv "$W/p/ab.new" "$W/p/ab"
[ "\${KILL_AT:-}" = arm1 ] && { pkill -9 -s "\$(cat "$W/p/sid")"; kill -9 0; }
exit 0
STUB
		cat > "$W/p/flash" <<STUB
#!/bin/bash
echo "flash-start \$1 \$2" >> "$W/p/calls"
[ "\$(sha256sum "\$1" | cut -d' ' -f1)" = "\$2" ] || exit 2
sed 's/^A=[^ ]*/A=15,7,0/' "$W/p/ab" > "$W/p/ab.new" && mv "$W/p/ab.new" "$W/p/ab"
n=\$(stat -c %s "\$1"); h=\$((n / 2))
chmod u+w "$W/p/dev/mmcblk0p13"
head -c "\$h" "\$1" | dd of="$W/p/dev/mmcblk0p13" conv=notrunc 2>/dev/null
[ -n "\${FLASH_SLEEP:-}" ] && sleep "\$FLASH_SLEEP"
[ "\${KILL_AT:-}" = flash-mid ] && { pkill -9 -s "\$(cat "$W/p/sid")"; kill -9 0; }
tail -c +\$((h + 1)) "\$1" | dd of="$W/p/dev/mmcblk0p13" bs=1M seek="\$h" oflag=seek_bytes conv=notrunc 2>/dev/null
chmod 444 "$W/p/dev/mmcblk0p13"
[ "\${KILL_AT:-}" = flash-end ] && { pkill -9 -s "\$(cat "$W/p/sid")"; kill -9 0; }
sed 's/^A=[^ ]*/A=15,7,0/' "$W/p/ab" > "$W/p/ab.new" && mv "$W/p/ab.new" "$W/p/ab"
echo flash-end >> "$W/p/calls"
exit 0
STUB
		cat > "$W/p/bootctl" <<STUB
#!/bin/bash
[ "\$1" = status ] || exit 9
IFS=' =,' read -r _ ap at as _ bp bt bs < "$W/p/ab"
echo "uc-pxx-bootctl: current: A{prio \$ap tries \$at succ \$as} B{prio \$bp tries \$bt succ \$bs} crc 0"
echo "libavb-would-boot: a"
STUB
		chmod 755 "$W/p/arm" "$W/p/flash" "$W/p/bootctl"
	}
	pu_panel() {  # the made-up panel of section 4: LTS in boot_a, A successful, both kernel packages
		mkpanel "$W/bootb-v0.img" crestron,uc-p10; addstable
		chmod u+w "$W/p/dev/mmcblk0p13"; dd if="$W/want-lts.img" of="$W/p/dev/mmcblk0p13" conv=notrunc 2>/dev/null; chmod 444 "$W/p/dev/mmcblk0p13"
		echo "A=15,0,1 B=14,0,1" > "$W/p/ab"
		mkstubs
		sha256sum "$TOOL" "$W/p/arm" "$W/p/flash" "$W/p/bootctl" > "$W/p/list"
		sed "s|^LIST=/usr/share/uc-pxx/boot-control.sha256 ARM=/usr/sbin/uc-pxx-arm-slot TOOL=/usr/sbin/uc-pxx-update-boot BOOTCTL=/usr/sbin/uc-pxx-bootctl\$|LIST=$W/p/list ARM=$W/p/arm TOOL=$TOOL BOOTCTL=$W/p/bootctl|" "$PUS" > "$W/p/pu"
	}
	penv() {
		env UC_PXX_SYSBLOCK="$W/p/sys" UC_PXX_DEVDIR="$W/p/dev" UC_PXX_ROOT="$W/p/root" UC_PXX_DT_COMPATIBLE="$W/p/compatible" \
			UC_PXX_RUNDIR="$W/p/run" UC_PXX_BOOT_DIR="$W/p/usr" UC_PXX_SHARE_DIR="$W/p/usr" UC_PXX_PANEL_CONF="$W/p/panel.conf" \
			UC_PXX_ARM_SLOT="$W/p/arm" UC_PXX_FLASH_BOOT="$W/p/flash" UC_PXX_BOOTCTL="$W/p/bootctl" UC_PXX_TEST_NONROOT=1 "$@"
	}
	PU() {  # PU OUT: the board step in its own session (a power cut ends the session); prints the status
		penv setsid -w bash -c 'echo $$ > "$1/sid"; exec sh "$1/pu" </dev/null' _ "$W/p" > "$1" 2>&1; echo $?
	}
	ba() { head -c "$(stat -c %s "$1")" "$W/p/dev/mmcblk0p13" | sha256sum | cut -d' ' -f1; }
	inv() {  # inv DESC: slot B never changes; boot_a differs from the proven LTS image only while A is trying
		local a b; a=$(sed 's/ .*//' "$W/p/ab"); b=$(sed 's/.* //' "$W/p/ab")
		if [ "$b" != B=14,0,1 ]; then bad "$1: slot B changed ($b)"; return; fi
		if [ "$(ba "$W/want-lts.img")" != "$WL" ] && [ "$a" != A=15,7,0 ]; then bad "$1: boot_a changed while slot A is $a"; return; fi
		ok "$1: B=14,0,1, and boot_a is the proven image or A is trying ($a)"
	}
	ok "uc-pxx-post-update of $ULX pins this tool (TOOL_SHA=$TSHA)"

	pu_panel; printf 'KERNEL_FLAVOR="stable"\n' > "$W/p/panel.conf"; : > "$W/p/calls"
	RC=$(PU "$W/p/out"); [ "$RC" = 0 ] && [ "$(ba "$W/want-st.img")" = "$WS" ] && grep -q "kernel flavor: stable" "$W/p/out" && [ "$(head -n 1 "$W/p/calls")" = arm-slot ] \
		&& ok "lts -> stable: status 0, the arm first, boot_a holds the stable image" || bad "pu stable: $RC $(cat "$W/p/calls") $(cat "$W/p/out")"
	inv "after the switch to stable"
	printf 'KERNEL_FLAVOR="lts"\n' > "$W/p/panel.conf"; echo "A=15,0,1 B=14,0,1" > "$W/p/ab"; : > "$W/p/calls"
	RC=$(PU "$W/p/out"); [ "$RC" = 0 ] && [ "$(ba "$W/want-lts.img")" = "$WL" ] && [ "$(head -n 1 "$W/p/calls")" = arm-slot ] \
		&& ok "stable -> lts: status 0, the arm first, boot_a holds the LTS image" || bad "pu lts: $RC $(cat "$W/p/out")"
	printf 'KERNEL_FLAVOR="next"\n' > "$W/p/panel.conf"; echo "A=15,0,1 B=14,0,1" > "$W/p/ab"; : > "$W/p/calls"
	RC=$(PU "$W/p/out"); [ "$RC" = 1 ] && [ ! -s "$W/p/calls" ] && [ "$(cat "$W/p/ab")" = "A=15,0,1 B=14,0,1" ] && [ "$(ba "$W/want-lts.img")" = "$WL" ] \
		&& grep -q "Nothing armed or written" "$W/p/out" && ok "an unknown flavor: status 1, no arm, A/B and boot_a unchanged" || bad "pu unknown: $RC $(cat "$W/p/calls") $(cat "$W/p/out")"

	for k in arm0 arm1 flash-mid flash-end; do
		pu_panel; printf 'KERNEL_FLAVOR="stable"\n' > "$W/p/panel.conf"; : > "$W/p/calls"
		KILL_AT=$k PU "$W/p/out" >/dev/null
		grep -q "^flash-end" "$W/p/calls" && bad "the cut at $k came too late" || true
		inv "a power cut at $k of the switch to stable"
		rm -f "$W/p/run/lock"   # a power cut clears /run
		: > "$W/p/calls"
		RC=$(PU "$W/p/out"); [ "$RC" = 0 ] && [ "$(ba "$W/want-st.img")" = "$WS" ] && ok "after the cut at $k: the next run finishes the switch (0)" || bad "recover $k: $RC $(cat "$W/p/out")"
		inv "after the next run ($k)"
	done

	pu_panel; printf 'KERNEL_FLAVOR="stable"\n' > "$W/p/panel.conf"; : > "$W/p/calls"
	( RC1=$(FLASH_SLEEP=2 PU "$W/p/out1"); echo "$RC1" > "$W/p/rc1" ) &
	P1=$!; for _ in $(seq 100); do grep -q flash-start "$W/p/calls" && break; sleep 0.1; done
	penv sh "$W/p/pu" </dev/null > "$W/p/out2" 2>&1; RC2=$?
	wait $P1; RC1=$(cat "$W/p/rc1")
	[ "$RC1" = 0 ] && [ "$RC2" = 1 ] && grep -q "another uc-pxx-update-boot runs" "$W/p/out2" && [ "$(grep -c flash-start "$W/p/calls")" = 1 ] \
		&& [ "$(ba "$W/want-st.img")" = "$WS" ] && ok "two runs at once: the first writes (0), the second refuses on the lock (1), one flash" \
		|| bad "two runs: $RC1 $RC2 $(cat "$W/p/calls") $(cat "$W/p/out2")"
	inv "after two runs at once"
fi

echo "== 6. as root: no overrides =="
if [ "$(id -u)" = 0 ]; then
	OUT=$(UC_PXX_BOOT_DIR=$W UC_PXX_PANEL_CONF=$W/fl.conf python3 -I "$TOOL" status)
	! grep -q "$W" <<<"$OUT" && grep -q "in /data/tsx/panel.conf" <<<"$OUT" && ok "root: UC_PXX_BOOT_DIR and UC_PXX_PANEL_CONF have no effect" || bad "root override: $OUT"
	OUT=$(UC_PXX_TEST_NONROOT=1 UC_PXX_ARM_SLOT=/bin/true UC_PXX_FLASH_BOOT=/bin/true UC_PXX_SYSBLOCK=$W/p/sys UC_PXX_ROOT=$W/p/root \
		python3 -I "$TOOL" write --yes); RC=$?
	[ $RC = 1 ] && ! grep -q "arming slot A" <<<"$OUT" && ok "root: write uses the fixed paths and refuses here (not a panel)" || bad "root write: $RC $OUT"
else
	skip "root section (the test does not run as root)"
fi
fin
