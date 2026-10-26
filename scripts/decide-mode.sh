#!/bin/bash
# The mode of a run of .github/workflows/build.yml. It reads the event from
# the environment and prints "key=value" lines (for $GITHUB_OUTPUT) for
# mode, publish, channel and source_sha. Every value is checked first, and a
# value never holds a newline, so the lines cannot add an output. The workflow
# uses these lines and parses nothing else. It exits 1 with an ::error::
# line for a combination that is not allowed.
#
#   mode   stable   a push to main, or a manual run on main (channel stable)
#          testing  a manual run on main with channel=testing and source_sha.
#                   The trigger job starts it after a push to the branch
#                   testing. No deploy runs on the branch testing itself.
#          promote  a manual run on main with action=promote
#          none     everything else (a pull request, a manual run on another
#                   branch): it builds with a throwaway key and publishes nothing
#   channel testing for the mode testing and for a pull request into testing
#          (commit sources are allowed), else stable.
#
# Environment: GITHUB_EVENT_NAME, GITHUB_REF, GITHUB_BASE_REF, ACTION
# (build|promote), CHANNEL (stable|testing), SOURCE_SHA, SEED_URL, PACKAGES,
# TRUST_LIVE (true|false: a stable build trusts the live site and skips the
# manifest, as the first deploy does).
set -eu
die() { echo "::error::$*"; exit 1; }
# A value with a newline or a carriage return is refused as a whole.
nl=$'\n' cr=$'\r'
for v in "${TRUST_LIVE:-}" "${GITHUB_EVENT_NAME:-}" "${GITHUB_REF:-}" "${GITHUB_BASE_REF:-}" "${ACTION:-}" "${CHANNEL:-}" "${SOURCE_SHA:-}" "${SEED_URL:-}"; do
	case $v in *"$nl"*|*"$cr"*) die "an input has a newline";; esac
done
case ${ACTION:-build} in build|promote) ;; *) die "action must be build or promote";; esac
case ${CHANNEL:-stable} in stable|testing) ;; *) die "channel must be stable or testing";; esac
mode=none sha=
case "${GITHUB_EVENT_NAME:-}:${GITHUB_REF:-}" in
push:refs/heads/main) mode=stable;;
workflow_dispatch:refs/heads/main)
	if [ "${ACTION:-build}" = promote ]; then
		mode=promote
		[ -n "$(printf '%s' "${PACKAGES:-}" | tr -d '[:space:],')" ] \
			|| die "promote needs the input packages (names, or all)"
	elif [ "${CHANNEL:-stable}" = testing ]; then
		mode=testing sha=${SOURCE_SHA:-}
		# Exactly 40 characters from 0-9a-f. No pattern with ^ and $ alone:
		# a line-based match would accept a second line.
		[ "${#sha}" = 40 ] && case $sha in *[!0-9a-f]*) false;; *) true;; esac \
			|| die "channel testing needs source_sha: the full 40-character sha of a commit on the branch testing"
	else
		mode=stable
	fi;;
esac
case ${TRUST_LIVE:-false} in true|false) ;; *) die "trust_live must be true or false";; esac
# trust_live skips the manifest check. Only a stable build may use it.
if [ "${TRUST_LIVE:-false}" = true ] && [ "$mode" != stable ]; then
	die "trust_live is for a stable build only (mode $mode)"
fi
# The seed replaces the live site. Only a stable build may use it.
if [ -n "${SEED_URL:-}" ] && [ "$mode" != stable ]; then
	die "seed_url is for a stable build only (mode $mode)"
fi
channel=stable
{ [ "$mode" = testing ] || [ "${GITHUB_BASE_REF:-}" = testing ]; } && channel=testing
echo "mode=$mode"
echo "channel=$channel"
echo "source_sha=$sha"
echo "trust_live=${TRUST_LIVE:-false}"
if [ "$mode" = none ]; then echo "publish=false"; else echo "publish=true"; fi
