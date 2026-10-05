#!/bin/sh
# Make the local source tarball of a release tag of tsx-ledbar-fw for the
# recipe xx60/tsx-ledbar-fw. Use it until that repo is on GitHub.
#
#   scripts/ledbar-fw-source.sh REPO TAG
#   REPO  path of a tsx-ledbar-fw checkout
#   TAG   a signed tag of that repo, for example v0.1.1
#
# The script writes tsx-ledbar-fw-<version>.tar.gz into xx60/tsx-ledbar-fw/
# (git ignores it). The archive holds fw, tools, panel, tests and LICENSE of
# the tag. Its top directory is tsx-ledbar-fw-<version>/, as in a GitHub tag
# archive. gzip -n and tar.umask=0022 keep the file and its sha512 the same
# on each run. The script prints the sha512 line for sha512sums= of the
# APKBUILD.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${1:?usage: ledbar-fw-source.sh REPO TAG}
TAG=${2:?usage: ledbar-fw-source.sh REPO TAG}
VER=${TAG#v}
[ "$VER" != "$TAG" ] || { echo "ledbar-fw-source.sh: the tag must look like vX.Y.Z" >&2; exit 1; }
NAME=tsx-ledbar-fw-$VER.tar.gz
git -C "$REPO" verify-tag "$TAG" >/dev/null 2>&1 || { echo "ledbar-fw-source.sh: $TAG is not a signed tag of $REPO" >&2; exit 1; }
T=$(mktemp)
chmod 644 "$T"
trap 'rm -f "$T"' EXIT
git -C "$REPO" -c tar.umask=0022 archive --format=tar --prefix="tsx-ledbar-fw-$VER/" "$TAG" fw tools panel tests LICENSE | gzip -n -9 > "$T"
install -m 644 "$T" "$HERE/../xx60/tsx-ledbar-fw/$NAME"
echo "$(sha512sum "$T" | cut -d' ' -f1)  $NAME"
