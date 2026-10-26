#!/bin/bash
# Host test of the mode of a run (scripts/decide-mode.sh) and of the check that
# a testing build takes its commit from the branch testing
# (scripts/check-testing-sha.sh). It needs git, no network and no docker.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1   # no .pyc in the work tree
HERE=$(cd "$(dirname "$0")/.." && pwd)
N=0 F=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }
fin() { echo "== $N ok, $F failed"; [ $F = 0 ] && echo PASS test-mode || echo FAIL test-mode; exit $F; }
SHA=0123456789abcdef0123456789abcdef01234567

echo "== decide-mode.sh =="
# mode EVENT REF ACTION CHANNEL SHA PACKAGES [SEED_URL [BASE_REF]]: prints
# "mode publish source_sha channel", or ERROR
mode() {
	local out
	out=$(GITHUB_EVENT_NAME=$1 GITHUB_REF=$2 ACTION=$3 CHANNEL=$4 SOURCE_SHA=$5 PACKAGES=$6 SEED_URL=${7:-} GITHUB_BASE_REF=${8:-} "$HERE/decide-mode.sh" 2>&1) || { echo ERROR; return; }
	echo "$(echo "$out" | sed -n 's/^mode=//p') $(echo "$out" | sed -n 's/^publish=//p') $(echo "$out" | sed -n 's/^source_sha=//p') $(echo "$out" | sed -n 's/^channel=//p')"
}
chk() { local want=$1; shift; local got; got=$(mode "$@"); [ "$got" = "$want" ] && ok "$*  ->  $want" || bad "$*  ->  $got (expected $want)"; }
chk "stable true  stable" push refs/heads/main "" "" "" ""
chk "stable true  stable" workflow_dispatch refs/heads/main build stable "" ""
chk "stable true  stable" workflow_dispatch refs/heads/main "" "" "" ""
chk "testing true $SHA testing" workflow_dispatch refs/heads/main build testing $SHA ""
chk "promote true  stable" workflow_dispatch refs/heads/main promote stable "" "tsx-a tsx-b"
chk "promote true  stable" workflow_dispatch refs/heads/main promote testing $SHA "all"
chk ERROR workflow_dispatch refs/heads/main promote stable "" " , "
chk ERROR workflow_dispatch refs/heads/main build testing "" ""
chk ERROR workflow_dispatch refs/heads/main build testing main ""
chk ERROR workflow_dispatch refs/heads/main build testing 0123456 ""
chk ERROR workflow_dispatch refs/heads/main build testing ${SHA^^} ""
chk "none false  stable" push refs/heads/testing "" "" "" ""
chk "none false  stable" workflow_dispatch refs/heads/testing build testing $SHA ""
chk "none false  stable" workflow_dispatch refs/heads/testing promote stable "" "all"
chk "none false  stable" workflow_dispatch refs/heads/feature build stable "" ""
chk "none false  stable" pull_request refs/pull/1/merge "" "" "" ""
chk "none false  testing" pull_request refs/pull/1/merge "" "" "" "" "" testing
# D6: a newline in a value. The line-based grep of the old check accepted the sha line.
chk ERROR workflow_dispatch refs/heads/main build testing "$SHA"$'\n'"mode<<EOF"$'\n'"stable"$'\n'"EOF" ""
chk ERROR workflow_dispatch refs/heads/main build testing "$SHA"$'\n' ""
chk ERROR workflow_dispatch refs/heads/main build testing "$SHA"$'\r' ""
chk ERROR workflow_dispatch refs/heads/main build $'testing\nx' "" ""
chk ERROR workflow_dispatch refs/heads/main $'promote\nx' stable "" "all"
chk ERROR workflow_dispatch refs/heads/main sneaky stable "" ""
chk ERROR workflow_dispatch refs/heads/main build sneaky "" ""
OUT=$(GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main CHANNEL=testing SOURCE_SHA="$SHA"$'\nmode=stable' "$HERE/decide-mode.sh" 2>&1); echo "$OUT" | grep -q '^mode=stable' && bad "a second mode line was printed" || ok "no injected output line"
# R2-3: trust_live skips the manifest. Stable only.
tl() { local out; out=$(GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main ACTION=$1 CHANNEL=$2 SOURCE_SHA=$3 PACKAGES=${4:-} TRUST_LIVE=$5 "$HERE/decide-mode.sh" 2>&1) || { echo ERROR; return; }; echo "$out" | sed -n 's/^trust_live=//p'; }
[ "$(tl build stable "" "" true)" = true ] && ok "trust_live on a stable build: accepted, printed" || bad "trust_live stable"
[ "$(tl build testing $SHA "" true)" = ERROR ] && ok "trust_live with channel testing: refused" || bad "trust_live testing accepted"
[ "$(tl promote stable "" all true)" = ERROR ] && ok "trust_live with promote: refused" || bad "trust_live promote accepted"
[ "$(tl build stable "" "" maybe)" = ERROR ] && ok "trust_live must be true or false" || bad "trust_live maybe accepted"
[ "$(tl build stable "" "" false)" = false ] && ok "trust_live false by default" || bad "trust_live false"
# D3: the seed replaces the site. Only a stable build may use it.
chk "stable true  stable" workflow_dispatch refs/heads/main build stable "" "" https://example.invalid/seed.tar.gz
chk ERROR workflow_dispatch refs/heads/main build testing $SHA "" https://example.invalid/seed.tar.gz
chk ERROR workflow_dispatch refs/heads/main promote stable "" "all" https://example.invalid/seed.tar.gz
chk "none false  stable" schedule refs/heads/main "" "" "" ""

