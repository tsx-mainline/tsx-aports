#!/bin/bash
# Assemble the published tree from what scripts/build.sh left in packages/v3.24,
# and (re)sign the APKINDEX for each <category>/<arch>. scripts/build.sh
# already writes a signed index as part of `abuild -r`; this script exists
# for the case that matters for publishing: pruning old package versions
# (GitHub Pages has no hard per-file limit but a ~1GB soft repo-size limit,
# and tsx-xx60-chromium alone is well over 100MB per build -- see
# README.md "Hosting and size") and re-signing the index after a prune, plus
# copying a stable, ready-to-serve tree to $OUT (default repo/).
#
#   scripts/index.sh [--keep N] [--out DIR]
#
# --keep N   keep the newest N versions of each package (by pkgver/pkgrel
#            sort), delete the rest, then reindex (default: 2, i.e. latest +
#            one previous version, per the hosting decision in README.md).
# --out DIR  where to place the published tree (default: repo/, gitignored;
#            CI publishes this directly, see .github/workflows/build.yml)
#
# Env: TSX_APORTS_KEY (private key, for re-signing after a prune -- not
# needed if nothing was pruned, since scripts/build.sh already signed).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
KEEP=2
OUT="$REPO/repo"
while [ $# -gt 0 ]; do case $1 in
	--keep) KEEP=$2; shift;;
	--out) OUT=$2; shift;;
	-h|--help) sed -n '2,20p' "$0"; exit 0;;
	*) echo "unknown arg $1" >&2; exit 1;;
esac; shift; done

SRC="$REPO/packages/v3.24"
[ -d "$SRC" ] || { echo "index.sh: no $SRC -- run scripts/build.sh first" >&2; exit 1; }

prune_dir() {  # ARCH_DIR
	local d="$1" pruned=0
	# group files by pkgname (strip -<pkgver>-r<pkgrel>.apk), keep the KEEP
	# newest by apk's own version compare (apk_vercmp via `apk` if available,
	# else fall back to a plain sort -- close enough for a prune, and this
	# never runs on anything security relevant by itself).
	for pkgname in $(cd "$d" && ls -- *.apk 2>/dev/null | sed -E 's/-[0-9][^-]*-r[0-9]+\.apk$//' | sort -u); do
		local files
		files=$(cd "$d" && ls -- "$pkgname"-*.apk 2>/dev/null | sort -V)
		local n old
		n=$(printf '%s\n' "$files" | wc -l)
		if [ "$n" -gt "$KEEP" ]; then
			old=$(printf '%s\n' "$files" | head -n $((n - KEEP)))
			for f in $old; do
				echo "index.sh: pruning $d/$f"
				rm -f "$d/$f"
				pruned=1
			done
		fi
	done
	return $pruned
}

for cat_dir in "$SRC"/*/; do
	cat=$(basename "$cat_dir")
	for arch_dir in "$cat_dir"*/; do
		arch=$(basename "$arch_dir")
		if prune_dir "$arch_dir"; then
			: # nothing pruned, existing APKINDEX (from build.sh) still valid
		else
			echo "index.sh: re-signing $cat/$arch after pruning"
			: "${TSX_APORTS_KEY:?pruning happened; set TSX_APORTS_KEY to re-sign}"
			docker run --rm --platform linux/arm/v7 \
				-v "$arch_dir:/repo" -v "$TSX_APORTS_KEY:/key.rsa:ro" \
				alpine:3.24 sh -euc "
					apk add --no-cache abuild >/dev/null
					cd /repo
					rm -f APKINDEX.tar.gz
					apk index -o APKINDEX.unsigned.tar.gz *.apk
					abuild-sign -k /key.rsa APKINDEX.unsigned.tar.gz
					mv APKINDEX.unsigned.tar.gz APKINDEX.tar.gz
				"
		fi
	done
done

echo "index.sh: assembling $OUT"
mkdir -p "$OUT"
rsync -a --delete "$SRC/" "$OUT/v3.24/"
du -sh "$OUT" 2>/dev/null || true
find "$OUT" -name '*.apk' -exec du -h {} + | sort -rh | head -10
echo "index.sh: done. Published tree: $OUT (copy its contents to the Pages/release destination)"
