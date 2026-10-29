#!/bin/sh
# Seed a fresh git worktree with another checkout's build caches, so its first
# scripts/build-local.sh takes about a minute instead of about 15.
#
#   scripts/worktree-seed.sh [SOURCE]   SOURCE defaults to the main worktree
#
# Copies are APFS clones (cp -c): instant and no extra disk; other volumes get a plain copy.
# Only caches that don't record their checkout's path come over. The Wine build trees do
# (srcdir = <repo>/scratch/wine), so the bridge comes over as its outputs, and only when
# both checkouts have the same bridge sources. Otherwise the Wine source comes over, and
# build-local.sh builds the bridge here without cloning Wine. Nothing in SOURCE is written.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
src=${1:-$(git -C "$repo" worktree list --porcelain | sed -n '1s/^worktree //p')}
src=$(cd "$src" && pwd)
[ "$src" != "$repo" ] || { echo "==> seed: this is the source checkout; run it in another worktree" >&2; exit 1; }
cd "$repo"
echo "==> seeding $repo from $src"

# clone PATH: from SOURCE, unless it is already here or SOURCE has none
clone() {
	if [ -e "$1" ] || [ -L "$1" ]; then echo "    $1: already here"; return 0; fi
	if [ ! -e "$src/$1" ]; then echo "    $1: not in the source"; return 0; fi
	mkdir -p "$(dirname "$1")"
	cp -c -R "$src/$1" "$1" 2>/dev/null || { rm -rf "$1"; cp -R "$src/$1" "$1"; }
	echo "    $1"
}

clone vendor/dobby
clone build/dobby
clone build/fonts
clone build/fonts.stamp
clone scratch/proton-lsc

# The font venv's scripts name its path, so it is shared, not copied, while both checkouts
# want the same tools; build-local.sh replaces the link with its own venv when they don't.
tools=$(sed -n 's/^ *FONT_TOOLS: "\(.*\)"$/\1/p' .github/workflows/app.yml)
if [ ! -e scratch/fontvenv ] && [ -n "$tools" ] && [ "$(cat "$src/scratch/fontvenv/.tools" 2>/dev/null)" = "$tools" ]; then
	mkdir -p scratch
	ln -s "$src/scratch/fontvenv" scratch/fontvenv
	echo "    scratch/fontvenv (link)"
fi

key=$(sh scripts/bridge-key.sh)
if [ "$(cat "$src/scratch/.bridge-key" 2>/dev/null)" = "$key" ] && [ "$(sh "$src/scripts/bridge-key.sh")" = "$key" ]; then
	for f in $(sh scripts/bridge-key.sh --outputs); do clone "$f"; done
	echo "$key" >scratch/.bridge-key
	echo "==> bridge: same sources as the source checkout, its build is reused"
else
	clone scratch/wine
	clone scratch/.wine-key
	echo "==> bridge: sources differ from the source checkout's last bridge build;"
	echo "    build-local.sh builds it here from the cloned Wine source"
fi
