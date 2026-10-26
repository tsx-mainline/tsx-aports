#!/bin/bash
# Assemble the published tree from the output of scripts/build.sh in
# packages/v3.24, and sign the APKINDEX again for each <category>/<arch>.
# scripts/build.sh writes a signed index as part of `abuild -r`, but only
# for the packages in the packages/ directory of that build. This script
# prunes old package versions, then rebuilds the index for everything that
# is published. GitHub Pages has a soft limit of about 1 GB, and
# tsx-xx60-chromium alone is over 100 MB per build (see README.md
# "Hosting and size"). The script also copies a ready tree to $OUT
# (default repo/).
#
#   scripts/index.sh [--keep N] [--out DIR] [--src DIR] [--prefix PATH]
#
# --keep N   keep the newest N versions of each package (sorted by
#            pkgver/pkgrel), delete the others, then re-index. The default
#            is 2: the latest version and one previous version.
#            The files that keep/keep.txt and keep/keep-alpine.txt list are
#            not pruned and do not count as versions. If the tree lacks one,
#            the script copies it from keep/v3.24/ (keep.txt) or from
#            keep/alpine/v3.24/ (keep-alpine.txt), sha256 checked. keep.txt
#            has the packages that the rescue initramfs of tsx-xx60-linux
#            pins. keep-alpine.txt has Alpine packages that Alpine removed
#            and that our packages depend on (see README.md "Kept packages").
# --out DIR  the directory for the published tree (default: repo/,
#            gitignored). CI publishes it (see .github/workflows/build.yml).
# --src DIR  the tree to index (default: packages/v3.24 of this repo). It has
#            <category>/<arch>/*.apk. The script prunes and indexes it in place.
# --prefix P put the result in DIR/P/v3.24 and not in DIR/v3.24. CI uses
#            "testing" for the testing channel. The script never touches
#            any other path of DIR.
#
# Environment: TSX_APORTS_KEY (the private key). The script always rebuilds
# and signs the index.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# The prune sorts with scripts/channels.py. Without it the prune would delete nothing, silently.
[ -x "$HERE/channels.py" ] || { echo "index.sh: $HERE/channels.py is missing or not executable" >&2; exit 1; }
. "$HERE/arch-image.sh"
KEEP=2
OUT="$REPO/repo"
SRC="$REPO/packages/v3.24"
PREFIX=
while [ $# -gt 0 ]; do case $1 in
	--keep) KEEP=$2; shift;;
	--out) OUT=$2; shift;;
	--src) SRC=$2; shift;;
	--prefix) PREFIX=${2#/}; PREFIX=${PREFIX%/}; shift;;
	-h|--help) sed -n '2,31p' "$0"; exit 0;;
	*) echo "unknown arg $1" >&2; exit 1;;
esac; shift; done

# apk_names DIR: one line "<pkgname><TAB><file>" for each .apk in DIR. The
# pkgname is the file name without -<pkgver>-r<pkgrel>.apk.
apk_names() {
	(cd "$1" && ls -- *.apk 2>/dev/null) | sed -E 's/^(.*)-([0-9][^-]*-r[0-9]+)\.apk$/\1\t\1-\2.apk/'
}

KEEPDIR=${TSX_APORTS_KEEP_DIR:-$REPO/keep}

# kept_list: one line "<category>/<arch>/<file> <sha256>" for each file that
# keep/keep.txt or keep/keep-alpine.txt lists.
kept_list() {
	local l
	for l in keep.txt keep-alpine.txt; do
		[ -f "$KEEPDIR/$l" ] || continue
		sed -e 's/#.*//' "$KEEPDIR/$l" | awk 'NF >= 2 { print $1, $2 }'
	done
}

# kept_source REL: the path of the copy of a kept file, in keep/v3.24/ or in
# keep/alpine/v3.24/. Print the first path, even if no file is there.
kept_source() {
	if [ -f "$KEEPDIR/v3.24/$1" ] || [ ! -f "$KEEPDIR/alpine/v3.24/$1" ]; then
		echo "$KEEPDIR/v3.24/$1"
	else
		echo "$KEEPDIR/alpine/v3.24/$1"
	fi
}

# restore_kept TREE: TREE is packages/v3.24. Copy each kept file that TREE
# lacks from keep/v3.24/. A kept file in TREE must have the sha256 of the
# list. Return 1 on a mismatch or a file that is nowhere.
restore_kept() {
	local tree=${1%/} rel sum t k
	while read -r rel sum; do
		t=$tree/$rel
		if [ -e "$t" ]; then
			[ "$(sha256sum < "$t" | cut -d' ' -f1)" = "$sum" ] \
				|| { echo "index.sh: $rel in the tree is not the kept file (sha256 $sum)" >&2; return 1; }
			continue
		fi
		k=$(kept_source "$rel")
		[ -f "$k" ] || { echo "index.sh: $rel is kept, but neither the tree nor $KEEPDIR/v3.24 or $KEEPDIR/alpine/v3.24 has it" >&2; return 1; }
		[ "$(sha256sum < "$k" | cut -d' ' -f1)" = "$sum" ] \
			|| { echo "index.sh: $k does not have the sha256 of keep.txt ($sum)" >&2; return 1; }
		mkdir -p "$(dirname "$t")"
		cp "$k" "$t"
		echo "index.sh: restored $rel from keep/v3.24"
	done < <(kept_list)
	return 0
}

