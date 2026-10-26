#!/bin/bash
# Host test of the manifest of a deploy (scripts/manifest.py) and of the way a
# run finds it (scripts/live-manifest.sh, with a fake gh). No docker, no key.
#   1. make, verify: the fetched trees must equal the manifest. A whole
#      category that is missing (a 404 for an index), an extra file and a
#      changed byte are errors.
#   2. check-tree: the stable tree of a testing deploy must equal the manifest
#      of the last deploy, not its own fetched copy.
#   3. wait: the CDN serves an older file first. wait polls until the file is
#      the one of the manifest, and fails at the timeout.
#   4. live-manifest.sh: fetch, none, and "another deploy finished".
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1   # no .pyc in the work tree
HERE=$(cd "$(dirname "$0")/.." && pwd)
M="$HERE/manifest.py"
N=0 F=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }
fin() { echo "== $N ok, $F failed"; [ $F = 0 ] && echo PASS test-manifest || echo FAIL test-manifest; exit $F; }
W=$(mktemp -d); SRV=; trap '[ -n "$SRV" ] && kill $SRV 2>/dev/null; rm -rf "$W"' EXIT
mk() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }

SITE=$W/site
mk $SITE/v3.24/common/armv7/a-1-r0.apk A; mk $SITE/v3.24/common/armv7/APKINDEX.tar.gz IA
mk $SITE/v3.24/xx60/armv7/b-1-r0.apk B; mk $SITE/v3.24/xx60/armv7/APKINDEX.tar.gz IB
mk $SITE/testing/v3.24/common/armv7/a-1-r1.apk A1; mk $SITE/testing/v3.24/common/armv7/APKINDEX.tar.gz IT
mk $SITE/promoted.txt "x"; mk $SITE/CNAME "site.example.invalid"
mk $SITE/manifest.txt "old manifest, not listed"
"$M" make --tree $SITE --run 42 --out $W/manifest.txt >/dev/null
head -1 $W/manifest.txt | grep -qx '# manifest run=42' && ! grep -q manifest.txt $W/manifest.txt && ok "make: run id in the first line; the manifest does not list itself" || bad "make: $(cat $W/manifest.txt)"

echo "== 1. verify =="
S=$W/fs T=$W/ft; mkdir -p $S $T; cp -r $SITE/v3.24/. $S/; cp -r $SITE/testing/v3.24/. $T/
"$M" verify --manifest $W/manifest.txt --stable $S --testing $T >/dev/null 2>&1 && ok "the fetched trees equal the manifest" || bad "equal trees refused"
rm -r $S/xx60; OUT=$("$M" verify --manifest $W/manifest.txt --stable $S --testing $T 2>&1) && bad "a missing category accepted (index 404 dropped a category)" || case "$OUT" in *"missing xx60/armv7/APKINDEX.tar.gz"*) ok "a category that is missing (a 404 for its index) is an error";; *) bad "message: $OUT";; esac
cp -r $SITE/v3.24/xx60 $S/; echo X >> $S/common/armv7/a-1-r0.apk
"$M" verify --manifest $W/manifest.txt --stable $S --testing $T >/dev/null 2>&1 && bad "a changed byte accepted" || ok "a changed byte is an error"
cp $SITE/v3.24/common/armv7/a-1-r0.apk $S/common/armv7/; mk $S/common/armv7/extra-1-r0.apk E
"$M" verify --manifest $W/manifest.txt --stable $S --testing $T >/dev/null 2>&1 && bad "an extra file accepted" || ok "an extra file is an error"
rm $S/common/armv7/extra-1-r0.apk
mk $T/common/armv7/APKINDEX.tar.gz "STALE"
"$M" verify --manifest $W/manifest.txt --stable $S --testing $T >/dev/null 2>&1 && bad "a stale testing index accepted" || ok "a stale testing index is an error"
echo "# nothing" > $W/empty.txt; "$M" verify --manifest $W/empty.txt --stable $S >/dev/null 2>&1 && bad "an empty manifest accepted" || ok "a manifest without files is an error"

