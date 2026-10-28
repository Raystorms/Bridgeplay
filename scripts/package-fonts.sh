#!/bin/sh
# Pack the Chinese, Japanese and Korean fonts (Makefile CJK_FONTS, built by `make fonts`)
# with their licences into out/fonts-cjk-<id>.tar.xz, the archive CJKFonts.swift downloads.
# The same fonts always give the same archive and the same id.
#
#   scripts/package-fonts.sh            pack, then print the pins for CJKFonts.swift
#   scripts/package-fonts.sh --publish  also create the fonts-cjk-<id> release that hosts it
#
# Only needed when the fonts change; app releases reuse the published archive.

set -eu

die() { echo "==> $*" >&2; exit 1; }

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
publish=0
case "${1:-}" in
	--publish) publish=1 ;;
	"") ;;
	*) die "usage: $0 [--publish]" ;;
esac

fonts=$(sed -n 's/^CJK_FONTS := //p' Makefile)
[ -n "$fonts" ] || die "no CJK_FONTS in the Makefile"
# msyh, msyhbd, simsun and malgun are built from Source Han Sans, msgothic from Ume.
licences="source-han-sans/LICENSE.txt ume/license.html"
for f in $fonts $licences; do
	[ -f "build/fonts/$f" ] || die "missing build/fonts/$f, run: make fonts"
done

# The id names the fonts, not the archive, so it only changes when a font does.
id=$(for f in $fonts; do shasum -a 256 "build/fonts/$f" | cut -d' ' -f1; done | shasum -a 256 | cut -c1-12)
name=fonts-cjk-$id
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/stage"
for f in $fonts $licences; do
	mkdir -p "$work/stage/$(dirname "$f")"
	cp "build/fonts/$f" "$work/stage/$f"
done
# Fixed modes, times and owners, entries in sorted order: a reproducible tarball.
find "$work/stage" -type d -exec chmod 755 {} + -o -type f -exec chmod 644 {} +
find "$work/stage" -exec touch -h -t 202601010000 {} +
(cd "$work/stage" && find . -type f | LC_ALL=C sort) >"$work/list"
mkdir -p out
archive=out/$name.tar.xz
(cd "$work/stage" && tar --uid 0 --gid 0 --uname root --gname wheel --no-xattrs --no-mac-metadata \
	-cf - -T "$work/list") | xz -9e -T1 >"$archive"
sha=$(shasum -a 256 "$archive" | cut -d' ' -f1)
echo "==> $archive ($(du -h "$archive" | cut -f1 | tr -d ' ')), sha256 $sha"

echo "==> pins for app/Sources/BridgeplayApp/Model/CJKFonts.swift:"
echo "    static let archive = \"$name.tar.xz\""
echo "    static let sha256 = \"$sha\""
echo "    release tag: $name"
for f in $fonts; do
	echo "    \"$f\": \"$(shasum -a 256 "build/fonts/$f" | cut -d' ' -f1)\","
done

[ "$publish" -eq 1 ] || exit 0
slug=raymondchins/Bridgeplay
if gh release view "$name" -R "$slug" >/dev/null 2>&1; then
	echo "==> $name is already published"
	exit 0
fi
gh release create "$name" "$archive" -R "$slug" --prerelease --latest=false \
	--title "CJK fonts $id" \
	--notes "Chinese, Japanese and Korean fonts that Bridgeplay downloads during setup (Source Han Sans and Ume, licences inside). Built by fonts/build.sh, packed by scripts/package-fonts.sh."
echo "==> published https://github.com/$slug/releases/tag/$name"
