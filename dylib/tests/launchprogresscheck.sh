#!/bin/sh
# launchprogresscheck: the panel between Play and the game's first window (launch_progress and
# launch_step in compat_run.sh). It starts beside the launch without holding it up or taking
# the prefix locks, only for a game launch, and only after the kernel anti-cheat prompt.
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "launchprogresscheck: $SRC not present, skipped"; exit 0; }

extract() { sed -n "/^$1() {\$/,/^}\$/p" "$SRC"; }
functions=""
for name in launch_progress launch_step; do
	body=$(extract "$name")
	[ -n "$body" ] || { echo "FAIL: $name not found in $SRC"; exit 1; }
	functions="$functions
$body"
done

work=$(mktemp -d) && work=$(cd "$work" && pwd -P) || exit 1
trap 'rm -rf "$work"' EXIT

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

support="$work/support"
compat="$work/steamapps/compatdata/3372060"
mkdir -p "$support" "$compat"
# The app stand-in records its arguments and the descriptors it was handed, then outlives the
# launch so a launch that waited on it would show.
app="$work/Bridgeplay.app/Contents/MacOS/BridgeplayApp"
mkdir -p "$(dirname "$app")"
cat > "$app" <<'APP'
#!/bin/sh
out="$(dirname "$0")/started"
printf '%s\n' "$@" > "$out.args"
for fd in 7 8 9; do { true >&"$fd"; } 2>/dev/null && echo "$fd" >> "$out.fds"; done
mv "$out.args" "$out"
sleep 5
APP
chmod +x "$app"
started="$(dirname "$app")/started"

# run VERB NEW [APP]: one launch up to the panel, with lock-like descriptors 8 and 9 open
run() {
	rm -f "$started" "$started.fds" "$compat/bridgeplay-launch-step" "$work/notes"
	if [ -n "${3:-}" ]; then printf '%s' "$3" > "$support/app-executable"; else rm -f "$support/app-executable"; fi
	before=$(date +%s)
	env verb="$1" prefix_was_new="$2" app_id=3372060 np_support="$support" log="$work/log" \
		STEAM_COMPAT_DATA_PATH="$compat" notes="$work/notes" functions="$functions" \
		sh -ec 'eval "$functions"
notify_user() { printf "%s\n" "$1" >> "$notes"; }
exec 8>> "$notes.lock" 9>> "$notes.lock"
if [ "$prefix_was_new" = 1 ]; then launch_progress setup; else launch_progress prepare; fi
launch_step start'
	took=$(($(date +%s) - before))
}
wait_started() { i=0; while [ ! -f "$started" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; }

echo "== starting it =="
run waitforexitandrun 1 "$app"
is "the launch does not wait for the panel" yes "$([ "$took" -le 2 ] && echo yes || echo no)"
wait_started
is "the app is asked for the panel with the prefix, new prefix and Wine log" \
	"--launch-progress|$compat|1|$support/launchers/3372060/bridgeplay-wine.log" \
	"$(paste -sd '|' "$started" 2>/dev/null)"
is "the prefix locks are not handed to it" "" "$(cat "$started.fds" 2>/dev/null)"
is "the last step is in the step file" start "$(cat "$compat/bridgeplay-launch-step")"
is "no notice when the panel shows" "" "$(cat "$work/notes" 2>/dev/null)"
run waitforexitandrun 0 "$app"
wait_started
is "a known prefix is passed as not new" 0 "$(sed -n 3p "$started" 2>/dev/null)"

echo "== without it =="
run run 1 "$app"
sleep 0.5
is "Steam's helpers (verb run) get no panel" no "$([ -f "$started" ] && echo yes || echo no)"
is "nor a step file" no "$([ -f "$compat/bridgeplay-launch-step" ] && echo yes || echo no)"
run waitforexitandrun 1 ""
is "no app: a new prefix gets the first-launch notice" "Getting this game ready" "$(cat "$work/notes" 2>/dev/null)"
run waitforexitandrun 0 "$work/missing"
is "no app: a known prefix gets nothing" "" "$(cat "$work/notes" 2>/dev/null)"
out=$(env functions="$functions" sh -ec 'eval "$functions"; launch_step dialog; echo fine')
is "a step before the panel started writes nothing" fine "$out"

echo "== order =="
# The anti-cheat prompt and the rebuild offer come first, and Bridgeplay's alerts hide the panel.
at() { grep -n "$1" "$SRC" | head -1 | cut -d: -f1; }
notice_at=$(at '^  kernel_anticheat_notice$')
switch_at=$(at '^  offer_switch_rebuild$')
panel_at=$(at 'launch_progress setup')
if [ -n "$notice_at" ] && [ -n "$switch_at" ] && [ -n "$panel_at" ] \
	&& [ "$notice_at" -lt "$panel_at" ] && [ "$switch_at" -lt "$panel_at" ]; then
	ok "the panel starts after the anti-cheat prompt and the rebuild offer"
else
	bad "the panel starts after the anti-cheat prompt and the rebuild offer" "$notice_at, $switch_at < panel" "${panel_at:-missing}"
fi
for name in show_alert show_rebuild_failure rebuild_prefix; do
	case "$(extract "$name")" in
		*"launch_step dialog"*) ok "$name hides the panel" ;;
		*) bad "$name hides the panel" "launch_step dialog" "missing" ;;
	esac
done

[ "$fails" -eq 0 ] || { echo "launchprogresscheck: $fails failed"; exit 1; }
echo "==> launchprogresscheck: the launch panel starts beside the launch"
