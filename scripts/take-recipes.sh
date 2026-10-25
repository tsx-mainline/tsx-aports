#!/bin/bash
# take-recipes.sh SHA: for a testing build. Check that SHA is on the branch
# testing, then replace the recipe folders of the work tree with the folders
# of SHA. The scripts stay the scripts of main, and so do the public keys
# (common/tsx-keys): the key that signs and the key that the checks trust come
# from main, whatever the commit has.
set -eu
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SHA=${1:?usage: take-recipes.sh SHA}
"$HERE/check-testing-sha.sh" "$SHA"
KEEPKEYS=$(mktemp -d)
trap 'rm -rf "$KEEPKEYS"' EXIT
[ ! -d common/tsx-keys ] || cp -a common/tsx-keys "$KEEPKEYS/tsx-keys"
for d in common xx60 xx50 xx70 uc-pxx keep; do
	rm -rf "$d"
	git checkout "$SHA" -- "$d" 2>/dev/null || true
done
if [ -d "$KEEPKEYS/tsx-keys" ]; then
	rm -rf common/tsx-keys
	mkdir -p common
	cp -a "$KEEPKEYS/tsx-keys" common/tsx-keys
fi
git status --short | sed -n 1,20p
