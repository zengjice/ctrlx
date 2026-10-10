#!/bin/bash
# Build a disposable compatibility app. Never install or launch the source app.
set -euo pipefail
PROBE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PROBE_SOURCE="${1:?Usage: bash prepare_upstream_probe.sh /path/to/current/CtrlX.app}"
PROBE_SDK="$PROBE_REPO/.build-local/cef-browser-probe/sdk/cef_binary_152.0.8+g1ce985c+chromium-152.0.7977.134_macosarm64_minimal"
PROBE_WRAPPER="$PROBE_REPO/.build-local/agent-browser/libcef_dll_wrapper/libcef_dll_wrapper.a"
PROBE_SHA='2e61287259053ea964d39e77002c6a34af0e589e55ccff25e659efae7e892e0d'
[[ "$(uname -m)" == arm64 ]] || { echo 'Apple Silicon required.' >&2; exit 1; }
[[ -f "$PROBE_SOURCE/Contents/MacOS/CtrlX" && -f "$PROBE_SOURCE/Contents/Frameworks/libCtrlXAgentBrowser.dylib" ]] || {
  echo 'A current embedded-browser CtrlX build is required.' >&2; exit 1;
}
[[ -f "$PROBE_SDK/include/cef_version.h" && -f "$PROBE_WRAPPER" ]] || {
  echo 'Build the matching CEF runtime with scripts/build-agent-browser.sh first.' >&2; exit 1;
}
PROBE_IDENTITY="${CTRLX_AGENT_BROWSER_SIGN_IDENTITY:-}"
if [[ -z "$PROBE_IDENTITY" ]]; then
  PROBE_IDENTITY="$(security find-identity -v -p codesigning | awk '/"Apple Development:/{print $2; exit}')"
fi
[[ -n "$PROBE_IDENTITY" ]] || { echo 'Apple Development signing identity required.' >&2; exit 1; }
mkdir -p "$PROBE_REPO/.build-local"
PROBE_BUILD="$(mktemp -d "$PROBE_REPO/.build-local/upstream-browser-proof.XXXXXX")"
# APFS clone avoids duplicating the large CEF framework. Failure is explicit;
# do not fall back to changing the installed application or downloading Chrome.
cp -cR "$PROBE_SOURCE" "$PROBE_BUILD/CtrlX.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.ctrlx.embedded-acceptance' "$PROBE_BUILD/CtrlX.app/Contents/Info.plist"
curl --fail --location --retry 2 --connect-timeout 15 --max-time 180 \
  'https://github.com/vercel-labs/agent-browser/releases/download/v0.38.1/agent-browser-darwin-arm64' \
  -o "$PROBE_BUILD/agent-browser"
[[ "$(shasum -a 256 "$PROBE_BUILD/agent-browser" | awk '{print $1}')" == "$PROBE_SHA" ]] || {
  echo 'Upstream checksum mismatch; refusing to execute.' >&2; exit 1;
}
chmod u+x "$PROBE_BUILD/agent-browser"
clang++ -std=c++20 "$PROBE_REPO/CtrlxPackage/AgentBrowser/tests/identity.cc" -o "$PROBE_BUILD/identity"
# The long-lived CLI fixture tolerates terminal focus/resize input during setup.
clang++ -std=c++20 "$PROBE_REPO/CtrlxPackage/AgentBrowser/tests/engine_identity.cc" -o "$PROBE_BUILD/codex"
clang++ -std=c++20 -O1 -fobjc-arc -fPIC -arch arm64 -mmacosx-version-min=12.0 \
  -DCTRLX_UPSTREAM_BROWSER_PROBE=1 -dynamiclib -I "$PROBE_SDK" \
  "$PROBE_REPO/CtrlxPackage/AgentBrowser/EmbeddedBrowser.mm" \
  "$PROBE_REPO/CtrlxPackage/AgentBrowser/AutomationBridge.mm" \
  "$PROBE_WRAPPER" -lpthread -framework AppKit -framework Cocoa -framework IOSurface -framework ImageIO -framework CoreGraphics \
  -install_name @rpath/libCtrlXAgentBrowser.dylib \
  -o "$PROBE_BUILD/CtrlX.app/Contents/Frameworks/libCtrlXAgentBrowser.dylib"
codesign --force --sign "$PROBE_IDENTITY" "$PROBE_BUILD/CtrlX.app/Contents/Frameworks/libCtrlXAgentBrowser.dylib"
# Compile-only workspace builds can carry stale signatures on copied package
# frameworks. Sign this disposable app's nested code too, never the source app.
codesign --force --deep --sign "$PROBE_IDENTITY" "$PROBE_BUILD/CtrlX.app"
codesign --verify --deep --strict "$PROBE_BUILD/CtrlX.app"
printf 'Prepared isolated fixture: %s\n' "$PROBE_BUILD"
printf 'Run: python3 -u %q %q %q %q\n' \
  "$PROBE_REPO/CtrlxPackage/AgentBrowser/tests/upstream_probe.py" \
  "$PROBE_BUILD/CtrlX.app" "$PROBE_BUILD/agent-browser" "$PROBE_BUILD/identity"
