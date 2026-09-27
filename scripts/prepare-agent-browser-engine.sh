#!/bin/bash
# Pinned, unmodified upstream engine; no npm, runtime install or latest lookup.
set -euo pipefail
ENGINE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_VERSION=0.38.1
ENGINE_SHA=2e61287259053ea964d39e77002c6a34af0e589e55ccff25e659efae7e892e0d
ENGINE_CACHE="$ENGINE_REPO/.build-local/agent-browser-engine/$ENGINE_VERSION"
ENGINE_OUT="$ENGINE_REPO/.build-local/agent-browser/Embedded/Resources/AgentBrowserEngine"
[[ "$(uname -m)" == arm64 ]] || { echo 'The pinned engine requires Apple Silicon.' >&2; exit 1; }
mkdir -p "$ENGINE_CACHE" "$ENGINE_OUT"
if [[ ! -f "$ENGINE_CACHE/agent-browser" ]]; then
  curl --fail --location --retry 2 --connect-timeout 15 --max-time 180 \
    "https://github.com/vercel-labs/agent-browser/releases/download/v$ENGINE_VERSION/agent-browser-darwin-arm64" \
    -o "$ENGINE_CACHE/agent-browser.part"
  [[ "$(shasum -a 256 "$ENGINE_CACHE/agent-browser.part" | awk '{print $1}')" == "$ENGINE_SHA" ]] || { echo 'Engine checksum mismatch.' >&2; exit 1; }
  mv "$ENGINE_CACHE/agent-browser.part" "$ENGINE_CACHE/agent-browser"
fi
[[ "$(shasum -a 256 "$ENGINE_CACHE/agent-browser" | awk '{print $1}')" == "$ENGINE_SHA" ]] || { echo 'Cached engine checksum mismatch.' >&2; exit 1; }
cp "$ENGINE_CACHE/agent-browser" "$ENGINE_OUT/agent-browser"
chmod 755 "$ENGINE_OUT/agent-browser"
cp "$ENGINE_REPO/CtrlxPackage/AgentBrowser/ThirdParty/agent-browser-LICENSE.txt" "$ENGINE_OUT/LICENSE.txt"
printf 'Prepared agent-browser %s (verified SHA-256).\n' "$ENGINE_VERSION"
