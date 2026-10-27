#!/bin/bash
# The manifest of the last deploy, from the artifact live-manifest of the
# newest run whose deploy succeeded (the deploy job uploads it after
# actions/deploy-pages). The artifact store is the truth about the live site.
# The CDN of Pages is not, because it can serve an older tree for 10 minutes.
#
# Only an artifact of a run of THIS workflow on main in THIS repository counts:
# the run is build.yml, its head branch is main, its head repository is this
# repository (no fork), and its event is push or workflow_dispatch. The script
# reads up to 5 pages of 30 artifacts, then checks them newest first by
# created_at. The API lists the artifacts by id, and the id order is not the
# time order: an artifact of an earlier deploy can have the higher id.
#
#   scripts/live-manifest.sh fetch FILE   write the manifest to FILE and print
#                                         "artifact_id=N". Exit 3 if there is
#                                         none (no deploy yet, or it expired).
#                                         Any other failure (the API too)
#                                         exits 1 at once.
#   scripts/live-manifest.sh same ID      exit 0 if the newest live-manifest is
#                                         ID ("none" for no manifest). Exit 1
#                                         if another deploy finished since, or
#                                         on an API error.
#
# Environment: GITHUB_REPOSITORY, and GH_TOKEN for gh (needs actions: read).
set -eu
REPO=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY}
WORKFLOW_PATH=${WORKFLOW_PATH:-.github/workflows/build.yml}

# api PATH: the JSON of a GitHub API call. Any failure ends the script with 1
# (never with 3: only "no artifact" may mean none).
api() { gh api "$1" || { echo "live-manifest: the API call failed: $1" >&2; exit 1; }; }

# newest: print the id of the newest artifact that passes the checks, or "none".
newest() {
	local page json cand all="" created id run runjson count
	for page in 1 2 3 4 5; do
		json=$(api "repos/$REPO/actions/artifacts?name=live-manifest&per_page=30&page=$page") || exit 1
		# candidates: not expired, from a run on main of this repository.
		# One line "<created_at> <artifact id> <run id>". A candidate without
		# created_at is an error: it cannot be put in order, and taking it as
		# the oldest could hide a newer deploy from "same".
		cand=$(printf '%s' "$json" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
for a in d.get("artifacts", []):
    r = a.get("workflow_run") or {}
    if a.get("expired"):
        continue
    if r.get("head_branch") != "main" or r.get("head_repository_id") != r.get("repository_id") or not r.get("id"):
        continue
    if not a.get("created_at"):
        sys.exit("live-manifest: the artifact %s has no created_at" % a["id"])
    print(a["created_at"], a["id"], r["id"])
') || { echo "live-manifest: cannot read the artifact list" >&2; exit 1; }
		[ -z "$cand" ] || all="$all$cand"$'\n'
		# fewer than 30 entries: no more pages
		count=$(printf '%s' "$json" | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin).get("artifacts", [])))') || exit 1
		[ "$count" -ge 30 ] || break
	done
	# newest first: created_at (ISO 8601 UTC sorts as text), then the higher id
	while read -r created id run; do
		[ -n "$id" ] || continue
		# The run is read into a variable first: in a pipeline the failure of
		# gh would be lost, and the artifact would count as "not ours".
		runjson=$(api "repos/$REPO/actions/runs/$run") || exit 1
		if printf '%s' "$runjson" | python3 -I -c '
import json, sys
path = sys.argv[1]
r = json.load(sys.stdin)
ok = (r.get("path") == path and r.get("event") in ("push", "workflow_dispatch")
      and r.get("head_branch") == "main"
      and (r.get("head_repository") or {}).get("id") == (r.get("repository") or {}).get("id")
      and r.get("conclusion") in (None, "success"))
sys.exit(0 if ok else 1)' "$WORKFLOW_PATH"; then
			echo "$id"; return 0
		fi
	done <<<"$(printf '%s' "$all" | sort -k1,1r -k2,2nr)"
	echo none
}

case ${1:-} in
fetch)
	OUT=${2:?usage: live-manifest.sh fetch FILE}
	id=$(newest) || exit 1
	if [ "$id" = none ]; then echo "artifact_id=none"; exit 3; fi
	T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
	gh api "repos/$REPO/actions/artifacts/$id/zip" > "$T/m.zip" || { echo "live-manifest: cannot download the artifact $id" >&2; exit 1; }
	python3 -I -c 'import sys,zipfile; sys.stdout.buffer.write(zipfile.ZipFile(sys.argv[1]).read("manifest.txt"))' "$T/m.zip" > "$OUT" \
		|| { echo "live-manifest: the artifact $id has no manifest.txt" >&2; exit 1; }
	[ -s "$OUT" ] || { echo "live-manifest: the artifact $id has no manifest.txt" >&2; exit 1; }
	echo "artifact_id=$id";;
same)
	want=${2:?usage: live-manifest.sh same ID}
	now=$(newest) || { echo "::error::cannot read the live-manifest artifacts"; exit 1; }
	if [ "$now" != "$want" ]; then
		echo "::error::another deploy finished while this run built (live-manifest $want, now $now). Start this run again."
		exit 1
	fi
	echo "live-manifest: no other deploy since the start of this run";;
*) echo "usage: live-manifest.sh fetch FILE | same ID" >&2; exit 2;;
esac
