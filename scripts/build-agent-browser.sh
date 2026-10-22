#!/bin/bash
# Builds the embedded runtime and sandboxed helpers; never installs or starts CtrlX.
set -euo pipefail
AB_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$AB_REPO/scripts"
source "$SCRIPT_DIR/common.sh"
with_worktree_lock "$@"
AB_BUILD="$AB_REPO/.build-local/agent-browser"
AB_CACHE="$AB_REPO/.build-local/cef-browser-probe"
AB_VERSION='152.0.8+g1ce985c+chromium-152.0.7977.134'
AB_COMMIT='1ce985cb23056548b9cc51483bbef4faf68b1cd3'
AB_ARCHIVE="cef_binary_${AB_VERSION}_macosarm64_minimal.tar.bz2"
AB_SHA='3bb9859cb8d3ea60b542023cdd75d10c037fbe21fd544dc6ccb790ad22d1759e'
AB_SDK="$AB_CACHE/sdk/${AB_ARCHIVE%.tar.bz2}"
AB_OUTPUT="$AB_BUILD/Embedded"
[[ "$(uname -m)" == arm64 ]] || { echo 'Agent Browser currently requires Apple Silicon.' >&2; exit 1; }
command -v cmake >/dev/null || { echo 'CMake is required.' >&2; exit 1; }

AB_SDK_OVERRIDE="${CTRLX_CEF_SDK_ROOT:-}"
if [[ -z "$AB_SDK_OVERRIDE" && -f "$AB_REPO/Config/Local-macOS.xcconfig" ]]; then
  AB_SDK_OVERRIDE="$(read_xcconfig_value "$AB_REPO/Config/Local-macOS.xcconfig" CTRLX_CEF_SDK_ROOT)"
fi
if [[ -n "$AB_SDK_OVERRIDE" ]]; then
  [[ -d "$AB_SDK_OVERRIDE" ]] || { echo "CEF_SDK_ROOT is not a directory: $AB_SDK_OVERRIDE" >&2; exit 1; }
  AB_SDK="$(cd "$AB_SDK_OVERRIDE" && pwd -P)"
  for ab_required in \
    include/cef_version.h \
    cmake/FindCEF.cmake \
    libcef_dll/CMakeLists.txt \
    Release/'Chromium Embedded Framework.framework'/'Chromium Embedded Framework' \
    LICENSE.txt \
    CREDITS.html; do
    [[ -e "$AB_SDK/$ab_required" ]] || { echo "CEF SDK is missing $ab_required: $AB_SDK" >&2; exit 1; }
  done
  AB_SDK_VERSION="$(sed -n 's/^#define CEF_VERSION "\(.*\)"$/\1/p' "$AB_SDK/include/cef_version.h")"
  AB_SDK_COMMIT="$(sed -n 's/^#define CEF_COMMIT_HASH "\(.*\)"$/\1/p' "$AB_SDK/include/cef_version.h")"
  [[ "$AB_SDK_VERSION" == "$AB_VERSION" ]] || {
    echo "CEF SDK version mismatch: expected $AB_VERSION, found $AB_SDK_VERSION" >&2; exit 1;
  }
  [[ "$AB_SDK_COMMIT" == "$AB_COMMIT" ]] || {
    echo "CEF SDK commit mismatch: expected $AB_COMMIT, found $AB_SDK_COMMIT" >&2; exit 1;
  }
else
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
fi

AB_SDK_FRAMEWORK="$AB_SDK/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework"
AB_SDK_FRAMEWORK_SHA="$(shasum -a 256 "$AB_SDK_FRAMEWORK" | awk '{print $1}')"
AB_SDK_STAMP="$AB_BUILD/.cef-sdk-framework.sha256"
if [[ -d "$AB_BUILD" ]]; then
  [[ ! -L "$AB_BUILD" ]] || { echo "Refusing symlinked Agent Browser build directory: $AB_BUILD" >&2; exit 1; }
  if [[ ! -f "$AB_SDK_STAMP" || "$(<"$AB_SDK_STAMP")" != "$AB_SDK_FRAMEWORK_SHA" ]]; then
    rm -rf -- "$AB_BUILD"
  fi
fi
rm -f "$AB_SDK_STAMP"
printf 'CEF SDK: %s\nCEF framework SHA-256: %s\n' "$AB_SDK" "$AB_SDK_FRAMEWORK_SHA"

cmake -S "$AB_REPO/CtrlxPackage/AgentBrowser" -B "$AB_BUILD" -G 'Unix Makefiles' \
  -DCEF_ROOT="$AB_SDK" -DCMAKE_BUILD_TYPE=Release
cmake --build "$AB_BUILD" --parallel 4
AB_BUILT_FRAMEWORK="$AB_OUTPUT/Frameworks/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework"
AB_BUILT_FRAMEWORK_BUNDLE="$(dirname "$(dirname "$(dirname "$AB_BUILT_FRAMEWORK")")")"
# The upstream framework is linker-signed and fails strict bundle verification.
# A passing signature means this is the already-signed incremental output; a
# fresh or relinked copy must match the selected SDK's original binary.
if ! codesign --verify --deep --strict "$AB_BUILT_FRAMEWORK_BUNDLE" >/dev/null 2>&1; then
  [[ "$(shasum -a 256 "$AB_BUILT_FRAMEWORK" | awk '{print $1}')" == "$AB_SDK_FRAMEWORK_SHA" ]] || {
    echo 'Built Agent Browser framework does not match the selected CEF SDK.' >&2; exit 1;
  }
fi
printf '%s\n' "$AB_SDK_FRAMEWORK_SHA" > "$AB_SDK_STAMP"
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
