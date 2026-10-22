#!/bin/sh
# exitcheck: the run script's account of how a game ended (exit_summary in compat_run.sh),
# which play reports quote.
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "exitcheck: $SRC not present, skipped"; exit 0; }

extract() { sed -n "/^$1() {\$/,/^}\$/p" "$SRC"; }
functions=""
for name in exit_meaning exit_signal exit_crash_lines exit_summary; do
	body=$(extract "$name")
	[ -n "$body" ] || { echo "FAIL: $name not found in $SRC"; exit 1; }
	functions="$functions
$body"
done
eval "$functions"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

clean="$work/clean.log"
printf '0118:err:kerberos:kerberos_LsaApInitializePackage no Kerberos support, expect problems\n' > "$clean"
unset NOTPROTON_LAUNCH_SERVICES
summary() { exit_summary "$1" "$2" "$3" "${4:-$clean}"; }

echo "== how the game ended =="
is "abort() after the game's own dialog (Mewgenics)" \
	"=== exit summary: exit status 3 after 75s, the game quit by itself (abort() in the C runtime or a breakpoint, usually after the game's own error message) ===" \
	"$(summary 3 75 0)"
is "exit -1 (SCP: Containment Breach)" \
	"=== exit summary: exit status 255 after 19s, the game quit by itself (exit code -1, a failure the game reported itself) ===" \
	"$(summary 255 19 0)"
is "a quick clean quit is suspicious (Plants vs. Zombies)" \
	"=== exit summary: exit status 0 after 24s, the game quit by itself within a minute without an error code, usually after its own error message ===" \
	"$(summary 0 24 0)"
is "a long session that ends cleanly, in minutes (Roboquest)" \
	"=== exit summary: exit status 0 after 27 min, the game quit normally ===" \
	"$(summary 0 1642 0)"
is "Steam's Exit Game wins over the status" \
	"=== exit summary: exit status 143 after 6s, stopped from Steam ===" \
	"$(summary 143 6 1)"
is "SIGTERM from outside Steam" \
	"=== exit summary: exit status 143 after 30s, Wine was killed by SIGTERM, asked to quit from outside Steam ===" \
	"$(summary 143 30 0)"
is "a Mac-side crash is a signal, not a Windows code" \
	"=== exit summary: exit status 139 after 5s, Wine was killed by SIGSEGV, a crash in Mac-side code such as Wine, D3DMetal or MoltenVK ===" \
	"$(summary 139 5 0)"
is "the low byte of 0xc0000135" \
	"=== exit summary: exit status 53 after 2s, the game quit by itself (0xc0000135, a DLL the game needs was not found) ===" \
	"$(summary 53 2 0)"
is "an unknown code stays raw" \
	"=== exit summary: exit status 42 after 10s, the game quit by itself ===" \
	"$(summary 42 10 0)"
is "Launch Services hides the game's status" \
	"=== exit summary: exit status 0 after 10s, started through Launch Services, so the status is open's and not the game's ===" \
	"$(NOTPROTON_LAUNCH_SERVICES=1; summary 0 10 0)"
is "a missing Wine log adds nothing" \
	"=== exit summary: exit status 5 after 3s, the game quit by itself (0xc0000005, an access violation: the game crashed) ===" \
	"$(summary 5 3 0 "$work/none.log")"

echo "== Wine's crash lines =="
crash="$work/crash.log"
{
	printf 'overlay_shim_load: pid=91135 exe=wine layer_hooks=3 overlay=present\n'
	printf '0024:err:module:import_dll Library MSVCP140.dll (which is needed by L"Z:\\\\Users\\\\someone\\\\Game.exe") not found\n'
	printf 'wine: Unhandled page fault on read access to 0000000000000000 at address 0000000140001234 (thread 0124), starting debugger...\n'
	printf 'overlay_shim_load: pid=91140 exe=winedbg layer_hooks=3 overlay=present\n'
	printf 'Unhandled exception: page fault on read access to 0x00000000 in 64-bit code (0x0000000140001234).\n'
	printf 'wine: Unhandled page fault again\n'
} > "$crash"
is "the first three crash lines follow the summary, then the crash handler" \
	"=== exit summary: exit status 5 after 12s, the game quit by itself (0xc0000005, an access violation: the game crashed) ===
=== exit cause: 0024:err:module:import_dll Library MSVCP140.dll (which is needed by L\"Z:\\\\Users\\\\someone\\\\Game.exe\") not found ===
=== exit cause: wine: Unhandled page fault on read access to 0000000000000000 at address 0000000140001234 (thread 0124), starting debugger... ===
=== exit cause: Unhandled exception: page fault on read access to 0x00000000 in 64-bit code (0x0000000140001234). ===
=== exit note: Wine started its crash handler, whose error dialog can sit behind the game ===" \
	"$(summary 5 12 0 "$crash")"

odd="$work/odd.log"
printf 'wine: could not load \303\251t\303\251.dll\r\n' > "$odd"
long=$(printf '%0400d' 0)
printf 'wine: cannot find %s\n' "$long" >> "$odd"
printf 'wine: configuration in L"\\\\??\\\\C:\\\\users" has been updated.\n' >> "$odd"
lines=$(exit_crash_lines "$odd")
is "non-ASCII and carriage returns are dropped, Wine's routine notes are not crash lines" \
	"wine: could not load t.dll" "$(printf '%s\n' "$lines" | sed -n 1p)"
is "a long line is cut" 300 "$(printf '%s\n' "$lines" | sed -n 2p | tr -d '\n' | wc -c | tr -d ' ')"
is "only crash lines are kept" 2 "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')"

if [ "$fails" -ne 0 ]; then
	echo "exitcheck: $fails failure(s)"
	exit 1
fi
echo "==> exitcheck: exit summaries read as expected"
