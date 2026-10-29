#!/bin/sh
# The verdict of the app workflow's "app gate" job, the one check a branch rule requires.
# Green only when the heavy jobs both succeeded, or both were skipped because the change
# is docs-only. Failed, cancelled and any other skip are red: a required check that is
# skipped counts as passing, so a skipped build must never be read as one.
#   SCOPE_RESULT   needs.scope.result
#   DOCS_ONLY      needs.scope.outputs.docs_only
#   BUILD_RESULT   needs.build.result
#   CHECKS_RESULT  needs.checks.result
fail() {
	echo "app gate: $*" >&2
	exit 1
}

[ "${SCOPE_RESULT:-}" = success ] || fail "the change scope job ended ${SCOPE_RESULT:-with no result}"
case ${DOCS_ONLY:-} in
true) want=skipped ;;
false) want=success ;;
*) fail "docs_only is '${DOCS_ONLY:-}', not true or false" ;;
esac
[ "${BUILD_RESULT:-}" = "$want" ] || fail "full app build ended ${BUILD_RESULT:-with no result}, expected $want"
[ "${CHECKS_RESULT:-}" = "$want" ] || fail "source checks ended ${CHECKS_RESULT:-with no result}, expected $want"

if [ "$want" = skipped ]; then
	echo "app gate: docs-only change, build and checks skipped"
else
	echo "app gate: full app build and source checks passed"
fi
