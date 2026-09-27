#!/bin/bash
# Independent macOS/arm64 experiment. Never changes CtrlX, Chrome, or Codex config.
set -euo pipefail
PROBE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_SOURCE="$PROBE_REPO/experiments/cef-browser-probe"
PROBE_ROOT="$PROBE_REPO/.build-local/cef-browser-probe"
CEF_VERSION='152.0.8+g1ce985c+chromium-152.0.7977.134'
CEF_ARCHIVE="cef_binary_${CEF_VERSION}_macosarm64_minimal.tar.bz2"
CEF_SHA256='3bb9859cb8d3ea60b542023cdd75d10c037fbe21fd544dc6ccb790ad22d1759e'
CEF_SDK="$PROBE_ROOT/sdk/${CEF_ARCHIVE%.tar.bz2}"
PROBE_BUILD_NAME="${CEF_PROBE_BUILD_NAME:-build}"
case "$PROBE_BUILD_NAME" in build|build-cdp) ;; *) echo 'Unsupported probe build directory' >&2; exit 2 ;; esac
PROBE_APP="$PROBE_ROOT/$PROBE_BUILD_NAME/CtrlX Browser Probe.app"

case "${1:-help}" in
  build)
    [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
      echo 'This pinned experiment currently supports Apple Silicon macOS only.' >&2; exit 1;
    }
    command -v cmake >/dev/null || { echo 'CMake is required.' >&2; exit 1; }
    mkdir -p "$PROBE_ROOT/downloads" "$PROBE_ROOT/sdk"
    archive="$PROBE_ROOT/downloads/$CEF_ARCHIVE"
    if [[ ! -f "$archive" ]]; then
      # Only reuse a partial download if its complete pinned checksum matches.
      if [[ ! -f "$archive.part" ]] || [[ "$(shasum -a 256 "$archive.part" | awk '{print $1}')" != "$CEF_SHA256" ]]; then
        curl --fail --location --retry 2 --connect-timeout 15 --max-time 600 \
          --output "$archive.part" "https://cef-builds.spotifycdn.com/${CEF_ARCHIVE//+/%2B}"
      fi
      [[ "$(shasum -a 256 "$archive.part" | awk '{print $1}')" == "$CEF_SHA256" ]] || {
        echo 'CEF download checksum mismatch. Not extracting or executing it.' >&2; exit 1;
      }
      mv "$archive.part" "$archive"
    fi
    [[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == "$CEF_SHA256" ]] || {
      echo 'CEF archive checksum mismatch.' >&2; exit 1;
    }
    if [[ ! -f "$CEF_SDK/include/cef_version.h" ]]; then
      tar -xjf "$archive" -C "$PROBE_ROOT/sdk"
    fi
    cmake -S "$PROBE_SOURCE" -B "$PROBE_ROOT/$PROBE_BUILD_NAME" -G 'Unix Makefiles' \
      -DCEF_ROOT="$CEF_SDK" -DPROJECT_ARCH=arm64 -DCMAKE_BUILD_TYPE=Release
    cmake --build "$PROBE_ROOT/$PROBE_BUILD_NAME" --parallel 4
    # Chromium reserializes the cached Info.plist for dynamic peer validation.
    # Normalize generated plists with Apple's serializer before signing.
    plutil -convert xml1 "$PROBE_APP/Contents/Info.plist"
    for helper_plist in "$PROBE_APP"/Contents/Frameworks/*Helper*.app/Contents/Info.plist; do
      plutil -convert xml1 "$helper_plist"
    done
    # Use an installed development identity for the isolated local build.
    # A valid on-disk signature alone does not prove Chromium IPC works.
    # Never bake a personal certificate into Git.
    identity="${CEF_PROBE_SIGN_IDENTITY:-}"
    if [[ -z "$identity" ]]; then
      identity="$(security find-identity -v -p codesigning | awk '/"Apple Development:/{print $2; exit}')"
    fi
    [[ -n "$identity" ]] || {
      echo 'Set CEF_PROBE_SIGN_IDENTITY to an installed development signing identity.' >&2; exit 1;
    }
    codesign --force --deep --sign "$identity" "$PROBE_APP"
    codesign --verify --deep --strict "$PROBE_APP"
    printf 'Built (not installed): %s\n' "$PROBE_APP"
    ;;
  serve)
    exec python3 -m http.server 8769 --bind 127.0.0.1 --directory "$PROBE_SOURCE/fixture"
    ;;
  smoke|smoke-control|smoke-cdp)
    [[ -x "$PROBE_APP/Contents/MacOS/CtrlX Browser Probe" ]] || {
      echo 'Build the probe first.' >&2; exit 1;
    }
    # Exact fixture check prevents an unrelated localhost service producing a false pass.
    curl --fail --silent --show-error --max-time 5 http://127.0.0.1:8769/index.html \
      | cmp - "$PROBE_SOURCE/fixture/index.html" || {
        echo 'Start the dedicated fixture with: scripts/cef-browser-probe.sh serve' >&2; exit 1;
      }
    if [[ "$1" == smoke-cdp ]]; then
      python3 "$PROBE_SOURCE/test_cdp_integration.py" "$PROBE_APP/Contents/MacOS/CtrlX Browser Probe"
    elif [[ "$1" == smoke-control ]]; then
      python3 "$PROBE_SOURCE/smoke.py" "$PROBE_APP/Contents/MacOS/CtrlX Browser Probe" --chrome-control
    else
      python3 "$PROBE_SOURCE/smoke.py" "$PROBE_APP/Contents/MacOS/CtrlX Browser Probe"
    fi
    ;;
  path)
    printf '%s\n' "$PROBE_APP"
    ;;
  help|--help|-h)
    printf '%s\n' 'Usage: scripts/cef-browser-probe.sh build|serve|smoke|smoke-control|smoke-cdp|path' \
      'build: download pinned CEF and build the isolated Mac app (about 1 GB including intermediates).' \
      'serve: serve only the non-sensitive fixture on 127.0.0.1:8769; Ctrl+C stops it.' \
      'smoke: check real NSView embedding, sandboxed startup, HTTP load and graceful shutdown.' \
      'smoke-control: compare a separate CEF Chrome-style window; NOT embedded-browser proof.' \
      'smoke-cdp: verify local CLI/internal CDP against two embedded fixture pages; no extension.' \
      'CEF_PROBE_BUILD_NAME=build-cdp: separate build output, leaving the older probe binary intact.' \
      'Open the built app manually. Extension installation/permissions remain manual.'
    ;;
  *) echo "Unknown command: $1" >&2; exit 2 ;;
esac
