#!/bin/bash
# Host tests for "the private signing key never leaves this workstation"
# (README.md "Signing key" / "Building on a remote host", scripts/build.sh):
#   1. the runtime guards scripts/build.sh's BUILD_HOST path relies on --
#      to_build_host (refuses to rsync anything that looks like a private
#      key) and assert_remote_cmd_safe (refuses a remote command string that
#      embeds the local private key's path) -- no BUILD_HOST needed: this
#      sources build.sh with TSX_APORTS_BUILD_SH_SOURCE_ONLY=1, which loads
#      the functions and returns before touching a real target/docker/ssh.
#   2. scripts/resign.sh actually replaces a throwaway signature with the
#      project key's: `apk verify` (trusting ONLY a fixture "project" public
#      key) fails against a package signed with a different (fixture
#      "throwaway") key, and passes after scripts/resign.sh re-signs it.
# Builds nothing heavy: the "package" is a handful of bytes of tar+gzip, put
# together and signed inside disposable Alpine containers (abuild-sign / apk
# verify -- the same operations scripts/build.sh's BUILD_HOST path and
# scripts/resign.sh do for real, not a kernel/rootfs/qemu compile). Neither
# key here is the real project key.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)   # scripts/tests -> scripts
N=0 F=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }

echo "== 1. build.sh's guards (no docker, no BUILD_HOST) =="
OUT=$(
	TSX_APORTS_BUILD_SH_SOURCE_ONLY=1 . "$HERE/build.sh"
	TSX_APORTS_KEY=/keys/tsx-mainline-real.rsa
	if to_build_host /keys/tsx-mainline-real.rsa host:/dest 2>&1; then echo "REFUSAL-MISSING"; fi
) 2>&1
case "$OUT" in *"refusing to copy a private key"*) ok "to_build_host refuses \$TSX_APORTS_KEY itself";; *) bad "to_build_host let \$TSX_APORTS_KEY through: $OUT";; esac

OUT=$(
	TSX_APORTS_BUILD_SH_SOURCE_ONLY=1 . "$HERE/build.sh"
	TSX_APORTS_KEY=/keys/tsx-mainline-real.rsa
	if to_build_host /keys/some-other-name.rsa host:/dest 2>&1; then echo "REFUSAL-MISSING"; fi
) 2>&1
case "$OUT" in *"refusing to copy a private key"*) ok "to_build_host refuses any *.rsa, not just the configured one";; *) bad "to_build_host let a *.rsa through: $OUT";; esac

OUT=$(
	TSX_APORTS_BUILD_SH_SOURCE_ONLY=1 . "$HERE/build.sh"
	TSX_APORTS_KEY=/keys/tsx-mainline-real.rsa
	# a local, no-network rsync (source and dest are both plain paths, no
	# "host:" target) so this stays fast and offline either way; only the
	# guard's own case check is under test here, not rsync itself
	to_build_host --dry-run /keys/tsx-mainline-real.rsa.pub /tmp/tsx-resign-test-nonexistent-dst 2>&1 || true
)
case "$OUT" in *"refusing to copy a private key"*) bad "to_build_host refused the PUBLIC key too: $OUT";; *) ok "to_build_host lets the public key (.rsa.pub) through";; esac

OUT=$(
	TSX_APORTS_BUILD_SH_SOURCE_ONLY=1 . "$HERE/build.sh"
	TSX_APORTS_KEY=/keys/tsx-mainline-real.rsa
	assert_remote_cmd_safe "TSX_APORTS_KEY=/keys/tsx-mainline-real.rsa scripts/build.sh --all" 2>&1 || true
)
case "$OUT" in *"embeds the local private key path"*) ok "assert_remote_cmd_safe refuses a command embedding the local key path";; *) bad "assert_remote_cmd_safe missed an embedded key path: $OUT";; esac

OUT=$(
	TSX_APORTS_BUILD_SH_SOURCE_ONLY=1 . "$HERE/build.sh"
	TSX_APORTS_KEY=/keys/tsx-mainline-real.rsa
	assert_remote_cmd_safe "TSX_APORTS_KEY=\$KD/throwaway.rsa scripts/build.sh --all" 2>&1
	echo "ran ok, rc=$?"
)
case "$OUT" in *"embeds the local private key path"*) bad "assert_remote_cmd_safe refused a safe (throwaway-only) command: $OUT";; *"ran ok"*) ok "assert_remote_cmd_safe allows a command naming only the throwaway key";; *) bad "unexpected: $OUT";; esac

if ! command -v docker >/dev/null 2>&1; then
	echo "== 2. skipped (no docker on this host) =="
	echo "== $N ok, $F failed"
	[ $F = 0 ] && echo PASS test-resign || echo FAIL test-resign
	exit $F
fi

echo "== 2. resign.sh replaces a throwaway signature with the project key's =="
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/in" "$W/out" "$W/build"

