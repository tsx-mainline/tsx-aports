#!/bin/bash
# Host test of scripts/channels.py (the tree logic of the stable and the
# testing channel). It needs no network, no docker and no key. The apks are
# plain files, because channels.py reads names and bytes only.
#   1. The order of apk versions (and, with docker, the same pairs against
#      `apk version -t`).
#   2. assemble: testing = stable + the newer testing packages; the stable
#      tree does not change; same or older testing versions are dropped; a
#      testing-only package stays; a missing testing tree is empty.
#   3. promote: the exact bytes arrive in stable; promoted.txt records name
#      and sha256; a bad word changes nothing; "all"; one name in two
#      architectures.
#   4. After a promote, assemble drops the testing copy that stable has now.
#   6. promote takes whole builds: the subpackages of the same origin and the
#      exact depends; it fails without an index or with a depend that is nowhere.
#   7. sort: the apk order of file names.
#   5. same: finds a changed byte, an extra file and a missing file.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1   # no .pyc in the work tree
HERE=$(cd "$(dirname "$0")/.." && pwd)   # scripts/tests -> scripts
CH="$HERE/channels.py"
N=0 F=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }
fin() { echo "== $N ok, $F failed"; [ $F = 0 ] && echo PASS test-channels || echo FAIL test-channels; exit $F; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

echo "== 1. version order =="
PAIRS="1.0:1.0.1 1.0-r2:1.0-r10 0.20.2-r1:0.20.2-r2 6.18.54_git20260928-r9:6.18.54_git20260928-r10 6.18.54_git20260928-r10:6.18.54_git20261004-r1
1.0_rc1:1.0 1.0_alpha:1.0_beta 1.0_beta:1.0_rc1 1.0:1.0_p1 1.0:1.0a 1.0a:1.0b 1.01:1.1 2.0:10.0 152.0.7977.82-r0:152.0.7977.82-r1 1.0_git20260101:1.0_git20260102 1.0:1.0-r1"
for p in $PAIRS; do
	a=${p%%:*} b=${p##*:}
	[ "$($CH compare "$a" "$b")" = -1 ] && [ "$($CH compare "$b" "$a")" = 1 ] && [ "$($CH compare "$a" "$a")" = 0 ] \
		&& ok "$a < $b" || bad "$a < $b gives $($CH compare "$a" "$b")"
done
if command -v docker >/dev/null && docker image inspect alpine:3.24 >/dev/null 2>&1; then
	for p in $PAIRS; do
		a=${p%%:*} b=${p##*:}
		[ "$(docker run --rm alpine:3.24 apk version -t "$a" "$b")" = "<" ] && ok "apk version -t agrees: $a < $b" || bad "apk version -t disagrees: $a $b"
	done
else echo "  (no docker image alpine:3.24 here: the comparison with apk version -t is skipped)"; fi

mk() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }   # mk FILE CONTENT
# mkidx DIR [name=origin[:dep,dep]]...: write DIR/APKINDEX.tar.gz for the apks in DIR
# (a gzip member of a tar with APKINDEX; the signature member is not needed here).
# The origin of a name is the name, unless a word says otherwise.
mkidx() {
	python3 -I - "$@" <<'PY'
import gzip, io, os, re, sys, tarfile
d, words = sys.argv[1], sys.argv[2:]
spec = {}
for w in words:
    n, _, rest = w.partition('=')
    o, _, deps = rest.partition(':')
    spec[n] = (o, deps.replace(',', ' '))
text = ''
for fn in sorted(os.listdir(d)):
    m = re.match(r'^(.+)-([0-9][^-]*-r[0-9]+)\.apk$', fn)
    if m:
        o, deps = spec.get(m[1], (m[1], ''))
        text += f'P:{m[1]}\nV:{m[2]}\no:{o or m[1]}\n' + (f'D:{deps}\n' if deps else '') + '\n'
b = io.BytesIO()
with tarfile.open(fileobj=b, mode='w') as t:
    data = text.encode()
    ti = tarfile.TarInfo('APKINDEX'); ti.size = len(data); t.addfile(ti, io.BytesIO(data))
open(os.path.join(d, 'APKINDEX.tar.gz'), 'wb').write(gzip.compress(b.getvalue()))
PY
}
S=$W/stable T=$W/testing
mk $S/common/armv7/tsx-a-1.0-r1.apk "stable a r1"
mk $S/common/armv7/tsx-a-1.0-r2.apk "stable a r2"
mk $S/common/armv7/tsx-b-1.0-r1.apk "stable b r1"
mk $S/common/armv7/tsx-b-sub-1.0-r1.apk "stable b-sub r1"
mk $S/xx60/armv7/tsx-xx60-k-6.18.54_git20260928-r10.apk "stable k r10"
mk $S/common/armv7/APKINDEX.tar.gz "stable index"
mk $T/common/armv7/tsx-a-1.0-r2.apk "testing a r2 (stable has r2)"
mk $T/common/armv7/tsx-a-1.0-r3.apk "testing a r3"
mk $T/common/armv7/tsx-b-1.0-r1.apk "testing b r1 DIFFERENT BYTES"
mk $T/common/armv7/tsx-c-2.0-r0.apk "testing c r0 (new package)"
mk $T/common/armv7/tsx-b-sub-0.9-r5.apk "testing b-sub 0.9 (older)"
mk $T/xx60/armv7/tsx-xx60-k-6.18.54_git20260928-r9.apk "testing k r9 (older)"
mkidx $T/common/armv7; mkidx $T/xx60/armv7
SUM_S=$(cd $S && find . -type f | sort | xargs sha256sum | sha256sum)
SUM_T=$(cd $T && find . -type f | sort | xargs sha256sum | sha256sum)

echo "== 2. assemble =="
O=$W/out
OUT=$($CH assemble --stable $S --testing $T --out $O 2>&1) || bad "assemble failed: $OUT"
has() { [ -f "$O/$1" ]; }
for f in common/armv7/tsx-a-1.0-r1.apk common/armv7/tsx-a-1.0-r2.apk common/armv7/tsx-b-1.0-r1.apk common/armv7/tsx-b-sub-1.0-r1.apk xx60/armv7/tsx-xx60-k-6.18.54_git20260928-r10.apk; do
	has $f && cmp -s $O/$f $S/$f && ok "stable file kept with its bytes: $f" || bad "stable file lost or changed: $f"
done
has common/armv7/tsx-a-1.0-r3.apk && [ "$(cat $O/common/armv7/tsx-a-1.0-r3.apk)" = "testing a r3" ] && ok "newer testing version added (r3)" || bad "r3 missing"
has common/armv7/tsx-c-2.0-r0.apk && ok "testing-only package added" || bad "new package missing"
[ "$(cat $O/common/armv7/tsx-b-1.0-r1.apk)" = "stable b r1" ] && ok "same version in testing: the stable bytes win" || bad "testing bytes replaced stable b r1"
has common/armv7/tsx-b-sub-0.9-r5.apk && bad "older testing subpackage kept" || ok "older testing version dropped (0.9 < 1.0)"
has xx60/armv7/tsx-xx60-k-6.18.54_git20260928-r9.apk && bad "older kernel kept" || ok "older testing kernel dropped"
has common/armv7/APKINDEX.tar.gz && bad "an index was copied" || ok "no index copied (index.sh makes it)"
[ "$(cd $S && find . -type f | sort | xargs sha256sum | sha256sum)" = "$SUM_S" ] && ok "the stable tree did not change" || bad "stable changed"
[ "$(cd $T && find . -type f | sort | xargs sha256sum | sha256sum)" = "$SUM_T" ] && ok "the testing input did not change" || bad "testing input changed"
$CH assemble --stable $S --testing $W/none --out $W/out2 >/dev/null 2>&1 && [ "$(cd $W/out2 && find . -name '*.apk' | wc -l)" = 5 ] \
	&& ok "no testing tree: testing = stable" || bad "missing testing tree"
$CH assemble --stable $S --testing $T --out $O >/dev/null 2>&1 && bad "assemble over a non-empty directory" || ok "refuses a non-empty OUT"
$CH assemble --stable $W/none --testing $T --out $W/out3 >/dev/null 2>&1 && [ -f $W/out3/common/armv7/tsx-b-1.0-r1.apk ] \
	&& ok "no stable tree: all of testing is new" || bad "missing stable tree"

echo "== 3. promote =="
LOG=$W/promoted.txt
ST=$(cd $S && find . -type f | sort | xargs sha256sum | sha256sum)
for w in nope tsx-b tsx-a-1.0-r2 "tsx-c nope"; do
	OUT=$($CH promote --stable $S --testing $T --packages "$w" --log $LOG 2>&1) && bad "promote '$w' accepted: $OUT" || ok "promote '$w' refused: $(echo "$OUT" | tail -1)"
done
[ "$(cd $S && find . -type f | sort | xargs sha256sum | sha256sum)" = "$ST" ] && [ ! -e $LOG ] && ok "a refused promote changed nothing (also not for the good word of 'tsx-c nope')" || bad "a refused promote changed stable or the log"
$CH promote --stable $S --testing $T --packages "" --log $LOG >/dev/null 2>&1 && bad "empty list accepted" || ok "empty list refused"
OUT=$($CH promote --stable $S --testing $T --packages "tsx-a, tsx-c" --log $LOG --run 4711 2>&1) || bad "promote failed: $OUT"
cmp -s $S/common/armv7/tsx-a-1.0-r3.apk $T/common/armv7/tsx-a-1.0-r3.apk && ok "tsx-a-1.0-r3.apk has the bytes of testing" || bad "tsx-a bytes"
cmp -s $S/common/armv7/tsx-c-2.0-r0.apk $T/common/armv7/tsx-c-2.0-r0.apk && ok "tsx-c-2.0-r0.apk has the bytes of testing" || bad "tsx-c bytes"
[ "$(cat $S/common/armv7/tsx-b-1.0-r1.apk)" = "stable b r1" ] && ok "other stable files unchanged" || bad "tsx-b changed"
H=$(sha256sum $T/common/armv7/tsx-a-1.0-r3.apk | cut -d' ' -f1)
grep -qE "^[0-9TZ:-]+ 4711 common/armv7/tsx-a-1.0-r3.apk $H\$" $LOG && [ "$(wc -l < $LOG)" = 2 ] && ok "promoted.txt: name and sha256, 2 lines" || bad "log: $(cat $LOG)"
$CH promote --stable $S --testing $T --packages "tsx-a" --log $LOG >/dev/null 2>&1 && bad "promoted twice" || ok "a second promote of the same version is refused"

echo "== 4. after the promote =="
rm -rf $O; $CH assemble --stable $S --testing $T --out $O >/dev/null 2>&1
has common/armv7/tsx-a-1.0-r3.apk && cmp -s $O/common/armv7/tsx-a-1.0-r3.apk $S/common/armv7/tsx-a-1.0-r3.apk && ok "testing has r3 from stable now" || bad "r3 missing after promote"
OUT=$($CH assemble --stable $S --testing $T --out $W/o4 2>&1); case "$OUT" in *"dropped common/armv7/tsx-a-1.0-r3.apk (stable has 1.0-r3)"*) ok "the testing copy of r3 is dropped";; *) bad "no drop line: $OUT";; esac
[ "$(cd $W/o4 && find . -type f | sort | xargs sha256sum | sha256sum)" = "$(cd $O && find . -type f | sort | xargs sha256sum | sha256sum)" ] && ok "assembling twice gives the same tree" || bad "trees differ"

