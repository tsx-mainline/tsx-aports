#!/bin/bash
# Host tests for the CI publish path (.github/workflows/build.yml):
#   1. scripts/carry-forward.py against a local HTTP server: fetch and verify,
#      a 404 site, a tampered apk, a bad or unknown index signature, a trimmed
#      seed tarball, and the fallback seed.
#   2. scripts/build.sh --skip-existing.
#   3. scripts/build.sh --skip-unreachable (a 404 source, as for a kernel).
#      scripts/build.sh --verify (no `abuild -F checksum` before the build).
#   4. scripts/index.sh --keep 2 over a tree with carried-forward packages and
#      new packages, and the result verifies again.
# The tests do packaging only. The fixture packages hold one text file. Each
# test builds them with abuild in a disposable Alpine container (like
# test-resign.sh). Sections 2 and 3 use a fake `docker` that only reports the
# call. The signing key is a throwaway fixture key, never the key of the
# project.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)   # scripts/tests -> scripts
N=0 F=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }
fin() { echo "== $N ok, $F failed"; [ $F = 0 ] && echo PASS test-ci-pages || echo FAIL test-ci-pages; exit $F; }
command -v docker >/dev/null || { echo "no docker: skipped"; exit 0; }

W=$(mktemp -d); SRV=
trap '[ -n "$SRV" ] && kill $SRV 2>/dev/null; rm -rf "$W"' EXIT
openssl genrsa -out "$W/project.rsa" 4096 >/dev/null 2>&1
openssl rsa -in "$W/project.rsa" -pubout -out "$W/project.rsa.pub" >/dev/null 2>&1
mkdir -p "$W/keys" && cp "$W/project.rsa.pub" "$W/keys/"
openssl genrsa -out "$W/other.rsa" 4096 >/dev/null 2>&1
openssl rsa -in "$W/other.rsa" -pubout -out "$W/other.rsa.pub" >/dev/null 2>&1

# mkpkg PKGREL DESTDIR: build tsx-fixture-1-r<PKGREL>, signed with the fixture key
mkpkg() {
	local b="$W/b$1"; mkdir -p "$b/common/tsx-fixture"
	cat > "$b/common/tsx-fixture/APKBUILD" <<APKBUILD
pkgname=tsx-fixture
pkgver=1
pkgrel=$1
pkgdesc="test-ci-pages.sh fixture"
url="https://example.invalid"
arch=noarch
license="GPL-2.0-or-later"
package() { mkdir -p "\$pkgdir"/usr/share/tsx-fixture; echo $1 > "\$pkgdir"/usr/share/tsx-fixture/rel; }
APKBUILD
	docker run --rm --platform linux/arm/v7 -v "$b:/b" -v "$2:/out" -v "$W/project.rsa:/keys/project.rsa:ro" \
		-v "$W/project.rsa.pub:/keys/project.rsa.pub:ro" alpine:3.24 sh -euc '
		apk add --no-cache alpine-sdk >/dev/null
		cp /keys/project.rsa.pub /etc/apk/keys/
		mkdir -p /root/.abuild; echo PACKAGER_PRIVKEY=/keys/project.rsa > /root/.abuild/abuild.conf
		cd /b/common/tsx-fixture && abuild -F -r -P /out
		chown -R '"$(id -u):$(id -g)"' /out /b' >"$W/mkpkg.log" 2>&1
}
mkdir -p "$W/site/v3.24"
for r in 0 1 2; do mkpkg $r "$W/site/v3.24"; done
if [ ! -f "$W/site/v3.24/common/armv7/tsx-fixture-1-r2.apk" ]; then
	echo "  SKIPPED: could not build the fixture packages"; tail -n 15 "$W/mkpkg.log"; exit 0
fi
IDX=$W/site/v3.24/common/armv7/APKINDEX.tar.gz
CF="$HERE/carry-forward.py --keys $W/keys"

python3 -u -m http.server 0 --bind 127.0.0.1 -d "$W/site" >"$W/http.log" 2>&1 & SRV=$!
for _ in $(seq 50); do PORT=$(grep -oE 'port [0-9]+' "$W/http.log" | head -1 | cut -d' ' -f2); [ -n "$PORT" ] && break; sleep 0.1; done
URL=http://127.0.0.1:$PORT

echo "== 1. carry-forward.py =="
if OUT=$($CF --from $URL --dest "$W/d1" 2>&1) && [ "$(ls "$W"/d1/common/armv7/*.apk | wc -l)" = 3 ] && [ -f "$W/d1/common/armv7/APKINDEX.tar.gz" ]; then
	ok "fetches the published tree over HTTP (3 apks + index; xx60 absent is fine)"
else bad "fetch: $OUT"; fi
$CF --from $URL --dest "$W/d1" >/dev/null 2>&1 && ok "second run over existing files succeeds" || bad "re-run failed"

if OUT=$($CF --from $URL/nothing-here --dest "$W/d2" 2>&1); then ok "404 (empty site) is not an error: $(echo "$OUT" | tail -1)"; else bad "404 site failed: $OUT"; fi

