#!/usr/bin/env bash
# np-test-batch.sh <appid...> - run np-test-game.sh sequentially with --stop; prints a summary.
# Extra args via NP_TEST_ARGS, e.g. NP_TEST_ARGS="--seconds 60 --backend dxvk".
# Exit status: 64 = no app IDs; 1 = any game failed or output was invalid;
#              0 = every game exited successfully and returned valid JSON.
set -u
[ $# -gt 0 ] || { echo "usage: $0 <appid...>" >&2; exit 64; }
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2206
EXTRA=(${NP_TEST_ARGS:-})
failed=0
for id in "$@"; do
  out="$("$DIR/np-test-game.sh" "$id" ${EXTRA[@]+"${EXTRA[@]}"} --stop)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "np-test-batch: game $id exited with status $rc" >&2
    failed=1
  fi
  if ! printf '%s\n' "$out" | jq -er '
    select(type == "object" and
           (.appid | type == "number") and
           (.name | type == "string") and
           (.backend | type == "string") and
           (.verdict | type == "string") and
           (.seconds_alive | type == "number"))
    | "\(.appid)\t\(.name)\t\(.backend)\t\(.verdict)\t\(.seconds_alive)s"
  '; then
    echo "np-test-batch: no valid result for game $id" >&2
    failed=1
  fi
  sleep 5
done
exit "$failed"
