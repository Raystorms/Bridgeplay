#!/bin/sh
# Print docs_only=true when the change under test touches only docs, docs_only=false
# otherwise. Run from the checkout; the app workflow appends the line to $GITHUB_OUTPUT.
#   EVENT   github.event_name
#   BEFORE  github.event.before (push events)
# Any doubt answers false and the whole workflow runs: another event, a new branch, a
# base that can't be fetched, no changed files, an unreadable docs list.
here=$(dirname "$0")

changed_paths() {
	case ${EVENT:-} in
	pull_request)
		# The checked-out merge commit: its first parent is the base, the second the PR head.
		git rev-parse --verify -q 'HEAD^2' >/dev/null || return 1
		git -c core.quotePath=false diff --name-only --no-renames 'HEAD^1' HEAD
		;;
	push)
		before=${BEFORE:-}
		# All zeros: the first push of a branch has no earlier tip to compare with.
		case $before in '' | *[!0]*) ;; *) return 1 ;; esac
		git cat-file -e "$before^{commit}" 2>/dev/null ||
			git fetch -q --no-tags --depth=1 origin "$before" || return 1
		git -c core.quotePath=false diff --name-only --no-renames "$before" HEAD
		;;
	*) return 1 ;;
	esac
}

result=false
if paths=$(changed_paths 2>/dev/null) && [ -n "$paths" ] &&
	code=$(printf '%s\n' "$paths" | sh "$here/ci-code-paths.sh") && [ -z "$code" ]; then
	result=true
fi
echo "ci-scope: ${EVENT:-no event}, docs_only=$result" >&2
echo "docs_only=$result"
