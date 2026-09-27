#!/bin/bash
# Builds the embedded runtime and sandboxed helpers; never installs or starts CtrlX.
set -euo pipefail
AB_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AB_BUILD="$AB_REPO/.build-local/agent-browser"
AB_CACHE="$AB_REPO/.build-local/cef-browser-probe"
AB_VERSION='152.0.8+g1ce985c+chromium-152.0.7977.134'
AB_ARCHIVE="cef_binary_${AB_VERSION}_macosarm64_minimal.tar.bz2"
AB_SHA='3bb9859cb8d3ea60b542023cdd75d10c037fbe21fd544dc6ccb790ad22d1759e'
AB_SDK="$AB_CACHE/sdk/${AB_ARCHIVE%.tar.bz2}"
AB_OUTPUT="$AB_BUILD/Embedded"
[[ "$(uname -m)" == arm64 ]] || { echo 'Agent Browser currently requires Apple Silicon.' >&2; exit 1; }
command -v cmake >/dev/null || { echo 'CMake is required.' >&2; exit 1; }
mkdir -p "$AB_CACHE/downloads" "$AB_CACHE/sdk"
if [[ ! -f "$AB_CACHE/downloads/$AB_ARCHIVE" ]]; then
  curl --fail --location --retry 2 --connect-timeout 15 --max-time 600 \
    -o "$AB_CACHE/downloads/$AB_ARCHIVE.part" "https://cef-builds.spotifycdn.com/${AB_ARCHIVE//+/%2B}"
  [[ "$(shasum -a 256 "$AB_CACHE/downloads/$AB_ARCHIVE.part" | awk '{print $1}')" == "$AB_SHA" ]] || exit 1
  mv "$AB_CACHE/downloads/$AB_ARCHIVE.part" "$AB_CACHE/downloads/$AB_ARCHIVE"
fi
[[ "$(shasum -a 256 "$AB_CACHE/downloads/$AB_ARCHIVE" | awk '{print $1}')" == "$AB_SHA" ]] || { echo 'CEF checksum mismatch.' >&2; exit 1; }
if [[ ! -f "$AB_SDK/include/cef_version.h" ]]; then
  tar -xjf "$AB_CACHE/downloads/$AB_ARCHIVE" -C "$AB_CACHE/sdk"
fi
cmake -S "$AB_REPO/CtrlxPackage/AgentBrowser" -B "$AB_BUILD" -G 'Unix Makefiles' \
  -DCEF_ROOT="$AB_SDK" -DCMAKE_BUILD_TYPE=Release
cmake --build "$AB_BUILD" --parallel 4
for ab_plist in "$AB_OUTPUT"/Frameworks/*Helper*.app/Contents/Info.plist; do
  plutil -convert xml1 "$ab_plist"
done
AB_IDENTITY="${CTRLX_AGENT_BROWSER_SIGN_IDENTITY:-${EXPANDED_CODE_SIGN_IDENTITY:-}}"
if [[ -z "$AB_IDENTITY" ]]; then
  AB_IDENTITY="$(security find-identity -v -p codesigning | awk '/"Apple Development:/{print $2; exit}')"
fi
[[ -n "$AB_IDENTITY" ]] || { echo 'No signing identity for Agent Browser.' >&2; exit 1; }
# Local validation first. Hardened-runtime/notarization must also be verified
# before distributing the runtime; the embedding phase rejects archives.
for ab_component in "$AB_OUTPUT"/Frameworks/*; do
  codesign --force --deep --sign "$AB_IDENTITY" "$ab_component"
  codesign --verify --deep --strict "$ab_component"
done
bash "$AB_REPO/scripts/prepare-agent-browser-engine.sh"
printf 'Built: %s\n' "$AB_OUTPUT"