echo "== 2. check-tree and check-file =="
O=$W/out; mkdir -p $O; cp -r $SITE/v3.24/. $O/
"$M" check-tree --manifest $W/manifest.txt --prefix v3.24 --dir $O >/dev/null 2>&1 && ok "the stable output equals the stable tree of the manifest" || bad "check-tree refused"
mk $O/common/armv7/APKINDEX.tar.gz "signed again"
"$M" check-tree --manifest $W/manifest.txt --prefix v3.24 --dir $O >/dev/null 2>&1 && bad "a re-signed index accepted" || ok "a stable index that changed is an error (a testing deploy must not re-sign stable)"
"$M" check-file --manifest $W/manifest.txt --path promoted.txt --file $SITE/promoted.txt >/dev/null 2>&1 && ok "check-file: promoted.txt matches" || bad "check-file"
"$M" check-file --manifest $W/manifest.txt --path promoted.txt --file $SITE/CNAME >/dev/null 2>&1 && bad "check-file accepted another file" || ok "check-file: another file is refused"

echo "== 3. wait (a CDN that serves the old file first) =="
mkdir -p $W/cdn; cp -r $SITE/. $W/cdn/; mk $W/cdn/v3.24/common/armv7/APKINDEX.tar.gz "OLD INDEX"
python3 -u -m http.server 0 --bind 127.0.0.1 -d "$W/cdn" >"$W/http.log" 2>&1 & SRV=$!
for _ in $(seq 50); do PORT=$(grep -oE 'port [0-9]+' "$W/http.log" | head -1 | cut -d' ' -f2); [ -n "$PORT" ] && break; sleep 0.1; done
"$M" wait --manifest $W/manifest.txt --base http://127.0.0.1:$PORT --timeout 2 --interval 1 >/dev/null 2>&1 && bad "wait accepted the old index" || ok "wait fails at the timeout while the old index is served"
( sleep 2; cp $SITE/v3.24/common/armv7/APKINDEX.tar.gz $W/cdn/v3.24/common/armv7/APKINDEX.tar.gz ) &
OUT=$("$M" wait --manifest $W/manifest.txt --base http://127.0.0.1:$PORT --timeout 20 --interval 1 2>&1) && case "$OUT" in *"waiting"*"matches"*|*"matches"*) ok "wait returns when the CDN serves the new index";; *) bad "wait output: $OUT";; esac || bad "wait did not return: $OUT"
rm $W/cdn/testing/v3.24/common/armv7/APKINDEX.tar.gz
"$M" wait --manifest $W/manifest.txt --base http://127.0.0.1:$PORT --timeout 2 --interval 1 >/dev/null 2>&1 && bad "wait accepted a 404" || ok "a 404 for an index is not a match"

echo "== 4. live-manifest.sh with a fake gh =="
# The fake gh answers from files in $FAKE_DIR: artifacts_<page>.json, run_<id>.json, zip.
# "fail" in $FAKE_DIR makes every call fail (an API error).
FB=$W/fb; mkdir -p $FB $W/fz
cat > $FB/gh <<'GH'
#!/bin/bash
[ -e "$FAKE_DIR/fail" ] && { echo "HTTP 500" >&2; exit 1; }
a="$*"
case "$a" in
*"artifacts?name=live-manifest"*) p=${a##*page=}; cat "$FAKE_DIR/artifacts_${p}.json" 2>/dev/null || echo '{"artifacts":[]}';;
*"/zip"*) cat "$FAKE_DIR/zip";;
*"actions/runs/"*) [ -e "$FAKE_DIR/failruns" ] && { echo "HTTP 502" >&2; exit 1; }; r=${a##*/runs/}; cat "$FAKE_DIR/run_$r.json" 2>/dev/null || exit 1;;
esac
GH
chmod +x $FB/gh
(cd $W/fz && cp $W/manifest.txt manifest.txt && python3 -c "import zipfile;z=zipfile.ZipFile('$W/m.zip','w');z.write('manifest.txt');z.close()")
cp $W/m.zip $W/fz/zip
LM() { (PATH="$FB:$PATH" FAKE_DIR=$W/fz GITHUB_REPOSITORY=o/r "$HERE/live-manifest.sh" "$@" 2>&1); }
# art ID RUN [BRANCH [HEAD_REPO [EXPIRED]]]: one artifact entry
art() { printf '{"id":%s,"expired":%s,"workflow_run":{"id":%s,"head_branch":"%s","head_repository_id":%s,"repository_id":1}}' "$1" "${5:-false}" "$2" "${3:-main}" "${4:-1}"; }
# run RUN [EVENT [PATH [HEAD_REPO]]]: the run behind it
run() { printf '{"id":%s,"path":"%s","event":"%s","head_branch":"main","conclusion":"success","head_repository":{"id":%s},"repository":{"id":1}}' "$1" "${3:-.github/workflows/build.yml}" "${2:-push}" "${4:-1}" > $W/fz/run_$1.json; }
page() { printf '{"artifacts":[%s]}' "$2" > $W/fz/artifacts_$1.json; }
rm -f $W/fz/*.json $W/fz/fail
page 1 "$(art 777 70)"; run 70
OUT=$(LM fetch $W/got.txt) && [ "$OUT" = artifact_id=777 ] && cmp -s $W/got.txt $W/manifest.txt && ok "fetch: the manifest of the newest live-manifest, with its id" || bad "fetch: $OUT"
page 1 "$(art 900 90 main 2),$(art 901 91 feature 1),$(art 902 92 main 1 true),$(art 903 93),$(art 904 94),$(art 905 95),$(art 777 70)"
run 90 push .github/workflows/build.yml 2; run 91; run 93 pull_request; run 94 push .github/workflows/other.yml; run 95 workflow_dispatch; run 70
OUT=$(LM fetch $W/got.txt); case "$OUT" in artifact_id=905) ok "fetch: skips a fork artifact (head repository 2), a feature branch, an expired one, a pull_request run and another workflow; takes the dispatch run";; *) bad "filtering gave: $OUT";; esac
page 1 "$(art 900 90 main 2),$(art 901 91 feature 1)"; page 2 ""
OUT=$(LM fetch $W/got2.txt); rc=$?; [ $rc = 3 ] && [ "$OUT" = artifact_id=none ] && ok "fetch: only foreign artifacts give exit 3 (none)" || bad "foreign only: rc $rc $OUT"
# page 2: 30 entries on page 1 that fail the checks, the good one on page 2
FILL=""; for i in $(seq 1 30); do FILL="$FILL$(art $((1000+i)) 90 main 2),"; done
page 1 "${FILL%,}"; page 2 "$(art 888 70)"
OUT=$(LM fetch $W/got.txt); [ "$OUT" = artifact_id=888 ] && ok "fetch: reads the second page when the first has 30 entries" || bad "page 2: $OUT"
# R3-1: the run lookup fails (HTTP 502) while the artifact list works. The old pipeline lost the
# failure and ended as "none" (exit 3).
page 1 "$(art 777 70)"; run 70
touch $W/fz/failruns; OUT=$(LM fetch $W/got4.txt); rc=$?; [ $rc = 1 ] && ok "fetch: HTTP 502 on runs/<id> exits 1 (not 3)" || bad "502 on runs: rc $rc $OUT"
LM same 777 >/dev/null && bad "same accepted a 502 on runs/<id>" || ok "same: HTTP 502 on runs/<id> fails"
rm -f $W/fz/failruns
touch $W/fz/fail; OUT=$(LM fetch $W/got3.txt); rc=$?; [ $rc = 1 ] && ok "fetch: an API error exits 1 (not 3, not none)" || bad "API error: rc $rc $OUT"
LM same none >/dev/null; [ $? != 0 ] && ok "same: an API error is an error" || bad "same accepted an API error"
rm -f $W/fz/fail
page 1 "$(art 777 70)"; page 2 ""
LM same 777 >/dev/null && ok "same: no other deploy" || bad "same"
page 1 "$(art 778 70),$(art 777 70)"; LM same 777 >/dev/null && bad "same accepted a newer deploy" || ok "same: another deploy finished, the run must stop"
page 1 ""; LM same none >/dev/null && ok "same none: still no deploy" || bad "same none"
fin
