#!/bin/bash
# Host test of scripts/stage-kernel-xx70.sh. No build host and no compiler.
# A fake ssh runs the remote part in a temporary directory. A fake make
# stands in for modules_install, and a fake kernel/mkimage.sh records its
# arguments. The test checks that the script passes the eight board DTBs
# to mkimage.sh by default, in order, puts every DTB into the bundle, and
# keeps working with a single DTB when DTB_NAMES says so. It needs bash, git, tar with
# zstd support and sha512sum.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# a copy of the files the script reads and edits
R=$T/repo
mkdir -p "$R/scripts" "$R/xx70"
cp "$REPO/scripts/stage-kernel-xx70.sh" "$R/scripts/"
cp -r "$REPO"/xx70/tsx-xx70-kernel-lts "$REPO"/xx70/tsx-xx70-boot-tools "$R/xx70/"

# fake build host: kernel build directory, source repository, lk2nd, initramfs
K=$T/kdir B=$T/kdir/arch/arm64/boot
mkdir -p "$B/dts/qcom" "$K/include/config" "$T/src" "$T/bin"
echo "Image" | gzip -n > "$B/Image.gz"
DTBS="tsw770 tsw1070 tsw570 tsw570-truly tsw770-rev1 tsw770-truly tsw1070-rev1 tsw1070-truly"
for d in $DTBS; do printf 'dtb %s crestron,tswxx70\n' "$d" > "$B/dts/qcom/apq8053-crestron-$d.dtb"; done
echo 6.18.99-00001-gabcdef123456 > "$K/include/config/kernel.release"
git -C "$T/src" init -q
git -C "$T/src" -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false \
	commit -q --allow-empty -m x
echo lk2nd > "$T/lk2nd.img"; echo initramfs > "$T/initramfs.cpio.gz"

cat > "$T/mkimage.sh" <<'SH'
#!/bin/sh
# fake kernel/mkimage.sh: lk2nd.img Image.gz dtb... initramfs out
out=
for a; do out=$a; done
printf '%s\n' "$@" > "${MKIMAGE_ARGS:?}"
{
	printf 'ANDROID!'; head -c 524280 /dev/zero
	printf 'ANDROID!'
	for a; do case $a in *.dtb) cat "$a";; esac; done
} > "$out"
SH
# fake ssh: drop the options and the host, run the command here
cat > "$T/bin/ssh" <<'SH'
#!/bin/sh
while [ "${1#-}" != "$1" ]; do [ "$1" = -o ] && shift; shift; done
shift
exec sh -c "$*"
SH
# fake make: the modules tree of modules_install
cat > "$T/bin/make" <<'SH'
#!/bin/sh
for a; do case $a in INSTALL_MOD_PATH=*) p=${a#INSTALL_MOD_PATH=};; esac; done
k=$(cat "$KDIR/include/config/kernel.release")
mkdir -p "$p/lib/modules/$k/kernel"
touch "$p/lib/modules/$k/modules.dep" "$p/lib/modules/$k/kernel/x.ko"
SH
chmod +x "$T/mkimage.sh" "$T/bin/ssh" "$T/bin/make"

stage() {  # stage TAG [VAR=value]...  (runs the script, prints nothing on success)
	local tag=$1; shift
	rm -rf "$T/build/xx70"
	env PATH="$T/bin:$PATH" KDIR="$K" MKIMAGE_ARGS="$T/args-$tag" \
		BUILD_HOST=fake BUILD_DIR="$T/build" BUILD_HOST_KDIR="$K" \
		BUILD_HOST_LINUX_DIR="$T/src" BUILD_HOST_LK2ND="$T/lk2nd.img" \
		BUILD_HOST_INITRAMFS="$T/initramfs.cpio.gz" BUILD_HOST_MKIMAGE="$T/mkimage.sh" \
		"$@" bash "$R/scripts/stage-kernel-xx70.sh" lts > "$T/log-$tag" 2>&1
}
DIST=$T/build/xx70/tsx-xx70-kernel-lts/dist
D770=$B/dts/qcom/apq8053-crestron-tsw770.dtb D1070=$B/dts/qcom/apq8053-crestron-tsw1070.dtb

# 1. default: the eight DTBs, the TSW-770 first
if stage default; then ok "script runs with the default DTB list"; else bad "script failed"; cat "$T/log-default"; fi
if [ "$(sed -n '2,11p' "$T/args-default")" = "$(echo "$B/Image.gz"; for d in $DTBS; do echo "$B/dts/qcom/apq8053-crestron-$d.dtb"; done; echo "$T/initramfs.cpio.gz")" ]; then ok "mkimage.sh gets Image.gz, the eight DTBs in order, the initramfs"; else bad "mkimage.sh arguments"; cat "$T/args-default"; fi
[ "$(sed -n 1p "$T/args-default")" = "$T/lk2nd.img" ] && ok "lk2nd first" || bad "lk2nd argument"
tar --zstd -tf "$DIST/tsx-xx70-kernel-lts-bundle.tar.zst" | sort > "$T/list-default"
for f in Image.gz $(for d in $DTBS; do echo "apq8053-crestron-$d.dtb"; done) tsx-xx70-boot.img \
	modules-6.18.99-00001-gabcdef123456.tar.gz kernel.release kernel.commit CHECKSUMS.sha256; do
	grep -qx "$f" "$T/list-default" && ok "bundle holds $f" || bad "bundle lacks $f"
done
grep -q 'apq8053-crestron-tsw1070.dtb' "$DIST/CHECKSUMS.sha256" && ok "CHECKSUMS lists the TSW-1070 DTB" || bad "CHECKSUMS"
cmp -s "$D770" "$DIST/apq8053-crestron-tsw770.dtb" && ok "TSW-770 DTB copied unchanged" || bad "TSW-770 DTB copy"
cmp -s "$D1070" "$DIST/apq8053-crestron-tsw1070.dtb" && ok "TSW-1070 DTB copied unchanged" || bad "TSW-1070 DTB copy"
grep -q '^_kernelrelease=6.18.99-00001-gabcdef123456$' "$R/xx70/tsx-xx70-kernel-lts/APKBUILD" && ok "APKBUILD has the kernel release" || bad "APKBUILD release"
grep -q "^pkgver=6.18.99_git$(date +%Y%m%d)\$" "$R/xx70/tsx-xx70-kernel-lts/APKBUILD" && ok "APKBUILD has the new pkgver" || bad "APKBUILD pkgver"
grep -Eq '^[0-9a-f]{128}  tsx-xx70-kernel-lts-bundle.tar.zst$' "$R/xx70/tsx-xx70-kernel-lts/APKBUILD" && ok "APKBUILD has the bundle sha512" || bad "APKBUILD sha512"

# 2. one DTB, as before
if stage one DTB_NAMES=apq8053-crestron-tsw770.dtb; then ok "script runs with one DTB"; else bad "one DTB failed"; cat "$T/log-one"; fi
[ "$(sed -n '2,4p' "$T/args-one")" = "$B/Image.gz
$D770
$T/initramfs.cpio.gz" ] && ok "mkimage.sh gets one DTB" || { bad "one DTB arguments"; cat "$T/args-one"; }
tar --zstd -tf "$DIST/tsx-xx70-kernel-lts-bundle.tar.zst" | grep -q tsw1070 && bad "bundle holds the TSW-1070 DTB" || ok "bundle has only the listed DTB"

# 3. a missing DTB stops the script
rm "$D1070"
if stage missing; then bad "a missing DTB did not stop the script"; else grep -q 'no such file' "$T/log-missing" && ok "a missing DTB stops the script" || bad "wrong error"; fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