# all, and one name in two architectures
mk $T/common/aarch64/tsx-d-1.0-r1.apk "d aarch64"
mk $T/common/armv7/tsx-d-1.0-r1.apk "d armv7"
mk $T/common/armv7/tsx-e-1.0-r1.apk "e"
mkidx $T/common/armv7; mkidx $T/common/aarch64
OUT=$($CH promote --stable $S --testing $T --packages "tsx-d" --log $LOG 2>&1) && [ -f $S/common/aarch64/tsx-d-1.0-r1.apk ] && [ -f $S/common/armv7/tsx-d-1.0-r1.apk ] && ok "one name, two architectures: both promoted" || bad "tsx-d: $OUT"
OUT=$($CH promote --stable $S --testing $T --packages "all" --log $LOG 2>&1) && [ -f $S/common/armv7/tsx-e-1.0-r1.apk ] && ok "all: the rest is promoted" || bad "all: $OUT"
$CH promote --stable $S --testing $T --packages all --log $LOG >/dev/null 2>&1 && bad "all with nothing to do accepted" || ok "all with nothing to promote is refused"

echo "== 6. promote takes whole builds =="
S2=$W/s2 T2=$W/t2
mk $S2/xx60/armv7/tsx-xx60-board-0.9-r1.apk "old board"; mk $S2/xx60/armv7/tsx-xx60-board-ha-0.9-r1.apk "old ha"
mk $T2/xx60/armv7/tsx-xx60-board-1.0-r1.apk "board 1.0"; mk $T2/xx60/armv7/tsx-xx60-board-ha-1.0-r1.apk "ha 1.0"
mk $T2/xx60/armv7/tsx-xx60-board-kiosk-1.0-r1.apk "kiosk 1.0"; mk $T2/xx60/armv7/tsx-other-2.0-r1.apk "other"
mk $T2/xx60/armv7/tsx-pin-1.0-r1.apk "pin user"; mk $T2/common/armv7/tsx-lib-3.0-r1.apk "lib 3.0"
mkidx $T2/xx60/armv7 tsx-xx60-board-ha=tsx-xx60-board:tsx-xx60-board=1.0-r1 tsx-xx60-board-kiosk=tsx-xx60-board:tsx-xx60-board=1.0-r1 \
	"tsx-pin=tsx-pin:tsx-lib=3.0-r1,so:libc.musl-armv7.so.1"
