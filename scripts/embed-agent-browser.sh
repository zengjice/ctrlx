#!/bin/bash
# Xcode macOS-only build phase. Packaging builds the pinned embedded runtime first.
set -euo pipefail
AB_SOURCE="${SRCROOT}/.build-local/agent-browser/Embedded"
AB_DEST="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}"
if [[ ! -d "$AB_SOURCE" ]]; then
  if [[ -e "$AB_DEST/Frameworks/libCtrlXAgentBrowser.dylib" ]]; then
    echo 'error: Stale Agent Browser in build output; rebuild the runtime first.' >&2
    exit 1
  fi
  echo 'warning: Agent Browser not built. Run bash scripts/build-agent-browser.sh to enable embedded Chromium tabs.'
  exit 0
fi
if [[ "${ACTION:-}" == install ]]; then
  echo 'error: Agent Browser is development-only pending embedded-runtime acceptance and hardened-runtime/notarization validation. Do not archive this runtime yet.' >&2
  exit 1
fi
for ab_component in "$AB_SOURCE"/Frameworks/*; do
  codesign --verify --deep --strict "$ab_component"
done
mkdir -p "$AB_DEST/Frameworks" "$AB_DEST/Resources"
ditto "$AB_SOURCE/Frameworks" "$AB_DEST/Frameworks"
ditto "$AB_SOURCE/Resources" "$AB_DEST/Resources"
# Recoverably remove the obsolete companion from incremental build output;
# otherwise the packaged app would still contain the old launchable UI.
AB_OLD="$AB_DEST/Helpers/CtrlX Agent Browser.app"
if [[ -d "$AB_OLD" ]]; then
  AB_RETIRED="$(mktemp -d "${SRCROOT}/.build-local/retired-browser.XXXXXX")"
  mv "$AB_OLD" "$AB_RETIRED/"
fi
