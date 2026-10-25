#!/bin/sh
# Check the pinned files in a built package: every line of _pins in the recipe
# names a file of the package and its sha256. abuild changes the files after
# package() (for example strip), so this check reads the final .apk.
#
#   scripts/check-apk-pins.sh APKBUILD APK
#
# _pins lines are "SHA256 SOURCE PATH" (uc-pxx/uc-pxx-boot-tools/APKBUILD).
# The script prints each result. It exits 1 and REMOVES the .apk when a file
# is missing or has another sha256, so a changed copy never goes into the
# tree. A recipe without _pins passes. scripts/build.sh runs it after abuild.
set -eu
REC=${1:?usage: check-apk-pins.sh APKBUILD APK}
APK=${2:?usage: check-apk-pins.sh APKBUILD APK}
PINS=$(startdir=$(dirname "$REC") srcdir=/nonexistent; . "$REC" >/dev/null 2>&1; printf '%s\n' "${_pins:-}")
[ -n "$(printf '%s' "$PINS" | tr -d ' \n\t')" ] || { echo "check-apk-pins: $REC has no _pins"; exit 0; }
[ -f "$APK" ] || { echo "check-apk-pins: no $APK" >&2; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# An apk is three concatenated gzip streams (signature, control, data). tar
# reads them as one archive.
tar -xzf "$APK" -C "$T" 2>/dev/null || true
bad=0
while read -r sum src path; do
	[ -n "$sum" ] || continue
	case $path in ""|/*|*..*) echo "check-apk-pins: bad pin line: $sum $src $path" >&2; bad=1; continue;; esac
	got=$(sha256sum "$T/$path" 2>/dev/null | cut -d' ' -f1)
	if [ "$got" = "$sum" ]; then
		echo "check-apk-pins: OK /$path $sum"
	else
		echo "check-apk-pins: CHANGED /$path in $(basename "$APK"): sha256 '${got:-missing}', the reviewed file is $sum" >&2
		bad=1
	fi
done <<EOF
$PINS
EOF
if [ $bad != 0 ]; then
	rm -f "$APK"
	echo "check-apk-pins: removed $APK" >&2
	exit 1
fi
