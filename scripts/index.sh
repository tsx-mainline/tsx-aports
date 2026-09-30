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
#   scripts/index.sh [--keep N] [--out DIR]
#
# --keep N   keep the newest N versions of each package (sorted by
#            pkgver/pkgrel), delete the others, then re-index. The default
#            is 2: the latest version and one previous version.
# --out DIR  the directory for the published tree (default: repo/,
#            gitignored). CI publishes it (see .github/workflows/build.yml).
#
# Environment: TSX_APORTS_KEY (the private key). The script always rebuilds
# and signs the index.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
KEEP=2
OUT="$REPO/repo"
while [ $# -gt 0 ]; do case $1 in
	--keep) KEEP=$2; shift;;
	--out) OUT=$2; shift;;
	-h|--help) sed -n '2,19p' "$0"; exit 0;;
	*) echo "unknown arg $1" >&2; exit 1;;
esac; shift; done

SRC="$REPO/packages/v3.24"
[ -d "$SRC" ] || { echo "index.sh: no $SRC -- run scripts/build.sh first" >&2; exit 1; }

prune_dir() {  # ARCH_DIR
	local d="$1" pruned=0
	# Group the files by pkgname (without -<pkgver>-r<pkgrel>.apk). Keep the
	# KEEP newest files. The order comes from a plain version sort. This is
	# close enough for a prune, and the prune alone does nothing that
	# affects security.
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
