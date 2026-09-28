#!/bin/bash
# Assemble the published tree from what scripts/build.sh left in packages/v3.24,
# and (re)sign the APKINDEX for each <category>/<arch>. scripts/build.sh
# already writes a signed index as part of `abuild -r`, but only over the
# packages in that build's own packages/ dir; this script rebuilds the index
# over everything that is published, after pruning old package versions
# (GitHub Pages has no hard per-file limit but a ~1GB soft repo-size limit,
# and tsx-xx60-chromium alone is well over 100MB per build -- see
# README.md "Hosting and size"), plus
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
# Env: TSX_APORTS_KEY (private key; the index is always rebuilt and signed).
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
		prune_dir "$arch_dir" || true
		# Always re-index and re-sign: the index scripts/build.sh leaves behind
		# only lists what that build's own packages/ dir held (a fresh remote
		# BUILD_DIR, or a package built after the last full index, would
		# otherwise be missing from what panels see).
		echo "index.sh: indexing + signing $cat/$arch"
		: "${TSX_APORTS_KEY:?set TSX_APORTS_KEY to sign the index}"
		# keep the key's real basename: abuild-sign names the signature
		# entry after it (.SIGN.RSA.<basename>.pub) and panels look the key
		# up in /etc/apk/keys by exactly that name. The public key is
		# trusted inside the container so `apk index` verifies every
		# package's own signature too. --rewrite-arch (what abuild -r does):
		# a noarch package (tsx-keys) is published in the <arch> dir, and apk
		# fetches from <repo>/<arch recorded in the index>/.
		KEYNAME=$(basename "$TSX_APORTS_KEY")
		docker run --rm --platform linux/arm/v7 \
			-v "$arch_dir:/repo" -v "$TSX_APORTS_KEY:/keys/$KEYNAME:ro" \
			-v "$TSX_APORTS_KEY.pub:/etc/apk/keys/$KEYNAME.pub:ro" \
			alpine:3.24 sh -euc "
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
mkdir -p "$OUT"
rsync -a --delete "$SRC/" "$OUT/v3.24/"
du -sh "$OUT" 2>/dev/null || true
find "$OUT" -name '*.apk' -exec du -h {} + | sort -rh | head -10
echo "index.sh: done. Published tree: $OUT (copy its contents to the Pages/release destination)"