mkidx $T2/common/armv7
SS=$(cd $S2 && find . -type f | sort | xargs sha256sum | sha256sum)
OUT=$($CH promote --stable $S2 --testing $T2 --packages "tsx-xx60-board" --log $W/p2.txt 2>&1) || bad "board promote failed: $OUT"
[ -f $S2/xx60/armv7/tsx-xx60-board-ha-1.0-r1.apk ] && [ -f $S2/xx60/armv7/tsx-xx60-board-kiosk-1.0-r1.apk ] && [ -f $S2/xx60/armv7/tsx-xx60-board-1.0-r1.apk ] \
	&& ok "promote of the main package takes its subpackages (same origin and version)" || bad "subpackages missing: $OUT"
[ ! -f $S2/xx60/armv7/tsx-other-2.0-r1.apk ] && ok "an unrelated package is not taken" || bad "tsx-other taken"
[ "$(wc -l < $W/p2.txt)" = 3 ] && ok "promoted.txt lists all 3 files" || bad "log: $(cat $W/p2.txt)"
rm -rf $S2; mk $S2/xx60/armv7/tsx-xx60-board-0.9-r1.apk "old board"
OUT=$($CH promote --stable $S2 --testing $T2 --packages "tsx-xx60-board-ha" 2>&1) || bad "ha promote failed: $OUT"
[ -f $S2/xx60/armv7/tsx-xx60-board-1.0-r1.apk ] && [ -f $S2/xx60/armv7/tsx-xx60-board-kiosk-1.0-r1.apk ] && ok "promote of a subpackage takes the main package and its siblings" || bad "ha alone: $OUT"
rm -rf $S2; mk $S2/xx60/armv7/tsx-xx60-board-0.9-r1.apk "old board"
OUT=$($CH promote --stable $S2 --testing $T2 --packages "tsx-pin" 2>&1) || bad "pin promote failed: $OUT"
[ -f $S2/common/armv7/tsx-lib-3.0-r1.apk ] && ok "an exact depend (tsx-lib=3.0-r1) that stable lacks is taken too" || bad "tsx-lib not taken: $OUT"
rm -rf $S2; mk $S2/xx60/armv7/tsx-xx60-board-0.9-r1.apk "old board"; mk $S2/common/armv7/tsx-lib-3.0-r1.apk "lib in stable"
OUT=$($CH promote --stable $S2 --testing $T2 --packages "tsx-pin" 2>&1) && [ ! -e $S2/common/armv7/tsx-lib-3.0-r1.apk.x ] && [ "$(cat $S2/common/armv7/tsx-lib-3.0-r1.apk)" = "lib in stable" ] \
	&& ok "an exact depend that stable has is left alone" || bad "tsx-lib in stable: $OUT"
