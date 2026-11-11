#!/bin/sh
# Check a BUILT .apk by its content against the UC-P10 safety rules
# (uc-pxx/RULES-PINS), whatever its recipe declares (re-look r1 of
# BOTH-SLOT-PACKAGING-REVIEW): a recipe that drops or renames _pins must not
# ship boot control that the rules do not name.
#
#   scripts/check-rules-content.sh APK
#
# Guarded paths: each one in the package must have a sha256 that RULES-PINS
# lists for that path. /boot/uc-pxx-lts.img (the kernel package) is checked by
# its Linux Image (the kernel part from 2 MiB on, as the installer gate reads
# it): RULES-PINS line "SHA256 linux-image:boot/uc-pxx-lts.img". The A/B tool
# of the installer and the files of step 2 are never in a package: always
# refused. TSX_ALLOW_UNREVIEWED_PINS=1 (a private test build on the build
# host, never CI) turns a missing RULES-PINS line into a warning; the
# never-in-a-package rule stays. scripts/build.sh runs this after abuild and
# removes the .apk when it fails.
set -eu
APK=${1:?usage: check-rules-content.sh APK}
HERE=$(cd "$(dirname "$0")" && pwd)
LIST=${TSX_RULES_PINS:-$HERE/../uc-pxx/RULES-PINS}
GUARDED="usr/sbin/uc-pxx-bootctl etc/uc-pxx-mark-boot.sh etc/init.d/uc-pxx-boot-ok usr/sbin/uc-pxx-flash-boot
usr/sbin/uc-pxx-arm-slot usr/sbin/uc-pxx-update-boot usr/sbin/uc-pxx-post-update usr/sbin/uc-pxx-slot
usr/local/lib/tsx/board.sh usr/sbin/uc-pxx-data-migrate usr/sbin/uc-pxx-data-release"
[ -f "$APK" ] && [ -f "$LIST" ] || { echo "check-rules-content: no $APK or $LIST" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
tar -xzf "$APK" -C "$T" 2>/dev/null || true
listed() { awk -v s="$1" -v p="$2" '$1 == s && $2 == p { f = 1 } END { exit !f }' "$LIST"; }
bad=0 never=0
for p in $GUARDED; do
	[ -e "$T/$p" ] || [ -L "$T/$p" ] || continue
	if [ -L "$T/$p" ] || [ ! -f "$T/$p" ]; then echo "check-rules-content: /$p is not a regular file ($APK)" >&2; bad=1; continue; fi
	s=$(sha256sum "$T/$p" | cut -d' ' -f1)
	if listed "$s" "$p"; then echo "check-rules-content: in the rules: /$p $s"
	else echo "check-rules-content: NOT IN THE RULES: /$p $s ($APK)" >&2; bad=1; fi
done
if [ -f "$T/boot/uc-pxx-lts.img" ]; then
	s=$(python3 -I - "$T/boot/uc-pxx-lts.img" <<'PY'
import hashlib, struct, sys
d = open(sys.argv[1], "rb").read()
ksize, = struct.unpack_from("<I", d, 8); page, = struct.unpack_from("<I", d, 36)
print(hashlib.sha256(d[page + 0x200000:page + ksize]).hexdigest())
PY
)
	if listed "$s" linux-image:boot/uc-pxx-lts.img; then echo "check-rules-content: in the rules: the Linux Image of /boot/uc-pxx-lts.img $s"
	else echo "check-rules-content: NOT IN THE RULES: the Linux Image of /boot/uc-pxx-lts.img $s ($APK)" >&2; bad=1; fi
fi
n=$(cd "$T" && find . \( -name 'uc-pxx-bootctl-inst*' -o -name 'uc-pxx-step2*' \) | sed 's#^\./##' | tr '\n' ' ')
[ -z "$n" ] || { echo "check-rules-content: never in a package: $n ($APK)" >&2; never=1; }
[ $never = 0 ] || exit 1
[ $bad = 0 ] && exit 0
if [ "${TSX_ALLOW_UNREVIEWED_PINS:-}" = 1 ]; then
	echo "check-rules-content: WARNING: TSX_ALLOW_UNREVIEWED_PINS=1: $APK holds boot control that the rules do not name. Never publish it." >&2
	exit 0
fi
echo "check-rules-content: $APK holds boot control that the UC-P10 safety rules do not name: removed" >&2
exit 1
