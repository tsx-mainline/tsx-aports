#!/bin/bash
# The job trigger-testing of .github/workflows/build.yml: start the testing
# build on main for the sha of a push to the branch testing.
#
# GitHub keeps one waiting run for a concurrency group, and a newer waiting run
# cancels the older one. A testing run that waits behind a running deploy would
# cancel a waiting deploy of main. So this script does not start the run while
# another run of the publish group waits. It fails then, and says so. The next
# push to testing (or a manual run) starts the build when the queue is empty.
# A running deploy is no problem: the new run waits behind it, alone.
#
#   scripts/trigger-testing.sh SHA
#
# Environment: GITHUB_REPOSITORY, GH_TOKEN. TRIGGER_RETRIES and TRIGGER_WAIT
# (seconds) say how long to wait for a waiting run to start (default 3 x 60).
set -eu
SHA=${1:?usage: trigger-testing.sh SHA}
REPO=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY}
{ [ "${#SHA}" = 40 ] && case $SHA in *[!0-9a-f]*) false;; *) true;; esac; } || { echo "::error::not a full sha"; exit 1; }
# waiting: the number of runs of build.yml that wait (status pending, queued or
# waiting) in the publish group: pushes to main and manual runs. Pull-request,
# scheduled and testing-push runs have other groups.
waiting() {
	local s n=0
	for s in pending queued waiting; do
		n=$((n + $(gh run list --repo "$REPO" --workflow build.yml --status "$s" --limit 50 \
			--json event,headBranch --jq '[.[] | select((.event == "push" and .headBranch == "main") or .event == "workflow_dispatch")] | length')))
	done
	echo "$n"
}
tries=${TRIGGER_RETRIES:-3}
while :; do
	n=$(waiting)
	[ "$n" = 0 ] && break
	tries=$((tries - 1))
	if [ "$tries" -lt 0 ]; then
		echo "::error::$n run(s) of build.yml wait for a deploy. A new run would replace one of them. Push to testing again (or start the build by hand) when the queue is empty."
		exit 1
	fi
	echo "$n run(s) wait; checking again in ${TRIGGER_WAIT:-60} s"
	sleep "${TRIGGER_WAIT:-60}"
done
gh workflow run build.yml --repo "$REPO" --ref main -f channel=testing -f source_sha="$SHA"
echo "started the testing build for $SHA"
