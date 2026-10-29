#!/bin/sh
# Notarize a signed app bundle or disk image with Apple and staple the ticket to it, so
# Gatekeeper opens a downloaded copy without Open Anyway, offline too. See docs/RELEASING.md
# (Signing).
#
#   scripts/notarize.sh <path/to/Some.app | path/to/Some.dmg>
#
# Env: BRIDGEPLAY_NOTARY_PROFILE  notarytool keychain profile (default "bridgeplay-notary"),
#      created once with `xcrun notarytool store-credentials`.

set -eu

die() { echo "==> $*" >&2; exit 1; }

[ "$#" -eq 1 ] && [ -e "$1" ] || die "usage: $0 <path/to/Some.app | path/to/Some.dmg>"
target=$1
profile=${BRIDGEPLAY_NOTARY_PROFILE:-bridgeplay-notary}
case "$target" in
	*.dmg) kind=dmg ;;
	*.app) kind=app ;;
	*) die "$target is neither an .app nor a .dmg" ;;
esac

# Apple refuses anything without a Developer ID and a secure timestamp (and, for code, the
# hardened runtime); checking here fails in seconds instead of after the upload.
deep=""
[ "$kind" = dmg ] || deep=--deep
# shellcheck disable=SC2086 # deep is empty or one flag
codesign --verify --strict $deep "$target" || die "$target is not validly signed"
info=$(codesign -dvv "$target" 2>&1)
printf '%s\n' "$info" | grep -q '^Authority=Developer ID Application: ' \
	|| die "$target is not signed with a Developer ID Application certificate"
printf '%s\n' "$info" | grep -q '^Timestamp=' || die "$target has no secure timestamp (codesign --timestamp)"
if [ "$kind" = app ]; then
	codesign -d --verbose=1 "$target" 2>&1 | grep -q 'flags=.*runtime' \
		|| die "$target does not have the hardened runtime (codesign --options runtime)"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# notarytool takes a disk image as it is; an app goes up as a zip.
upload=$target
if [ "$kind" = app ]; then
	upload="$work/$(basename "$target" .app).zip"
	ditto -c -k --keepParent "$target" "$upload"
fi

echo "==> notarizing $(basename "$target") (profile $profile), usually a few minutes"
result="$work/result.json"
xcrun notarytool submit "$upload" --keychain-profile "$profile" --wait --output-format json >"$result" \
	|| { cat "$result" >&2; die "notarytool submit failed"; }
id=$(plutil -extract id raw -o - "$result" 2>/dev/null || true)
status=$(plutil -extract status raw -o - "$result" 2>/dev/null || true)
if [ "$status" != "Accepted" ]; then
	# The log names each file Apple rejected and why.
	[ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
	die "notarization of $target: ${status:-no status} (submission ${id:-unknown})"
fi
echo "==> notarized (submission $id)"

xcrun stapler staple "$target" >/dev/null || die "could not staple the ticket to $target"
xcrun stapler validate "$target" >/dev/null || die "the stapled ticket on $target does not validate"
# What Gatekeeper decides for a downloaded copy.
if [ "$kind" = app ]; then
	assess=$(spctl --assess --type execute -vv "$target" 2>&1 || true)
else
	assess=$(spctl --assess --type open --context context:primary-signature -vv "$target" 2>&1 || true)
fi
printf '%s\n' "$assess" | grep -q 'source=Notarized Developer ID' \
	|| die "Gatekeeper does not accept $target as Notarized Developer ID"
echo "==> stapled; Gatekeeper: Notarized Developer ID"
