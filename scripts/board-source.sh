#!/bin/sh
# Make the local source tarball of a board tag of a family repo for the board
# recipe of that family. Use it until the family repo is on GitHub.
#
#   scripts/board-source.sh REPO TAG
#   REPO  path of a tsx-xx60-linux checkout
#   TAG   a signed tag of that repo, for example board-v0.1.0
#
# The script writes tsx-xx60-linux-<version>.tar.gz into xx60/tsx-xx60-board/
# (git ignores it). The archive holds only rootfs/overlay, rootfs/src and
# LICENSE of the tag. Its top directory is tsx-xx60-linux-<version>/, as in a
# GitHub tag archive. gzip -n keeps the file the same on each run, so its
# sha512 stays the same.
# tar.umask=0022 gives the modes of a GitHub tag archive (755 and 644). The git
# default (002) would make every file in a package writable for its group. It prints the sha512 line for sha512sums= of the
# APKBUILD.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${1:?usage: board-source.sh REPO TAG}
TAG=${2:?usage: board-source.sh REPO TAG}
VER=${TAG#board-v}
[ "$VER" != "$TAG" ] || { echo "board-source.sh: the tag must look like board-vX.Y.Z" >&2; exit 1; }
NAME=tsx-xx60-linux-$VER.tar.gz
git -C "$REPO" verify-tag "$TAG" >/dev/null 2>&1 || { echo "board-source.sh: $TAG is not a signed tag of $REPO" >&2; exit 1; }
T=$(mktemp)
chmod 644 "$T"
trap 'rm -f "$T"' EXIT
git -C "$REPO" -c tar.umask=0022 archive --format=tar --prefix="tsx-xx60-linux-$VER/" "$TAG" rootfs/overlay rootfs/src LICENSE | gzip -n -9 > "$T"
install -m 644 "$T" "$HERE/../xx60/tsx-xx60-board/$NAME"
echo "$(sha512sum "$T" | cut -d' ' -f1)  $NAME"
