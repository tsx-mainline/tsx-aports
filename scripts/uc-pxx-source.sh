#!/bin/sh
# Make the local source archive of uc-pxx-linux for the uc-pxx recipes that
# use it (uc-pxx-boot-tools, uc-pxx-board, uc-pxx-leds: every recipe with the
# source uc-pxx-linux-$pkgver.tar.gz). Use it while uc-pxx-linux has no public
# repository or no tag for the version of the recipes (README.md "uc-pxx
# packages").
#
#   scripts/uc-pxx-source.sh [--no-update] REPO REF
#   REPO  path of a uc-pxx-linux checkout
#   REF   a tag (board-vX.Y.Z) or a commit of that repository
#
# The script writes uc-pxx-linux-<pkgver>.tar.gz into the dist/ folder of
# these recipes (git ignores dist/). They must have the same pkgver.
# The archive holds the whole tree of REF under the top directory
# uc-pxx-linux-board-v<pkgver>/, as the GitHub archive of the tag
# board-v<pkgver> does. A commit that is not that tag makes a SNAPSHOT: the
# script says so, and its archive must never go into a release. gzip -n
# keeps the file the same on each run, so its sha512 stays the same.
# tar.umask=0022 gives the modes 755 and 644.
# Without --no-update the script writes the sha512 of the archive into the
# sha512sums of these recipes. The sum of the GitHub archive is another
# one: run abuild checksum again after the tag is public.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
UPDATE=1
[ "${1:-}" = --no-update ] && { UPDATE=0; shift; }
REPO=${1:?usage: uc-pxx-source.sh [--no-update] REPO REF}
REF=${2:?usage: uc-pxx-source.sh [--no-update] REPO REF}
PKGS=$(cd "$TOP/uc-pxx" && grep -l '^source="uc-pxx-linux-$pkgver.tar.gz::' */APKBUILD | sed 's|/APKBUILD$||' | sort)
[ -n "$PKGS" ] || { echo "uc-pxx-source.sh: no recipe uses the uc-pxx-linux archive" >&2; exit 1; }
VER=
for p in $PKGS; do
	v=$(sed -n 's/^pkgver=//p' "$TOP/uc-pxx/$p/APKBUILD")
	[ -z "$VER" ] || [ "$v" = "$VER" ] || { echo "uc-pxx-source.sh: $p has pkgver $v, the others $VER" >&2; exit 1; }
	VER=$v
done
echo "uc-pxx-source.sh: recipes $(echo $PKGS), pkgver $VER"
COMMIT=$(git -C "$REPO" rev-parse --verify "$REF^{commit}") || { echo "uc-pxx-source.sh: $REF is not a commit of $REPO" >&2; exit 1; }
TAGC=$(git -C "$REPO" rev-parse --verify -q "refs/tags/board-v$VER^{commit}" || true)
if [ "$TAGC" = "$COMMIT" ]; then
	echo "uc-pxx-source.sh: $REF is the tag board-v$VER ($COMMIT)"
else
	echo "uc-pxx-source.sh: SNAPSHOT of $COMMIT under the name of the tag board-v$VER (that tag ${TAGC:+is $TAGC}${TAGC:-does not exist}). Never release this archive."
fi
NAME=uc-pxx-linux-$VER.tar.gz
T=$(mktemp)
trap 'rm -f "$T"' EXIT
git -C "$REPO" -c tar.umask=0022 archive --format=tar --prefix="uc-pxx-linux-board-v$VER/" "$COMMIT" | gzip -n -9 > "$T"
chmod 644 "$T"
SUM=$(sha512sum "$T" | cut -d' ' -f1)
for p in $PKGS; do
	mkdir -p "$TOP/uc-pxx/$p/dist"
	cp "$T" "$TOP/uc-pxx/$p/dist/$NAME"
	if [ "$UPDATE" = 1 ]; then
		sed -i "s/^[0-9a-f]\{128\}  $NAME\$/$SUM  $NAME/" "$TOP/uc-pxx/$p/APKBUILD"
		grep -q "^$SUM  $NAME\$" "$TOP/uc-pxx/$p/APKBUILD" || { echo "uc-pxx-source.sh: no sha512sums line for $NAME in $p" >&2; exit 1; }
	fi
done
echo "$SUM  $NAME"
echo "commit $COMMIT"