rm -rf $S2; mk $S2/xx60/armv7/tsx-xx60-board-0.9-r1.apk "old board"
mkidx $T2/xx60/armv7 "tsx-pin=tsx-pin:tsx-missing=9-r1"
OUT=$($CH promote --stable $S2 --testing $T2 --packages "tsx-pin" 2>&1) && bad "a depend that is nowhere accepted" || case "$OUT" in *"tsx-missing=9-r1"*) ok "an exact depend that is nowhere: refused";; *) bad "message: $OUT";; esac
[ ! -e $S2/xx60/armv7/tsx-pin-1.0-r1.apk ] && ok "  ... and nothing was copied" || bad "partial copy"
rm $T2/xx60/armv7/APKINDEX.tar.gz
OUT=$($CH promote --stable $S2 --testing $T2 --packages "tsx-xx60-board" 2>&1) && bad "promote without an index accepted" || case "$OUT" in *"no APKINDEX.tar.gz"*) ok "no index in the testing tree: refused";; *) bad "message: $OUT";; esac

echo "== 7. sort (apk order) =="
GOT=$(printf '%s\n' tsx-a-1.0-r10.apk tsx-a-1.0_pre1-r0.apk tsx-a-1.0-r2.apk tsx-a-1.0a-r0.apk tsx-a-0.9-r9.apk | $CH sort | tr '\n' ' ')
[ "$GOT" = "tsx-a-0.9-r9.apk tsx-a-1.0_pre1-r0.apk tsx-a-1.0-r2.apk tsx-a-1.0-r10.apk tsx-a-1.0a-r0.apk " ] && ok "sort: $GOT" || bad "sort gives: $GOT"

echo "== 5. same =="
mkdir -p $W/x $W/y; cp -r $S/. $W/x; cp -r $S/. $W/y
$CH same $W/x $W/y >/dev/null 2>&1 && ok "identical trees" || bad "identical trees differ"
echo X >> $W/y/common/armv7/tsx-b-1.0-r1.apk; $CH same $W/x $W/y >/dev/null 2>&1 && bad "a changed byte not found" || ok "a changed byte is found"
cp $W/x/common/armv7/tsx-b-1.0-r1.apk $W/y/common/armv7/; touch $W/y/extra; $CH same $W/x $W/y >/dev/null 2>&1 && bad "extra file not found" || ok "an extra file is found"
rm $W/y/extra $W/y/common/armv7/APKINDEX.tar.gz; $CH same $W/x $W/y >/dev/null 2>&1 && bad "missing index not found" || ok "a missing file is found"
fin