echo "== files of the repository =="
if git -C "$HERE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	TR=$(git -C "$HERE" ls-files | grep -E '\.pyc$|__pycache__' || true)
	[ -z "$TR" ] && ok "no .pyc or __pycache__ file is tracked" || bad "tracked byte code: $TR"
	grep -qx '__pycache__/' "$HERE/../.gitignore" && grep -qx '\*.pyc' "$HERE/../.gitignore" && ok ".gitignore has __pycache__/ and *.pyc" || bad ".gitignore lacks the byte code lines"
	NX=$(for f in source-policy.sh arch-image.sh; do [ -x "$HERE/$f" ] && echo "$f"; done)
	[ -z "$NX" ] && ok "the scripts that are only sourced are not executable" || bad "executable but only sourced: $NX"
	git -C "$HERE" ls-files | grep -vE '\.(sh|py|md|yml|txt|json|apk|puf|patch|conf|initd|confd|post-install|post-upgrade|pre-install|pre-deinstall|post-deinstall|pub|tar\.zst)$' | grep -E '\.(pyc|so|o|bin|img)$' && bad "a generated binary file is tracked" || ok "no generated binary file is tracked"
fi
grep -q 'PYTHONDONTWRITEBYTECODE' "$HERE/../.github/workflows/build.yml" && ok "the workflow sets PYTHONDONTWRITEBYTECODE" || bad "the workflow can write byte code"

echo "== workflow: no pipe that head can break =="
# `cmd | sort | head` under pipefail: head exits early, sort gets SIGPIPE, the step fails at random.
if grep -nE '\|[^|]*\bhead\b' "$HERE/index.sh" "$HERE/assemble-site.sh" "$HERE/../.github/workflows/build.yml" | grep -vE 'echo|printf|grep -q|#' | grep -E 'sort|find|du |ls |git '; then
	bad "a producer is piped into head"
else ok "no find/sort/du/ls/git output is piped into head in index.sh, assemble-site.sh and the workflow"; fi

echo "== check-testing-sha.sh =="
command -v git >/dev/null || { echo "no git: skipped"; fin; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
G() { git -C "$W/r" -c user.name=t -c user.email=t@example.invalid "$@"; }
git init -q "$W/r"; G commit -q --allow-empty -m base
M=$(G rev-parse HEAD)
G checkout -q -b testing; G commit -q --allow-empty -m t1; T1=$(G rev-parse HEAD); G commit -q --allow-empty -m t2; T2=$(G rev-parse HEAD)
G checkout -q -b other "$M"; G commit -q --allow-empty -m o1; O1=$(G rev-parse HEAD)
CT() { (cd "$W/r" && TESTING_REF=refs/heads/testing "$HERE/check-testing-sha.sh" "$@" 2>&1); }
CT "$T2" >/dev/null && ok "the tip of testing is accepted" || bad "tip refused"
CT "$T1" >/dev/null && ok "an older commit of testing is accepted" || bad "older commit refused"
CT "$M" >/dev/null && ok "a commit that testing contains (the base) is accepted" || bad "base refused"
OUT=$(CT "$O1") && bad "a commit of another branch accepted" || case "$OUT" in *"not on the branch testing"*) ok "a commit that is not on testing is refused";; *) bad "message: $OUT";; esac
CT "$T2"$'\n'"$T2" >/dev/null && bad "a sha with a second line accepted" || ok "a value with a newline is refused"
CT "${T2:0:12}" >/dev/null && bad "a short sha accepted" || ok "a short sha is refused"
CT "$(printf '0%.0s' $(seq 40))" >/dev/null && bad "an unknown commit accepted" || ok "an unknown commit is refused"
(cd "$W/r" && TESTING_REF=refs/heads/nope "$HERE/check-testing-sha.sh" "$T2" >/dev/null 2>&1) && bad "a missing branch accepted" || ok "a missing testing branch is refused"

