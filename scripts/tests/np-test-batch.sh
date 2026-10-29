#!/bin/sh
# Batch reports each game's verdict, but fails overall if a run or its JSON fails.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
cp "$root/scripts/np-test-batch.sh" "$work/np-test-batch.sh"
mkdir "$work/bin"
cat > "$work/np-test-game.sh" <<'SCRIPT'
#!/bin/sh
case " $* " in *" --stop "*) ;; *) exit 65 ;; esac
case "$1" in
    1) printf '%s\n' '{"appid":1,"name":"One","backend":"dxmt","verdict":"running","seconds_alive":3}'; exit 0 ;;
    2) printf '%s\n' '{"appid":2,"name":"Two","backend":"dxmt","verdict":"crashed","seconds_alive":2}'; exit 1 ;;
    3) echo invalid-json; exit 2 ;;
    4) printf '%s\n' '{"appid":4}'; exit 0 ;;
    *) exit 64 ;;
esac
SCRIPT
printf '#!/bin/sh\nexit 0\n' > "$work/bin/sleep"
chmod +x "$work/bin/sleep" "$work/np-test-game.sh"
export PATH="$work/bin:$PATH"
if ! bash "$work/np-test-batch.sh" 1 > "$work/out" 2> "$work/err"; then
    echo 'successful game should pass the batch' >&2; exit 1
fi
grep -qx "$(printf '1\tOne\tdxmt\trunning\t3s')" "$work/out"
if bash "$work/np-test-batch.sh" 1 2 3 4 > "$work/out" 2> "$work/err"; then
    echo 'failed game must fail the batch' >&2; exit 1
fi
grep -qx "$(printf '2\tTwo\tdxmt\tcrashed\t2s')" "$work/out"
grep -q 'game 2 exited with status 1' "$work/err"
grep -q 'game 3 exited with status 2' "$work/err"
grep -q 'no valid result for game 3' "$work/err"
grep -q 'no valid result for game 4' "$work/err"
echo 'np-test-batch: success, failure and invalid results checked'
