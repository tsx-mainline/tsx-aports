#!/bin/bash
# Assemble the tree of the whole site for GitHub Pages: the stable tree
# (v3.24/...) and the testing tree (testing/v3.24/...). Every deploy uploads
# both, because Pages serves one artifact for the site. The step starts from
# trees that scripts/carry-forward.py fetched from the live site. It changes
# the tree of the mode, and it indexes and signs what changed.
#
#   scripts/assemble-site.sh stable|testing|promote
#
#   stable    (push to main, manual run on main) The built stable tree is in
#             packages/v3.24. The script prunes, indexes and signs it into
#             OUT/v3.24. Then it builds the testing tree again: all of
#             stable, and the testing-only packages that are newer than
#             stable (scripts/channels.py assemble), in OUT/testing/v3.24.
#   testing   (push to testing) The live stable tree is in WORK/stable. The
#             script copies it to OUT/v3.24 without a change (the same
#             bytes, also the indexes) and stops if one byte differs from the
#             manifest of the last deploy (MANIFEST_FILE; without it, from the
#             copy that was fetched, which proves less). The
#             testing tree (the live testing tree plus the new builds) is in
#             packages/v3.24. The script builds the tree from stable and from
#             the testing packages that are newer, indexes and signs it into
#             OUT/testing/v3.24.
#   promote   (manual run on main) The live stable tree is in WORK/stable and
#             the live testing tree is in WORK/testing-live. The script copies
#             the apks of the list PROMOTE from testing to stable (the same
#             bytes), writes them to promoted.txt, prunes, indexes and signs
#             stable, and then builds the testing tree again, as in "stable".
#
# Environment (all but the key are optional):
#   TSX_APORTS_KEY   the private signing key (required)
#   PACKAGES_DIR     the tree that scripts/build.sh made (default packages/v3.24)
#   WORK_DIR         the fetched live trees (default work): WORK_DIR/stable,
#                    WORK_DIR/testing-live and WORK_DIR/promoted.txt
#   OUT_DIR          the result (default repo)
#   PROMOTE          the list of the mode "promote" (see scripts/channels.py)
#   STABLE_KEEP      versions of each package in stable (default 2)
#   TESTING_KEEP     versions of each package in testing (default 1). The
#                    site has two full trees and Pages has a soft limit of
#                    about 1 GB, so testing keeps only the newest version.
#   SITE_DOMAIN      the name for the CNAME file
#   RUN_ID           written to promoted.txt (default GITHUB_RUN_ID)
#   MANIFEST_FILE    the manifest of the last deploy (scripts/manifest.py). In
#                    the mode testing the stable tree must equal it.
#   KEYS_DIR         the trusted public keys for the last check (default
#                    common/tsx-keys)
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
MODE=${1:?usage: assemble-site.sh stable|testing|promote}
PKGS=${PACKAGES_DIR:-$REPO/packages/v3.24}
WORK=${WORK_DIR:-$REPO/work}
OUT=${OUT_DIR:-$REPO/repo}
STABLE_KEEP=${STABLE_KEEP:-2}
TESTING_KEEP=${TESTING_KEEP:-1}
: "${TSX_APORTS_KEY:?set TSX_APORTS_KEY to sign the indexes}"
CH="$HERE/channels.py"
KEYS_ARG=()
[ -z "${KEYS_DIR:-}" ] || KEYS_ARG=(--keys "$KEYS_DIR")

log() { echo "assemble-site: $*"; }

# testing_from_stable STABLE_DIR TESTING_DIR: the testing tree is the stable
# tree and the newer testing packages. Index and sign it into OUT/testing.
testing_from_stable() {
	rm -rf "$WORK/testing-new"
	"$CH" assemble --stable "$1" --testing "$2" --out "$WORK/testing-new"
	"$HERE/index.sh" --src "$WORK/testing-new" --keep "$TESTING_KEEP" --prefix testing --out "$OUT"
}

rm -rf "$OUT"; mkdir -p "$OUT" "$WORK"
case $MODE in
stable)
	log "stable: index and sign the built tree"
	"$HERE/index.sh" --src "$PKGS" --keep "$STABLE_KEEP" --out "$OUT"
	testing_from_stable "$OUT/v3.24" "$WORK/testing-live"
	;;
promote)
	: "${PROMOTE:?set PROMOTE to the list of packages (or all)}"
	[ -d "$WORK/stable" ] || { echo "assemble-site: no $WORK/stable" >&2; exit 1; }
	log "promote: $PROMOTE"
	"$CH" promote --stable "$WORK/stable" --testing "$WORK/testing-live" \
		--packages "$PROMOTE" --log "$WORK/promoted.txt" --run "${RUN_ID:-${GITHUB_RUN_ID:-}}"
	"$HERE/index.sh" --src "$WORK/stable" --keep "$STABLE_KEEP" --out "$OUT"
	testing_from_stable "$OUT/v3.24" "$WORK/testing-live"
	;;
testing)
	[ -d "$WORK/stable" ] || { echo "assemble-site: no $WORK/stable" >&2; exit 1; }
	log "testing: copy stable without a change"
	mkdir -p "$OUT/v3.24"
	rsync -a "$WORK/stable/" "$OUT/v3.24/"
	testing_from_stable "$WORK/stable" "$PKGS"
	# The stable tree must be the tree of the last deploy, byte for byte. The
	# manifest of that deploy is the truth, not the fetched copy: a bad fetch
	# would make a copy that equals itself.
	if [ -n "${MANIFEST_FILE:-}" ]; then
		"$HERE/manifest.py" check-tree --manifest "$MANIFEST_FILE" --prefix v3.24 --dir "$OUT/v3.24"
	else
		echo "assemble-site: WARNING: no manifest; stable is only compared with the fetched copy" >&2
		"$CH" same "$WORK/stable" "$OUT/v3.24"
	fi
	;;
*) echo "assemble-site: unknown mode $MODE" >&2; exit 1;;
esac

[ -z "${SITE_DOMAIN:-}" ] || echo "$SITE_DOMAIN" > "$OUT/CNAME"
if [ -f "$WORK/promoted.txt" ]; then cp "$WORK/promoted.txt" "$OUT/promoted.txt"; else : > "$OUT/promoted.txt"; fi

# Last check: every index signature and apk checksum in both trees must verify
# against the committed key.
rm -rf "$WORK/verify-stable" "$WORK/verify-testing"
"$HERE/carry-forward.py" --from "$OUT" --dest "$WORK/verify-stable" "${KEYS_ARG[@]}"
"$HERE/carry-forward.py" --from "$OUT/testing" --dest "$WORK/verify-testing" "${KEYS_ARG[@]}"
# The manifest of this deploy: the next run starts from it.
"$HERE/manifest.py" make --tree "$OUT" --run "${RUN_ID:-${GITHUB_RUN_ID:--}}" --out "$WORK/manifest.txt"
cp "$WORK/manifest.txt" "$OUT/manifest.txt"
log "done: $(cd "$OUT" && find . -name '*.apk' | wc -l) apks, $(du -sh "$OUT" | cut -f1)"