echo "== take-recipes.sh: recipes from the commit, scripts and keys from main =="
R2=$W/r2; git init -q "$R2"
G2() { git -C "$R2" -c user.name=t -c user.email=t@example.invalid "$@"; }
mkdir -p "$R2/common/tsx-keys" "$R2/common/tsx-base" "$R2/xx60/tsx-b" "$R2/scripts"
echo "main key" > "$R2/common/tsx-keys/tsx-mainline-aaaa.rsa.pub"; echo "main base" > "$R2/common/tsx-base/APKBUILD"
echo "b main" > "$R2/xx60/tsx-b/APKBUILD"; echo "main script" > "$R2/scripts/x.sh"
G2 add -A; G2 commit -q -m main; G2 branch -M main
G2 checkout -q -b testing
echo "evil key" > "$R2/common/tsx-keys/tsx-mainline-bbbb.rsa.pub"; rm "$R2/common/tsx-keys/tsx-mainline-aaaa.rsa.pub"
echo "testing base" > "$R2/common/tsx-base/APKBUILD"; rm -r "$R2/xx60/tsx-b"; mkdir -p "$R2/xx60/tsx-new"; echo new > "$R2/xx60/tsx-new/APKBUILD"
echo "testing script" > "$R2/scripts/x.sh"
G2 add -A; G2 commit -q -m testing; TS=$(G2 rev-parse HEAD)
G2 checkout -q main; G2 update-ref refs/remotes/origin/testing "$TS"
(cd "$R2" && "$HERE/take-recipes.sh" "$TS" >/dev/null 2>&1) && RC=0 || RC=1
[ $RC = 0 ] && [ "$(cat $R2/common/tsx-base/APKBUILD)" = "testing base" ] && [ -f $R2/xx60/tsx-new/APKBUILD ] && [ ! -e $R2/xx60/tsx-b ] \
	&& ok "the recipe folders are the folders of the commit (also a recipe added and one removed)" || bad "recipes: rc $RC"
[ "$(cat $R2/scripts/x.sh)" = "main script" ] && ok "the scripts stay the scripts of main" || bad "scripts changed"
[ -f $R2/common/tsx-keys/tsx-mainline-aaaa.rsa.pub ] && [ ! -e $R2/common/tsx-keys/tsx-mainline-bbbb.rsa.pub ] && ok "the public key folder stays the one of main (D9)" || bad "keys: $(ls $R2/common/tsx-keys)"
G2 checkout -q -b other main; echo o > "$R2/o"; G2 add o; G2 commit -q -m o; OS=$(G2 rev-parse HEAD); G2 checkout -q main
(cd "$R2" && "$HERE/take-recipes.sh" "$OS" >/dev/null 2>&1) && bad "a commit that is not on testing accepted" || ok "a commit that is not on testing is refused"

echo "== trigger-testing.sh: never replace a waiting run =="
FB=$W/fakebin; mkdir -p "$FB"
cat > "$FB/gh" <<'GH'
#!/bin/bash
# fake gh: "run list --status S" prints the number from $FAKE_WAITING_<S> in the form the jq filter wants
case "$*" in
*"run list"*)
	for a in "$@"; do last=$a; done
	st=; prev=; for a in "$@"; do [ "$prev" = --status ] && st=$a; prev=$a; done
	n=$(cat "$FAKE_DIR/$st" 2>/dev/null || echo 0)
	# the script's --jq asks for a count of matching runs: print the number
	echo "$n";;
*"workflow run"*) echo "$*" >> "$FAKE_DIR/started";;
esac
GH
chmod +x "$FB/gh"; FD=$W/fake; mkdir -p "$FD"
TR() { (PATH="$FB:$PATH" FAKE_DIR=$FD GITHUB_REPOSITORY=o/r TRIGGER_RETRIES=1 TRIGGER_WAIT=0 "$HERE/trigger-testing.sh" "$1" 2>&1); }
rm -f $FD/*; OUT=$(TR "$SHA") && grep -q "channel=testing -f source_sha=$SHA" $FD/started && ok "no run waits: the testing build is started on main" || bad "start: $OUT"
rm -f $FD/started; echo 1 > $FD/pending; OUT=$(TR "$SHA") && bad "started while a run waits" || { [ ! -e $FD/started ] && ok "a run waits: no testing build is started (it would replace it)"; }
rm -f $FD/pending $FD/started; echo 2 > $FD/queued; OUT=$(TR "$SHA") && bad "started while queued" || ok "a queued run: refused too"
rm -f $FD/queued; TR "${SHA:0:10}" >/dev/null && bad "short sha accepted" || ok "a short sha is refused"
fin
