#!/bin/bash
# Build a disposable signed experiment using the pinned probe's SDK/helpers.
set -euo pipefail
PROBE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$PROBE_REPO/scripts"
source "$SCRIPT_DIR/common.sh"
with_worktree_lock "$@"
PROBE_ROOT="$PROBE_REPO/.build-local/cef-browser-probe"
PROBE_SDK="$PROBE_ROOT/sdk/cef_binary_152.0.8+g1ce985c+chromium-152.0.7977.134_macosarm64_minimal"
PROBE_BASE="$PROBE_ROOT/build/CtrlX Browser Probe.app"
PROBE_WRAPPER="$PROBE_ROOT/build/libcef_dll_wrapper/libcef_dll_wrapper.a"
[[ -f "$PROBE_WRAPPER" && -x "$PROBE_BASE/Contents/MacOS/CtrlX Browser Probe" ]] || {
  echo 'Build the pinned isolated app first: bash scripts/cef-browser-probe.sh build' >&2; exit 1;
}
PROBE_IDENTITY="${CEF_PROBE_SIGN_IDENTITY:-}"
if [[ -z "$PROBE_IDENTITY" ]]; then
  PROBE_IDENTITY="$(security find-identity -v -p codesigning | awk '/"Apple Development:/{print $2; exit}')"
fi
[[ -n "$PROBE_IDENTITY" ]] || { echo 'An installed development signing identity is required.' >&2; exit 1; }
PROBE_OUTPUT="$(mktemp -d "$PROBE_REPO/.build-local/upstream-browser-proof.XXXXXX")"
PROBE_APP="$PROBE_OUTPUT/CtrlX Browser Probe.app"
cp -cR "$PROBE_BASE" "$PROBE_APP"
clang++ -std=c++20 -O1 -fobjc-arc -arch arm64 -mmacosx-version-min=12.0 \
  -I "$PROBE_SDK" "$PROBE_REPO/experiments/cef-browser-probe/ExtensionProbe.mm" \
  "$PROBE_WRAPPER" -lpthread -framework AppKit -framework Cocoa -framework IOSurface -framework ScreenCaptureKit \
  -o "$PROBE_APP/Contents/MacOS/CtrlX Browser Probe"
codesign --force --deep --sign "$PROBE_IDENTITY" "$PROBE_APP"
codesign --verify --deep --strict "$PROBE_APP"
printf 'Prepared isolated extension probe: %s\n' "$PROBE_OUTPUT"
printf 'Run: python3 %q use-artifact --path %q -- python3 -u %q %q\n' \
  "$PROBE_REPO/scripts/clean-build.py" "$PROBE_OUTPUT" \
  "$PROBE_REPO/experiments/cef-browser-probe/test_extensions.py" "$PROBE_APP"
