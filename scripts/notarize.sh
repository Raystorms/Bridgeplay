#!/bin/sh
# Notarize a signed app bundle with Apple and staple the ticket to it, so Gatekeeper opens a
# downloaded copy without Open Anyway, offline too. See docs/RELEASING.md (Signing).
#
#   scripts/notarize.sh <path/to/Some.app>
#
# Env: BRIDGEPLAY_NOTARY_PROFILE  notarytool keychain profile (default "bridgeplay-notary"),
#      created once with `xcrun notarytool store-credentials`.

set -eu

die() { echo "==> $*" >&2; exit 1; }

[ "$#" -eq 1 ] && [ -d "$1" ] || die "usage: $0 <path/to/Some.app>"
app=$1
profile=${BRIDGEPLAY_NOTARY_PROFILE:-bridgeplay-notary}

# Apple refuses anything without a Developer ID, the hardened runtime and a secure
# timestamp; checking here fails in seconds instead of after the upload.
codesign --verify --strict --deep "$app" || die "$app is not validly signed"
info=$(codesign -dvv "$app" 2>&1)
printf '%s\n' "$info" | grep -q '^Authority=Developer ID Application: ' \
	|| die "$app is not signed with a Developer ID Application certificate"
printf '%s\n' "$info" | grep -q '^Timestamp=' || die "$app has no secure timestamp (codesign --timestamp)"
codesign -d --verbose=1 "$app" 2>&1 | grep -q 'flags=.*runtime' \
	|| die "$app does not have the hardened runtime (codesign --options runtime)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
zip="$work/$(basename "$app" .app).zip"
ditto -c -k --keepParent "$app" "$zip"

echo "==> notarizing $(basename "$app") (profile $profile), usually a few minutes"
result="$work/result.json"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait --output-format json >"$result" \
	|| { cat "$result" >&2; die "notarytool submit failed"; }
id=$(plutil -extract id raw -o - "$result" 2>/dev/null || true)
status=$(plutil -extract status raw -o - "$result" 2>/dev/null || true)
if [ "$status" != "Accepted" ]; then
	# The log names each file Apple rejected and why.
	[ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
	die "notarization of $app: ${status:-no status} (submission ${id:-unknown})"
fi
echo "==> notarized (submission $id)"

xcrun stapler staple "$app" >/dev/null || die "could not staple the ticket to $app"
xcrun stapler validate "$app" >/dev/null || die "the stapled ticket on $app does not validate"
# What Gatekeeper decides for a downloaded copy.
spctl --assess --type execute -vv "$app" 2>&1 | grep -q 'source=Notarized Developer ID' \
	|| die "Gatekeeper does not accept $app as Notarized Developer ID"
echo "==> stapled; Gatekeeper: Notarized Developer ID"
