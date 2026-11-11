#!/bin/sh
# Refuse a recipe whose _pins names a sha256 that the UC-P10 safety rules do not
# name yet (uc-pxx/RULES-PINS, the mirror of ucp10 RULES.md).
#
#   scripts/check-rules-pins.sh APKBUILD
#
# _pins lines are "SHA256 SOURCE PATH" (uc-pxx-boot-tools, uc-pxx-board). Each
# SHA256 must be on a line "SHA256 PATH # entry" of uc-pxx/RULES-PINS with the
# same PATH. A recipe without _pins passes. scripts/build.sh runs this before
# abuild, so CI never builds (and so never publishes) boot control that the
# rules do not name: a panel on a channel would install it and run it without
# a person (uc-pxx-post-update). A private test build on the build host may set
# TSX_ALLOW_UNREVIEWED_PINS=1: then the script only warns. CI never sets it.
set -eu
REC=${1:?usage: check-rules-pins.sh APKBUILD}
HERE=$(cd "$(dirname "$0")" && pwd)
LIST=${TSX_RULES_PINS:-$HERE/../uc-pxx/RULES-PINS}
[ -f "$REC" ] || { echo "check-rules-pins: no $REC" >&2; exit 1; }
PINS=$(startdir=$(dirname "$REC") srcdir=/nonexistent; . "$REC" >/dev/null 2>&1; printf '%s\n' "${_pins:-}")
[ -n "$(printf '%s' "$PINS" | tr -d ' \n\t')" ] || exit 0
[ -f "$LIST" ] || { echo "check-rules-pins: no $LIST" >&2; exit 1; }
bad=0
while read -r sum src path; do
	[ -n "$sum" ] || continue
	if awk -v s="$sum" -v p="$path" '$1 == s && $2 == p { f = 1 } END { exit !f }' "$LIST"; then
		echo "check-rules-pins: in the rules: /$path $sum"
	else
		echo "check-rules-pins: NOT IN THE RULES: /$path $sum ($REC)" >&2
		bad=1
	fi
done <<EOT
$PINS
EOT
[ $bad = 0 ] && exit 0
if [ "${TSX_ALLOW_UNREVIEWED_PINS:-}" = 1 ]; then
	echo "check-rules-pins: WARNING: TSX_ALLOW_UNREVIEWED_PINS=1: a private test build with boot control that the rules do not name. Never publish it." >&2
	exit 0
fi
echo "check-rules-pins: $REC pins files that the UC-P10 safety rules do not name: not built (a private test build: TSX_ALLOW_UNREVIEWED_PINS=1)" >&2
exit 1
