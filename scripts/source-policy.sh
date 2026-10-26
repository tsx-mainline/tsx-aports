# Which GitHub sources a recipe may use on which channel. scripts/build.sh and
# scripts/tests/test-sources.sh source this file. Do not run it.
#
# The stable channel (main) builds from the archive of a signed tag
# (.../archive/refs/tags/<tag>.tar.gz). The testing channel (the branch
# testing) may also build from the archive of one commit
# (.../archive/<40 hex characters>.tar.gz), so a change that has no tag yet can
# be tested. A branch name or a short sha is never allowed, because the bytes
# of such an archive change.

# channel_name: the channel of this run, from TSX_APORTS_CHANNEL (stable or
# testing). Anything else is stable.
channel_name() {
	case ${TSX_APORTS_CHANNEL:-stable} in testing) echo testing;; *) echo stable;; esac
}

# is_commit_source URL: 0 if URL is the GitHub archive of a full commit sha.
is_commit_source() {
	printf '%s\n' "$1" | grep -Eq '^https://github\.com/[^/]+/[^/]+/archive/[0-9a-f]{40}\.tar\.gz$'
}

# source_policy CHANNEL URL: return 0 if the channel may use URL. Else print
# the reason and return 1. A URL that is not on a GitHub host is not checked.
# The scheme and the host are compared in lower case. A URL with "..", an
# encoded dot or slash, "?" or "#" is refused: a glob could match it as a tag
# and curl would fetch another file.
source_policy() {
	local channel=$1 url=$2 head rest
	head=${url%%://*}; rest=${url#*://}
	head=${head,,}
	rest="${rest%%/*}"; rest=${rest,,}/${url#*://*/}
	url=$head://$rest
	# The host must be exactly github.com, codeload.github.com or
	# raw.githubusercontent.com. A port, a trailing dot or a user name before
	# the host makes another name for the same server, so it is refused. Any
	# other host is not checked, unless it names GitHub.
	local auth=${rest%%/*}
	case $auth in
	github.com|codeload.github.com|raw.githubusercontent.com) ;;
	*github.com*|*githubusercontent.com*)
		echo "the host of a GitHub source must be exactly github.com, codeload.github.com or raw.githubusercontent.com"; return 1;;
	*) return 0;;
	esac
	[ "$head" = https ] || { echo "a GitHub source must use https"; return 1; }
	case $url in
	*..*|*%2[eEfF]*|*\?*|*\#*|*[[:space:]]*) echo "a GitHub source URL must be plain: no .., encoded dot or slash, query or fragment"; return 1;;
	esac
	if printf '%s\n' "$url" | grep -Eq '^https://github\.com/[^/]+/[^/]+/archive/refs/tags/[^/]+\.tar\.gz$'; then
		return 0
	fi
	# A release asset (kernel bundles, tools bundles) is a published file, not a source tree.
	if printf '%s\n' "$url" | grep -Eq '^https://github\.com/[^/]+/[^/]+/releases/download/[^/]+/[^/]+$'; then
		return 0
	fi
	if is_commit_source "$url" \
		|| printf '%s\n' "$url" | grep -Eq '^https://(codeload\.github\.com/[^/]+/[^/]+/tar\.gz/[0-9a-f]{40}|raw\.githubusercontent\.com/[^/]+/[^/]+/[0-9a-f]{40}/.+)$'; then
		[ "$channel" = testing ] && return 0
		echo "a commit source is allowed on the testing branch only. Stable needs the archive of a signed tag"
		return 1
	fi
	echo "a GitHub source must be the archive of a signed tag (github.com/.../archive/refs/tags/TAG.tar.gz) or, on testing, of a full 40-character commit sha"
	return 1
}
