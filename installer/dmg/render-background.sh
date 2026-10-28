#!/bin/sh
# Renders background.html into background.tiff (660x400 and @2x) for scripts/package-dmg.sh.
# Needs Google Chrome; run it after editing background.html and commit the TIFF.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
chrome=${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}
[ -x "$chrome" ] || { echo "render-background: no Chrome at $chrome (set CHROME)" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for scale in 1 2; do
	"$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor="$scale" \
		--window-size=660,400 --screenshot="$work/bg$scale.png" "file://$here/background.html" >/dev/null 2>&1
done
[ "$(sips -g pixelWidth "$work/bg2.png" | awk '/pixelWidth/{print $2}')" = 1320 ] || { echo "render-background: unexpected @2x size" >&2; exit 1; }
tiffutil -cathidpicheck "$work/bg1.png" "$work/bg2.png" -out "$here/background.tiff" >/dev/null
echo "==> wrote $here/background.tiff"