# Fixture keys (neither is the real project key): "project" is what a
# workstation's TSX_APORTS_KEY would be; "throwaway" simulates the key a
# BUILD_HOST build generates and deletes.
openssl genrsa -out "$W/project.rsa" 4096 >/dev/null 2>&1
openssl rsa -in "$W/project.rsa" -pubout -out "$W/project.rsa.pub" >/dev/null 2>&1

# A tiny REAL package (one static file, `abuild -F -r` the same way
# scripts/build.sh's local path builds anything -- packaging, not
# compiling), signed with the THROWAWAY key inside a disposable Alpine
# container. A real `abuild -r` build is used (rather than hand-assembling
# a .PKGINFO) so `apk verify` below is checking the genuine article: apk's
# own PKGINFO/checksum requirements are whatever abuild itself produces,
# not our guess at them.
mkdir -p "$W/build/tsx-fixture"
cat > "$W/build/tsx-fixture/APKBUILD" <<'APKBUILD'
pkgname=tsx-fixture
pkgver=1
pkgrel=0
pkgdesc="scripts/tests/test-resign.sh fixture package"
url="https://example.invalid"
arch=noarch
license="GPL-2.0-or-later"
package() {
	mkdir -p "$pkgdir"/usr/share/doc/tsx-fixture
	echo test > "$pkgdir"/usr/share/doc/tsx-fixture/README
}
APKBUILD
docker run --rm --platform linux/arm/v7 -v "$W:/w" alpine:3.24 sh -euc '
	apk add --no-cache alpine-sdk openssl >/dev/null
	openssl genrsa -out /w/throwaway.rsa 4096 >/dev/null 2>&1
	openssl rsa -in /w/throwaway.rsa -pubout -out /w/throwaway.rsa.pub >/dev/null 2>&1
	mkdir -p /root/.abuild
	echo "PACKAGER_PRIVKEY=/w/throwaway.rsa" > /root/.abuild/abuild.conf
	cp /w/throwaway.rsa.pub /etc/apk/keys/
	cd /w/build/tsx-fixture
	abuild -F -r -P /w/staged
	find /w/staged -name "tsx-fixture-*.apk" -exec cp {} /w/in/tsx-fixture-1-r0.apk \;
	chown -R '"$(id -u):$(id -g)"' /w
' >"$W/fixture-build.log" 2>&1
if [ ! -f "$W/in/tsx-fixture-1-r0.apk" ]; then
	echo "  SKIPPED: could not build the fixture apk (no docker/network for the alpine:3.24 pull?)"
	tail -n 15 "$W/fixture-build.log"
	echo "== $N ok, $F failed"
	[ $F = 0 ] && echo PASS test-resign || echo FAIL test-resign
	exit $F
fi

echo "  apk verify against ONLY the project public key, before re-signing:"
if docker run --rm --platform linux/arm/v7 -v "$W/in:/w:ro" -v "$W/project.rsa.pub:/etc/apk/keys/project.rsa.pub:ro" \
	alpine:3.24 sh -c 'apk add -q --no-cache apk-tools >/dev/null; apk verify /w/tsx-fixture-1-r0.apk' >/dev/null 2>&1
then bad "apk verify unexpectedly PASSED before re-signing (throwaway-signed package trusted as the project's)"
else ok "apk verify correctly refuses the throwaway-signed package"
fi

TSX_APORTS_KEY="$W/project.rsa" "$HERE/resign.sh" "$W/in" "$W/out" >/tmp/test-resign.out 2>&1
RC=$?
[ $RC = 0 ] && [ -f "$W/out/tsx-fixture-1-r0.apk" ] && ok "resign.sh ran and produced the re-signed apk" \
	|| bad "resign.sh failed (rc=$RC): $(cat /tmp/test-resign.out)"

echo "  apk verify against ONLY the project public key, after re-signing:"
if docker run --rm --platform linux/arm/v7 -v "$W/out:/w:ro" -v "$W/project.rsa.pub:/etc/apk/keys/project.rsa.pub:ro" \
	alpine:3.24 sh -c 'apk add -q --no-cache apk-tools >/dev/null; apk verify /w/tsx-fixture-1-r0.apk' >/dev/null 2>&1
then ok "apk verify passes after resign.sh (project key only)"
else bad "apk verify still fails after resign.sh"
fi

cmp -s "$W/in/tsx-fixture-1-r0.apk" "$W/out/tsx-fixture-1-r0.apk" \
	&& bad "re-signed apk is byte-identical to the throwaway-signed one (no re-sign happened?)" \
	|| ok "re-signed apk differs from the throwaway-signed input (a new signature was written)"

echo "== $N ok, $F failed"
[ $F = 0 ] && echo PASS test-resign || echo FAIL test-resign
exit $F
