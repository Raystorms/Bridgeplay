#!/bin/sh
# Package a built Bridgeplay.app as Bridgeplay.dmg: the app and an Applications link in a
# window with installer/dmg/background.tiff, so people drag the app across and open it.
# The app's Setup Assistant does the rest. See docs/RELEASING.md.
#
#   scripts/package-dmg.sh <path/to/Bridgeplay.app> <out.dmg>
#
# A Developer ID identity (BRIDGEPLAY_SIGN_IDENTITY) signs the image, and the image is
# notarized and stapled (scripts/notarize.sh) unless BRIDGEPLAY_DMG_NOTARIZE=0. Any other
# identity leaves it unsigned, for local builds and dry runs.
#
# The window layout is a .DS_Store written by dmgbuild (pinned below), so building needs no
# Finder scripting. It is installed once into out/dmgbuild-venv.

set -eu

die() { echo "==> $*" >&2; exit 1; }

[ "$#" -eq 2 ] && [ -d "$1" ] || die "usage: $0 <path/to/Bridgeplay.app> <out.dmg>"
repo=$(cd "$(dirname "$0")/.." && pwd)
app=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
out=$2
identity=${BRIDGEPLAY_SIGN_IDENTITY:--}
background=$repo/installer/dmg/background.tiff
[ -f "$background" ] || die "no $background; run installer/dmg/render-background.sh"
[ "$(basename "$app")" = Bridgeplay.app ] || die "$app is not Bridgeplay.app"

dmgbuild_version=1.6.7
venv=$repo/out/dmgbuild-venv
if [ "$("$venv/bin/python3" -I -c 'import importlib.metadata as m; print(m.version("dmgbuild"))' 2>/dev/null)" != "$dmgbuild_version" ]; then
	echo "==> installing dmgbuild $dmgbuild_version into $venv"
	rm -rf "$venv"
	python3 -m venv "$venv"
	"$venv/bin/pip" -q install "dmgbuild==$dmgbuild_version" || die "could not install dmgbuild"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
settings=$work/settings.py
# Icon centres match the two slots in background.html. ULMO (lzma) is about a quarter smaller
# than UDZO (zlib) for this app; it opens on macOS 10.15 and later.
cat >"$settings" <<PYTHON
files = [$(printf '%s' "$app" | python3 -I -c 'import json,sys; print(json.dumps(sys.stdin.read()))')]
symlinks = {"Applications": "/Applications"}
background = $(printf '%s' "$background" | python3 -I -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
format = "ULMO"
filesystem = "APFS"
window_rect = ((200, 160), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {"Bridgeplay.app": (165, 200), "Applications": (495, 200)}
hide_extension = ["Bridgeplay.app"]
PYTHON

mkdir -p "$(dirname "$out")"
rm -f "$out"
"$venv/bin/dmgbuild" -s "$settings" Bridgeplay "$out" >"$work/dmgbuild.log" 2>&1 \
	|| { cat "$work/dmgbuild.log" >&2; die "dmgbuild failed"; }

case "$identity" in
	"Developer ID Application: "*)
		codesign --sign "$identity" --timestamp "$out"
		if [ "${BRIDGEPLAY_DMG_NOTARIZE:-1}" = 1 ]; then
			"$repo/scripts/notarize.sh" "$out"
		fi
		;;
esac
echo "==> $out ($(du -h "$out" | cut -f1 | tr -d ' '))"
