#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_ROOT/Config/Shared-Base.xcconfig"
WORKSPACE="$PROJECT_ROOT/Ctrlx.xcworkspace"
SCHEME="CtrlxServer"
EXPORT_OPTIONS="$SCRIPT_DIR/export-options.plist"

# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"
load_project_environment "$PROJECT_ROOT"

[ "$#" -eq 0 ] || log_error "CtrlX release is zero-parameter; edit the selected .env file instead."
assert_git_worktree

require_config() {
    local name="$1"
    [ -n "${!name:-}" ] || log_error "Missing $name in ${CTRLX_ENV_FILE:-the selected environment file}."
}

require_config CTRLX_MAC_DEVELOPMENT_TEAM
require_config CTRLX_MAC_SIGNING_IDENTITY
require_config CTRLX_NOTARYTOOL_PROFILE
require_config CTRLX_DOWNLOAD_URL_PREFIX

command -v sign_update >/dev/null \
    || log_error "Sparkle sign_update is required. Install Sparkle's command-line tools first."

if [ -n "$(git -C "$PROJECT_ROOT" status --porcelain)" ]; then
    log_error "Release requires a clean worktree."
fi

VERSION="$(get_version)"
BUILD_NUMBER="$(get_build_number)"
BUILD_STAMP="$(get_build_stamp)"
SOURCE_REVISION="$(get_full_source_revision)"
EXPECTED_TAG="v$VERSION"
TAG_COMMIT="$(git -C "$PROJECT_ROOT" rev-list -n 1 "$EXPECTED_TAG" 2>/dev/null || true)"
[ "$TAG_COMMIT" = "$SOURCE_REVISION" ] \
    || log_error "Tag $EXPECTED_TAG must point at the exact release commit $SOURCE_REVISION."

DIST_DIR="$PROJECT_ROOT/dist"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ctrlx-release.XXXXXX")"
DERIVED_DATA="$WORK_ROOT/DerivedData"
SOURCE_PACKAGES="$PROJECT_ROOT/.build-local/SourcePackages"
ARCHIVE_PATH="$WORK_ROOT/CtrlX.xcarchive"
EXPORT_PATH="$WORK_ROOT/export"
PACKAGE_ROOT="$WORK_ROOT/package"
APP_PATH="$EXPORT_PATH/CtrlX.app"
DMG_PATH="$DIST_DIR/CtrlX-$VERSION.dmg"
APPCAST_PATH="$DIST_DIR/CtrlX.xml"

cleanup_release_workspace() {
    [ ! -d "$WORK_ROOT" ] || /bin/rm -rf -- "$WORK_ROOT"
}
trap cleanup_release_workspace EXIT

mkdir -p "$DIST_DIR" "$SOURCE_PACKAGES" "$PACKAGE_ROOT/root"
if [ -e "$DMG_PATH" ]; then
    mv "$DMG_PATH" "$DMG_PATH.previous"
fi
if [ -e "$APPCAST_PATH" ]; then
    mv "$APPCAST_PATH" "$APPCAST_PATH.previous"
fi

log_info "Archiving CtrlX $VERSION ($SOURCE_REVISION)"
xcodebuild archive \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipMacroValidation \
    -skipPackagePluginValidation \
    COMPILER_INDEX_STORE_ENABLE=NO \
    INDEX_ENABLE_DATA_STORE=NO \
    CTRLX_BUILD_STAMP="$BUILD_STAMP" \
    CTRLX_SOURCE_REVISION="$SOURCE_REVISION" \
    DEVELOPMENT_TEAM="$CTRLX_MAC_DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$CTRLX_MAC_SIGNING_IDENTITY"

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_PATH" \
    DEVELOPMENT_TEAM="$CTRLX_MAC_DEVELOPMENT_TEAM"

[ -d "$APP_PATH" ] || log_error "Archive export did not produce $APP_PATH."
codesign --verify --deep --strict "$APP_PATH" \
    || log_error "Exported CtrlX.app signature is invalid."

ditto -c -k --keepParent "$APP_PATH" "$WORK_ROOT/CtrlX-notary.zip"
xcrun notarytool submit "$WORK_ROOT/CtrlX-notary.zip" \
    --keychain-profile "$CTRLX_NOTARYTOOL_PROFILE" \
    --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

ditto "$APP_PATH" "$PACKAGE_ROOT/root/CtrlX.app"
ln -s /Applications "$PACKAGE_ROOT/root/Applications"
hdiutil create \
    -volname CtrlX \
    -srcfolder "$PACKAGE_ROOT/root" \
    -format UDZO \
    -ov \
    "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$CTRLX_NOTARYTOOL_PROFILE" \
    --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
hdiutil verify "$DMG_PATH" >/dev/null

signature_output="$(sign_update "$DMG_PATH")"
signature="$(printf '%s' "$signature_output" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
[ -n "$signature" ] || log_error "Could not read Sparkle signature from sign_update output."

download_url="${CTRLX_DOWNLOAD_URL_PREFIX%/}/$(basename "$DMG_PATH")"
artifact_size="$(stat -f '%z' "$DMG_PATH")"
release_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S %z')"

CTRLX_APPCAST_PATH="$APPCAST_PATH" \
CTRLX_VERSION="$VERSION" \
CTRLX_BUILD_NUMBER="$BUILD_NUMBER" \
CTRLX_DOWNLOAD_URL="$download_url" \
CTRLX_ARTIFACT_SIZE="$artifact_size" \
CTRLX_SPARKLE_SIGNATURE="$signature" \
CTRLX_RELEASE_DATE="$release_date" \
CTRLX_SOURCE_URL="https://github.com/jicezeng/CtrlX/tree/$SOURCE_REVISION" \
    python3 - <<'PY'
import html
import os
from pathlib import Path

values = {key: html.escape(value, quote=True) for key, value in os.environ.items() if key.startswith("CTRLX_")}
xml = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>CtrlX Updates</title>
    <item>
      <title>CtrlX {values["CTRLX_VERSION"]}</title>
      <pubDate>{values["CTRLX_RELEASE_DATE"]}</pubDate>
      <link>{values["CTRLX_SOURCE_URL"]}</link>
      <enclosure url="{values["CTRLX_DOWNLOAD_URL"]}"
                 length="{values["CTRLX_ARTIFACT_SIZE"]}"
                 type="application/octet-stream"
                 sparkle:version="{values["CTRLX_BUILD_NUMBER"]}"
                 sparkle:shortVersionString="{values["CTRLX_VERSION"]}"
                 sparkle:edSignature="{values["CTRLX_SPARKLE_SIGNATURE"]}" />
    </item>
  </channel>
</rss>
'''
Path(os.environ["CTRLX_APPCAST_PATH"]).write_text(xml, encoding="utf-8")
PY

write_artifact_metadata "$DMG_PATH"
prune_local_artifacts "$DMG_PATH"
log_success "Release artifact: $DMG_PATH"
log_success "Appcast: $APPCAST_PATH"
log_success "Corresponding source: https://github.com/jicezeng/CtrlX/tree/$SOURCE_REVISION"
