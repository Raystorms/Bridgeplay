#!/bin/sh
# The bridge build's cache key, shared by build-local.sh and worktree-seed.sh.
#   scripts/bridge-key.sh            a hash of the sources app.yml keys its bridge cache on
#                                    (bridge/, lsteamclient/, steam-shim/), uncommitted edits included
#   scripts/bridge-key.sh --outputs  the bridge outputs, the paths app.yml's bridge cache saves
set -eu
cd "$(dirname "$0")/.."

if [ "${1:-}" = --outputs ]; then
	cat <<'EOF'
scratch/wine-build-dual/programs/steam.exe/x86_64-windows/steam.exe
scratch/wine-build-dual/dlls/lsteamclient/x86_64-windows/lsteamclient.dll
scratch/wine-build-dual/dlls/lsteamclient/lsteamclient.so
scratch/wine-build-dual/dlls/lsteamclient/i386-windows/lsteamclient.dll
scratch/wine-build-arm64/dlls/lsteamclient/lsteamclient.so
EOF
	exit 0
fi

git ls-files -co --exclude-standard -z bridge lsteamclient steam-shim \
	| xargs -0 shasum -a 256 2>/dev/null | shasum -a 256 | cut -c1-16