prune_dir() {  # ARCH_DIR
	local d="${1%/}" pruned=0 pkgname files n old f catarch kept
	# The kept files of this <category>/<arch> stay, and they do not count.
	catarch=$(basename "$(dirname "$d")")/$(basename "$d")
	kept=$(kept_list | awk -v p="$catarch/" 'index($1, p) == 1 { print substr($1, length(p) + 1) }')
	# Group the files by the whole pkgname, and keep the KEEP newest files
	# of each group. Do not use a glob such as "<pkgname>-*.apk": it also
	# matches the subpackages (tsx-xx60-board-ha, tsx-ledbar-fw), and then
	# the prune deleted the newest main package. The order is the order of
	# apk (scripts/channels.py sort). A plain `sort -V` is wrong for
	# 1.0_pre1, 1.0_rc1 and 1.0a: it puts 1.0-r0 before 1.0_pre1.
	for pkgname in $(apk_names "$d" | cut -f1 | sort -u); do
		files=$(apk_names "$d" | awk -F'\t' -v p="$pkgname" -v k="$kept" '
			BEGIN { n = split(k, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") K[a[i]] = 1 }
			$1 == p && !($2 in K) { print $2 }' | "$HERE/channels.py" sort)
		[ -n "$files" ] || continue
		n=$(printf '%s\n' "$files" | wc -l)
		if [ "$n" -gt "$KEEP" ]; then
			old=$(printf '%s\n' "$files" | sed -n "1,$((n - KEEP))p")
			for f in $old; do
				echo "index.sh: pruning $d/$f"
				rm -f "$d/$f"
				pruned=1
			done
		fi
	done
	return $pruned
}

# The host test loads the functions only.
if [ "${TSX_APORTS_INDEX_SH_SOURCE_ONLY:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

[ -d "$SRC" ] || { echo "index.sh: no $SRC -- run scripts/build.sh first" >&2; exit 1; }

SRC=$(cd "$SRC" && pwd)
restore_kept "$SRC"

READY=   # the architectures whose image is pulled and checked in this run
for cat_dir in "$SRC"/*/; do
	cat=$(basename "$cat_dir")
	for arch_dir in "$cat_dir"*/; do
		arch=$(basename "$arch_dir")
		prune_dir "$arch_dir" || true
		# Always re-index and re-sign. The index that scripts/build.sh leaves
		# lists only the packages in the packages/ directory of that build.
		# Without this step, a panel would not see the packages of a new
		# remote BUILD_DIR, or a package built after the last full index.
		echo "index.sh: indexing + signing $cat/$arch"
		: "${TSX_APORTS_KEY:?set TSX_APORTS_KEY to sign the index}"
		# Keep the real basename of the key. abuild-sign uses it for the
		# name of the signature entry (.SIGN.RSA.<basename>.pub), and a panel
		# finds the key in /etc/apk/keys by this exact name. The container
		# trusts the public key, so `apk index` also verifies the signature of
		# each package. --rewrite-arch does the same as abuild -r. A noarch
		# package (tsx-keys) goes in the <arch> directory, and apk fetches
		# from <repo>/<arch recorded in the index>/.
		KEYNAME=$(basename "$TSX_APORTS_KEY")
		case $arch in aarch64) IARCH=aarch64;; *) IARCH=armv7;; esac
		case " $READY " in
		*" $IARCH "*) ;;
		*) ensure_image "$IARCH"; check_image_arch "$IARCH"; READY="$READY $IARCH";;
		esac
		docker run --rm --platform "$(arch_platform "$IARCH")" \
			-v "$arch_dir:/repo" -v "$TSX_APORTS_KEY:/keys/$KEYNAME:ro" \
			-v "$TSX_APORTS_KEY.pub:/etc/apk/keys/$KEYNAME.pub:ro" \
			"$(arch_image "$IARCH")" sh -euc "
				apk add --no-cache abuild >/dev/null
				cd /repo
				rm -f APKINDEX.tar.gz APKINDEX.unsigned.tar.gz
				apk index --rewrite-arch $arch -d 'tsx-aports $cat' -o APKINDEX.unsigned.tar.gz *.apk
				abuild-sign -k /keys/$KEYNAME APKINDEX.unsigned.tar.gz
				mv APKINDEX.unsigned.tar.gz APKINDEX.tar.gz
			"
	done
done

echo "index.sh: assembling $OUT"
DEST=$OUT${PREFIX:+/$PREFIX}/v3.24
mkdir -p "$DEST"
rsync -a --delete "$SRC/" "$DEST/"
du -sh "$OUT" 2>/dev/null || true
# sed, not head: head exits early, sort gets SIGPIPE, and pipefail fails the run.
find "$OUT" -name '*.apk' -exec du -h {} + | sort -rh | sed -n 1,10p
echo "index.sh: done. Published tree: $OUT (copy its contents to the Pages/release destination)"