cp -r "$W/site" "$W/tamper"; cp "$W/site/v3.24/common/armv7/tsx-fixture-1-r0.apk" "$W/tamper/v3.24/common/armv7/tsx-fixture-1-r2.apk"
python3 -u -m http.server 0 --bind 127.0.0.1 -d "$W/tamper" >"$W/http2.log" 2>&1 & S2=$!
for _ in $(seq 50); do P2=$(grep -oE 'port [0-9]+' "$W/http2.log" | head -1 | cut -d' ' -f2); [ -n "$P2" ] && break; sleep 0.1; done
if OUT=$($CF --from http://127.0.0.1:$P2 --dest "$W/d3" 2>&1); then bad "a swapped apk was accepted"; else
	case "$OUT" in *"does not match the checksum"*) ok "an apk that does not match the signed index is refused";; *) bad "wrong error: $OUT";; esac; fi
kill $S2 2>/dev/null

mkdir -p "$W/keys-other"; cp "$W/other.rsa.pub" "$W/keys-other/"
if OUT=$($HERE/carry-forward.py --keys "$W/keys-other" --from $URL --dest "$W/d4" 2>&1); then bad "unknown signing key accepted"; else
	case "$OUT" in *"not one of the committed keys"*) ok "index signed by a key that is not committed is refused";; *) bad "wrong error: $OUT";; esac; fi
mkdir -p "$W/keys-swap"; cp "$W/other.rsa.pub" "$W/keys-swap/project.rsa.pub"
if OUT=$($HERE/carry-forward.py --keys "$W/keys-swap" --from $URL --dest "$W/d5" 2>&1); then bad "wrong public key under the right name accepted"; else
	case "$OUT" in *"BAD SIGNATURE"*) ok "index whose signature does not verify is refused";; *) bad "wrong error: $OUT";; esac; fi

(cd "$W/site" && tar -czf "$W/seed.tar.gz" --exclude='*-r0.apk' v3.24)
if OUT=$($CF --seed "$W/seed.tar.gz" --dest "$W/d6" 2>&1) && [ "$(ls "$W"/d6/common/armv7/*.apk | wc -l)" = 2 ]; then
	ok "seed tarball with a trimmed apk (index lists r0, tarball lacks it): 2 apks, no error"; else bad "seed: $OUT"; fi
$CF --seed "$W/none.tar.gz" --dest "$W/d7" >/dev/null 2>&1 && bad "missing --seed accepted" || ok "a missing --seed is an error"
if OUT=$($CF --from $URL/nothing-here --fallback-seed "$W/seed.tar.gz" --dest "$W/d8" 2>&1) && [ "$(ls "$W"/d8/common/armv7/*.apk | wc -l)" = 2 ]; then
	ok "fallback seed used when the site is empty"; else bad "fallback: $OUT"; fi
OUT=$($CF --from $URL/nothing-here --fallback-seed "$W/none.tar.gz" --dest "$W/d9" 2>&1) && case "$OUT" in *"::warning"*) ok "missing fallback seed only warns";; *) bad "no warning: $OUT";; esac
$CF --from $URL --fallback-seed "$W/none.tar.gz" --dest "$W/d10" 2>&1 | grep -q warning && bad "fallback consulted although the site had content" || ok "fallback ignored when the site has content"

