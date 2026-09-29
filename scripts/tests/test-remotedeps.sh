#!/bin/bash
# Host test for the "UNTRUSTED signature" bug: a BUILD_HOST kernel build in
# a fresh BUILD_DIR failed because tsx-xx60-kernel-*'s
# depends="tsx-xx60-boot-tools>=1-r4" is resolved by abuild from
# packages/v3.24 (REPODEST, which persists between separate scripts/build.sh
# calls against the same BUILD_DIR -- it's excluded from the push, like
# .throwaway-key/), but each call used to mint and delete its OWN throwaway
# signing key: a dep built by an earlier call sat in an index signed by a
# key the current call's container never trusted. The fix (see scripts/
# build.sh's file header) makes the throwaway keypair persist at
# BUILD_DIR/.throwaway-key and reused across calls, and also trusts this
# repo's own committed public key (common/tsx-keys/*.rsa.pub) in the build
# container.
#
# 1. Static checks on scripts/build.sh: the fix is actually in place (no
#    BUILD_HOST/ssh/docker needed).
# 2. A docker reproduction of the real mechanism -- two REAL abuild -r
#    builds (packaging, not compiling, same as test-resign.sh's fixture),
#    one package depending on the other via REPODEST, exactly like
#    tsx-xx60-kernel-* depending on tsx-xx60-boot-tools -- showing a
#    dependent build FAILS untrusted against a differently-keyed dep index
#    (the bug, reproduced), and SUCCEEDS when the same key is reused
#    across the two separate builds (the fix).
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)   # scripts/tests -> scripts
N=0 F=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }

echo "== 1. scripts/build.sh: fix is in place (static checks) =="

grep -q "KD='\$BUILD_DIR/.throwaway-key'" "$HERE/build.sh" \
	&& ok "the throwaway keypair is generated at a path under BUILD_DIR (persistent, not \$(mktemp -d))" \
	|| bad "REMOTE_CMD no longer keeps the throwaway key under BUILD_DIR"

grep -qF -e '-f \"\$KD/throwaway.rsa\" ] ||' "$HERE/build.sh" \
	&& ok "an existing throwaway key is reused instead of being regenerated" \
	|| bad "no reuse-if-present check found for the throwaway key"

if grep -q 'rm -rf \\"\$KD\\"' "$HERE/build.sh"; then
	bad "REMOTE_CMD still deletes the throwaway key after one call (defeats reuse)"
else
	ok "REMOTE_CMD no longer deletes the throwaway key after one call"
fi

grep -q "exclude '.throwaway-key/'" "$HERE/build.sh" \
	&& ok "the push excludes .throwaway-key/ (never pushed from or deleted by the local side)" \
	|| bad "the push does not exclude .throwaway-key/ -- a later push would delete the persisted key"

grep -q 'common/tsx-keys/\*.rsa.pub' "$HERE/build.sh" \
	&& ok "the docker build step also trusts this repo's own committed public key(s)" \
	|| bad "the docker build step does not trust common/tsx-keys/*.rsa.pub"

if ! command -v docker >/dev/null 2>&1; then
	echo "== 2. skipped (no docker on this host) =="
	echo "== $N ok, $F failed"
	[ $F = 0 ] && echo PASS test-remotedeps || echo FAIL test-remotedeps
	exit $F
fi

echo "== 2. reproduce the mechanism with real abuild -r builds =="
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/xx60fixture" "$W/repoA"

# Two throwaway keypairs (neither is the real project key): "A" stands in
# for a BUILD_DIR's persisted key, "B" for a fresh, unrelated one -- what
# the old per-call mktemp -d behavior produced.
openssl genrsa -out "$W/keyA.rsa" 4096 >/dev/null 2>&1
openssl rsa -in "$W/keyA.rsa" -pubout -out "$W/keyA.rsa.pub" >/dev/null 2>&1
openssl genrsa -out "$W/keyB.rsa" 4096 >/dev/null 2>&1
openssl rsa -in "$W/keyB.rsa" -pubout -out "$W/keyB.rsa.pub" >/dev/null 2>&1

mkdir -p "$W/xx60fixture/tsx-fixture-dep"
cat > "$W/xx60fixture/tsx-fixture-dep/APKBUILD" <<'APKBUILD'
pkgname=tsx-fixture-dep
pkgver=1
pkgrel=4
pkgdesc="test-remotedeps.sh fixture: stands in for tsx-xx60-boot-tools"
url="https://example.invalid"
arch=noarch
license="GPL-2.0-or-later"
package() {
	mkdir -p "$pkgdir"/usr/share/doc/tsx-fixture-dep
	echo dep > "$pkgdir"/usr/share/doc/tsx-fixture-dep/README
}
APKBUILD

