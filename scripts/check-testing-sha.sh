#!/bin/bash
# check-testing-sha.sh SHA: stop unless SHA is the full sha of a commit that is
# on the branch testing (refs/remotes/origin/testing, or the ref in TESTING_REF).
# A testing build deploys from main and takes its recipes from SHA, so SHA must
# come from the branch whose pushes lead to a signed deploy.
set -eu
SHA=${1:?usage: check-testing-sha.sh SHA}
REF=${TESTING_REF:-refs/remotes/origin/testing}
{ [ "${#SHA}" = 40 ] && case $SHA in *[!0-9a-f]*) false;; *) true;; esac; } \
	|| { echo "::error::the value is not a full 40-character sha"; exit 1; }
git cat-file -e "$SHA^{commit}" 2>/dev/null || { echo "::error::commit $SHA is not in this repository"; exit 1; }
git rev-parse -q --verify "$REF^{commit}" >/dev/null || { echo "::error::the branch testing does not exist ($REF)"; exit 1; }
git merge-base --is-ancestor "$SHA" "$REF" || { echo "::error::$SHA is not on the branch testing"; exit 1; }
echo "check-testing-sha: $SHA is on the branch testing"
