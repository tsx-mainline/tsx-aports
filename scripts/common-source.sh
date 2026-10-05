#!/bin/sh
# Make the local source tarball of a tsx-linux-common tag for the recipes in
# common/. Use it until tsx-linux-common is on GitHub.
#
#   scripts/common-source.sh REPO TAG
#   REPO  path of a tsx-linux-common checkout
#   TAG   a tag of that repo, for example v0.1.0
#
# The script writes tsx-linux-common-<version>.tar.gz into the directory of
# each package that builds from it. It does not write the file anywhere else.
# The file is in .gitignore. It is the same as `git archive`, with the same
# top directory as a GitHub tag archive (tsx-linux-common-<version>/). gzip -n
# keeps the file the same on each run, so its sha512 stays the same.
# tar.umask=0022 gives the modes of a GitHub tag archive (755 and 644). The git
# default (002) would make every file in a package writable for its group.
# It prints the sha512 line for the sha512sums= of the APKBUILDs.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${1:?usage: common-source.sh REPO TAG}
TAG=${2:?usage: common-source.sh REPO TAG}
VER=${TAG#v}
NAME=tsx-linux-common-$VER.tar.gz
git -C "$REPO" verify-tag "$TAG" >/dev/null 2>&1 || { echo "common-source.sh: $TAG is not a signed tag of $REPO" >&2; exit 1; }
T=$(mktemp)
chmod 644 "$T"
trap 'rm -f "$T"' EXIT
git -C "$REPO" -c tar.umask=0022 archive --format=tar --prefix="tsx-linux-common-$VER/" "$TAG" | gzip -n -9 > "$T"
for d in "$HERE"/../common/tsx-*/; do
	grep -q "tsx-linux-common-" "$d/APKBUILD" 2>/dev/null || continue
	install -m 644 "$T" "$d/$NAME"
done
echo "$(sha512sum "$T" | cut -d' ' -f1)  $NAME"