mkdir -p "$W/xx60fixture/tsx-fixture-user"
cat > "$W/xx60fixture/tsx-fixture-user/APKBUILD" <<'APKBUILD'
pkgname=tsx-fixture-user
pkgver=1
pkgrel=0
pkgdesc="test-remotedeps.sh fixture: stands in for tsx-xx60-kernel-*"
url="https://example.invalid"
arch=noarch
license="GPL-2.0-or-later"
depends="tsx-fixture-dep>=1-r4"
package() {
	mkdir -p "$pkgdir"/usr/share/doc/tsx-fixture-user
	echo user > "$pkgdir"/usr/share/doc/tsx-fixture-user/README
}
APKBUILD

# Step A: build the dep, signed+indexed with key A, into a REPODEST both
# later builds share -- this is packages/v3.24 in the real repo.
docker run --rm --platform linux/arm/v7 -v "$W:/w" alpine:3.24 sh -euc '
	apk add --no-cache alpine-sdk >/dev/null
	mkdir -p /root/.abuild
	echo "PACKAGER_PRIVKEY=/w/keyA.rsa" > /root/.abuild/abuild.conf
	cp /w/keyA.rsa.pub /etc/apk/keys/
	cd /w/xx60fixture/tsx-fixture-dep
	abuild -F -r -P /w/repoA
	chown -R '"$(id -u):$(id -g)"' /w
' >"$W/dep-build.log" 2>&1
if ! find "$W/repoA" -name "tsx-fixture-dep-*.apk" | grep -q .; then
	echo "  SKIPPED: could not build the fixture dep apk (no docker/network for the alpine:3.24 pull?)"
	tail -n 15 "$W/dep-build.log"
	echo "== $N ok, $F failed"
	[ $F = 0 ] && echo PASS test-remotedeps || echo FAIL test-remotedeps
	exit $F
fi
ok "fixture dep built and indexed (REPODEST), signed with key A"

# Step B (the BUG, reproduced): a separate build, its OWN key B, trusting
# only B -- the old "mktemp -d ... rm -rf" per-call behavior. The dep in
# REPODEST is signed with A, which this container never trusts.
docker run --rm --platform linux/arm/v7 -v "$W:/w" alpine:3.24 sh -euc '
	apk add --no-cache alpine-sdk >/dev/null
	mkdir -p /root/.abuild
	echo "PACKAGER_PRIVKEY=/w/keyB.rsa" > /root/.abuild/abuild.conf
	cp /w/keyB.rsa.pub /etc/apk/keys/
	cd /w/xx60fixture/tsx-fixture-user
	abuild -F -r -P /w/repoA
' >"$W/user-build-keyB.log" 2>&1
RC=$?
if [ $RC -eq 0 ]; then
	bad "dependent build unexpectedly SUCCEEDED with a fresh, untrusted key (bug not reproduced)"
else
	if grep -qi "untrusted signature\|UNTRUSTED\|verification failed" "$W/user-build-keyB.log"; then
		ok "dependent build fails UNTRUSTED against a dep signed with a different (unreused) key -- bug reproduced"
	else
		bad "dependent build failed, but not with the expected untrusted-signature error: $(tail -n 5 "$W/user-build-keyB.log")"
	fi
fi

# Step C (the FIX): a separate build reusing the SAME key A (what
# BUILD_DIR/.throwaway-key persistence now guarantees across calls).
docker run --rm --platform linux/arm/v7 -v "$W:/w" alpine:3.24 sh -euc '
	apk add --no-cache alpine-sdk >/dev/null
	mkdir -p /root/.abuild
	echo "PACKAGER_PRIVKEY=/w/keyA.rsa" > /root/.abuild/abuild.conf
	cp /w/keyA.rsa.pub /etc/apk/keys/
	cd /w/xx60fixture/tsx-fixture-user
	abuild -F -r -P /w/repoA
' >"$W/user-build-keyA.log" 2>&1
if [ $? -eq 0 ] && find "$W/repoA" -name "tsx-fixture-user-*.apk" | grep -q .; then
	ok "dependent build succeeds when the SAME key is reused across separate calls -- fix confirmed"
else
	bad "dependent build failed even with the same key reused: $(tail -n 15 "$W/user-build-keyA.log")"
fi

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-remotedeps || echo FAIL test-remotedeps
exit $F