echo "== 2/3. build.sh --skip-existing / --skip-unreachable (fake docker) =="
R=$W/repo; mkdir -p "$R/scripts" "$R/common/tsx-fixture" "$R/xx60/tsx-fixture-kernel" "$R/packages/v3.24/common/armv7" "$W/bin"
cp "$HERE/build.sh" "$HERE/arch-image.sh" "$R/scripts/"; cp "$W"/d1/common/armv7/* "$R/packages/v3.24/common/armv7/"
# The fake docker answers the image steps of scripts/arch-image.sh (pull, tag,
# and `apk --print-arch`). A build (`docker run ... sh -euc SCRIPT`) prints
# DOCKER-CALLED and its script.
cat > "$W/bin/docker" <<'DOCKER'
#!/bin/sh
case "$1" in pull|tag|image) exit 0;; esac
case "$*" in
*"apk --print-arch"*) case "$*" in *arm/v7*) echo armv7;; *) echo aarch64;; esac; exit 0;;
esac
for a in "$@"; do last=$a; done
echo DOCKER-CALLED
echo "DOCKER-SCRIPT: $last"
DOCKER
chmod +x "$W/bin/docker"
touch "$W/k" "$W/k.pub"
BS() { (cd "$R" && PATH="$W/bin:$PATH" TSX_APORTS_KEY="$W/k" scripts/build.sh "$@" 2>&1); }
mkapk() { printf 'pkgname=%s\npkgver=1\npkgrel=%s\narch=armv7\nsource="%s"\n' "$2" "$3" "$4" > "$R/$1/APKBUILD"; }

mkapk common/tsx-fixture tsx-fixture 2 ""; mkapk xx60/tsx-fixture-kernel tsx-fixture-kernel 1 "http://127.0.0.1:$PORT/gone/bundle.tar.zst"
OUT=$(BS --skip-existing common/tsx-fixture)
case "$OUT" in *"already in packages"*) ok "existing tsx-fixture-1-r2.apk: not rebuilt";; *) bad "skip-existing: $OUT";; esac
case "$OUT" in *DOCKER-CALLED*) bad "docker ran for an existing package";; *) ok "no build for an existing package";; esac
mkapk common/tsx-fixture tsx-fixture 3 ""
OUT=$(BS --skip-existing common/tsx-fixture)
case "$OUT" in *DOCKER-CALLED*) ok "a new pkgrel (r3) is built";; *) bad "r3 not built: $OUT";; esac
OUT=$(BS common/tsx-fixture); mkapk common/tsx-fixture tsx-fixture 2 ""
case "$OUT" in *DOCKER-CALLED*) ok "without --skip-existing an existing version is still built";; *) bad "plain build changed: $OUT";; esac
OUT=$(BS --skip-existing --all)
case "$OUT" in *"already in packages"*) ok "--all --skip-existing: existing skipped";; *) bad "--all: $OUT";; esac

OUT=$(BS --skip-unreachable xx60/tsx-fixture-kernel); RC=$?
case "$OUT" in *"::warning title=tsx-fixture-kernel skipped::"*"HTTP 404"*) ok "404 source: ::warning:: and skipped";; *) bad "404: $OUT";; esac
[ $RC = 0 ] && ok "  ... exit status 0" || bad "  ... exit status $RC"
case "$OUT" in *DOCKER-CALLED*) bad "docker ran for a 404 source";; *) ok "  ... no build attempted";; esac
mkdir -p "$R/xx60/tsx-fixture-kernel/dist"; touch "$R/xx60/tsx-fixture-kernel/dist/bundle.tar.zst"
OUT=$(BS --skip-unreachable xx60/tsx-fixture-kernel)
case "$OUT" in *DOCKER-CALLED*) ok "source staged in dist/ counts as present";; *) bad "dist/: $OUT";; esac
rm -rf "$R/xx60/tsx-fixture-kernel/dist"; mkapk xx60/tsx-fixture-kernel tsx-fixture-kernel 1 "http://127.0.0.1:$PORT/v3.24/common/armv7/tsx-fixture-1-r2.apk"
OUT=$(BS --skip-unreachable xx60/tsx-fixture-kernel)
case "$OUT" in *DOCKER-CALLED*) ok "reachable source: built";; *) bad "200: $OUT";; esac
mkapk xx60/tsx-fixture-kernel tsx-fixture-kernel 1 "http://127.0.0.1:1/x.tar.zst"
OUT=$(BS --skip-unreachable xx60/tsx-fixture-kernel); RC=$?
[ $RC != 0 ] && ok "a network failure (not 404) still fails the run" || bad "connection refused was skipped: $OUT"

# --verify leaves out the checksum step. The fake docker prints the script of
# the build, so the test can read the steps.
mkapk common/tsx-fixture tsx-fixture 5 ""
OUT=$(BS common/tsx-fixture)
case "$OUT" in *"abuild -F checksum"*) ok "a plain build runs abuild checksum";; *) bad "plain build has no checksum step: $OUT";; esac
OUT=$(BS --verify common/tsx-fixture)
case "$OUT" in *"abuild -F -r"*) ok "--verify: the build still runs";; *) bad "--verify: no build: $OUT";; esac
case "$OUT" in *"abuild -F checksum"*) bad "--verify still runs abuild checksum";; *) ok "--verify: no abuild checksum";; esac

echo "== 4. index.sh --keep 2 over carried-forward + fresh packages =="
P=$W/idx; mkdir -p "$P/scripts" "$P/packages/v3.24"
cp "$HERE/index.sh" "$HERE/arch-image.sh" "$P/scripts/"; cp -r "$W/d1/." "$P/packages/v3.24/"
mkpkg 3 "$P/packages/v3.24"   # the "fresh build" of this run, next to the carried r0..r2
ls "$P"/packages/v3.24/common/armv7/*.apk | wc -l | grep -qx 4 && ok "mixed tree holds r0-r2 (carried) + r3 (built)" || bad "mixed tree wrong"
if OUT=$(TSX_APORTS_KEY="$W/project.rsa" "$P/scripts/index.sh" --keep 2 --out "$P/repo" 2>&1); then
	L=$(cd "$P/repo/v3.24/common/armv7" && echo *.apk)
	[ "$L" = "tsx-fixture-1-r2.apk tsx-fixture-1-r3.apk" ] && ok "pruned to the newest 2: $L" || bad "prune left: $L"
	if OUT=$($CF --from "$P/repo" --dest "$W/d11" 2>&1); then ok "re-signed index verifies against the fixture key and lists what is there"; else bad "verify: $OUT"; fi
else bad "index.sh: $OUT"; fi
fin
