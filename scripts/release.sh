#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_ROOT/Config/Shared-Base.xcconfig"
WORKSPACE="$PROJECT_ROOT/Ctrlx.xcworkspace"
SCHEME="CtrlxServer"

# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"
load_project_environment "$PROJECT_ROOT"

[ "$#" -eq 0 ] || log_error "CtrlX release is zero-parameter; edit the selected .env file instead."
assert_git_worktree
with_worktree_lock "$@"

require_config() {
    local name="$1"
    [ -n "${!name:-}" ] || log_error "Missing $name in ${CTRLX_ENV_FILE:-the selected environment file}."
}

require_config CTRLX_MAC_DEVELOPMENT_TEAM
require_config CTRLX_MAC_SIGNING_IDENTITY
require_config CTRLX_NOTARYTOOL_PROFILE
require_config CTRLX_DOWNLOAD_URL_PREFIX

SIGN_UPDATE="$PROJECT_ROOT/.build-local/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "$SIGN_UPDATE" ] || SIGN_UPDATE="$(command -v sign_update || true)"
[ -x "$SIGN_UPDATE" ] || log_error 'Sparkle sign_update is unavailable.'
case "$CTRLX_MAC_SIGNING_IDENTITY" in
    'Developer ID Application: '*) ;;
    *) log_error 'Formal releases require a Developer ID Application identity.' ;;
esac
security find-identity -v -p codesigning | grep -F "\"$CTRLX_MAC_SIGNING_IDENTITY\"" >/dev/null \
    || log_error 'The configured Developer ID identity and private key are unavailable.'
# Fail before compiling if authentication is missing. Passwords stay in Keychain.
xcrun notarytool history --keychain-profile "$CTRLX_NOTARYTOOL_PROFILE" --output-format json >/dev/null

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
check_build_space "$PROJECT_ROOT"
check_build_space "${TMPDIR:-/tmp}"
mkdir -p "$PROJECT_ROOT/.build-local"
WORK_ROOT="$(mktemp -d "$PROJECT_ROOT/.build-local/package-macos.XXXXXX")"
DERIVED_DATA="$PROJECT_ROOT/.build-local/DerivedData/macOS"
SOURCE_PACKAGES="$PROJECT_ROOT/.build-local/SourcePackages"
ARCHIVE_PATH="$WORK_ROOT/CtrlX.xcarchive"
EXPORT_PATH="$WORK_ROOT/export"
PACKAGE_ROOT="$WORK_ROOT/package"
APP_PATH="$EXPORT_PATH/CtrlX.app"
DMG_PATH="$DIST_DIR/CtrlX-$VERSION.dmg"
STAGED_DMG="$WORK_ROOT/$(basename "$DMG_PATH")"
APPCAST_PATH="$DIST_DIR/CtrlX.xml"
STAGED_APPCAST="$WORK_ROOT/CtrlX.xml"
NOTARY_REPORTS="$DIST_DIR/qcloud-release/$VERSION/notary-$(basename "$WORK_ROOT")"
RELEASE_COMPLETE=false

cleanup_release_workspace() {
    if [ "$RELEASE_COMPLETE" = true ]; then
        /bin/rm -rf -- "$WORK_ROOT"
    else
        log_warning "Release stopped; evidence and resumable notarization inputs retained: $WORK_ROOT"
    fi
}
trap cleanup_release_workspace EXIT

mkdir -p "$DIST_DIR" "$SOURCE_PACKAGES" "$PACKAGE_ROOT/root"
export CTRLX_MAC_DISTRIBUTION=developer-id
export CTRLX_AGENT_BROWSER_SIGN_IDENTITY="$CTRLX_MAC_SIGNING_IDENTITY"
export CTRLX_DEVICE_INSTALLER_SIGN_IDENTITY="$CTRLX_MAC_SIGNING_IDENTITY"
bash "$SCRIPT_DIR/build-device-installer.sh"
bash "$SCRIPT_DIR/build-agent-browser.sh"

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
    CODE_SIGN_IDENTITY="$CTRLX_MAC_SIGNING_IDENTITY" \
    OTHER_CODE_SIGN_FLAGS=--timestamp \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    CTRLX_MAC_DISTRIBUTION=developer-id

# Use the chosen team/certificate even when Xcode has multiple logged-in accounts.
CTRLX_EXPORT_OPTIONS="$WORK_ROOT/export-options.plist" \
    python3 - <<'PY'
import os
import plistlib
from pathlib import Path
Path(os.environ['CTRLX_EXPORT_OPTIONS']).write_bytes(plistlib.dumps({
    'method': 'developer-id', 'signingStyle': 'manual', 'destination': 'export',
    'teamID': os.environ['CTRLX_MAC_DEVELOPMENT_TEAM'],
    'signingCertificate': os.environ['CTRLX_MAC_SIGNING_IDENTITY'],
}))
PY

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$WORK_ROOT/export-options.plist" \
    -exportPath "$EXPORT_PATH" \
    DEVELOPMENT_TEAM="$CTRLX_MAC_DEVELOPMENT_TEAM"

[ -d "$APP_PATH" ] || log_error "Archive export did not produce $APP_PATH."
python3 "$SCRIPT_DIR/macos_signing.py" sign "$APP_PATH" \
    --identity "$CTRLX_MAC_SIGNING_IDENTITY" --team "$CTRLX_MAC_DEVELOPMENT_TEAM"

ditto -c -k --keepParent "$APP_PATH" "$WORK_ROOT/CtrlX-notary.zip"
python3 "$SCRIPT_DIR/notarize_macos.py" "$WORK_ROOT/CtrlX-notary.zip" \
    --profile "$CTRLX_NOTARYTOOL_PROFILE" --report "$NOTARY_REPORTS/app.json"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
python3 "$SCRIPT_DIR/macos_signing.py" verify "$APP_PATH" --team "$CTRLX_MAC_DEVELOPMENT_TEAM"
spctl --assess --type execute --verbose=2 "$APP_PATH"

ditto "$APP_PATH" "$PACKAGE_ROOT/root/CtrlX.app"
ln -s /Applications "$PACKAGE_ROOT/root/Applications"
hdiutil create \
    -volname CtrlX \
    -srcfolder "$PACKAGE_ROOT/root" \
    -format UDZO \
    -ov \
    "$STAGED_DMG"
codesign --force --sign "$CTRLX_MAC_SIGNING_IDENTITY" --timestamp "$STAGED_DMG"
python3 "$SCRIPT_DIR/notarize_macos.py" "$STAGED_DMG" \
    --profile "$CTRLX_NOTARYTOOL_PROFILE" --report "$NOTARY_REPORTS/dmg.json"
xcrun stapler staple "$STAGED_DMG"
xcrun stapler validate "$STAGED_DMG"
codesign --verify --strict "$STAGED_DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$STAGED_DMG"
hdiutil verify "$STAGED_DMG" >/dev/null

signature_output="$("$SIGN_UPDATE" "$STAGED_DMG")"
signature="$(printf '%s' "$signature_output" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
[ -n "$signature" ] || log_error "Could not read Sparkle signature from sign_update output."

download_url="${CTRLX_DOWNLOAD_URL_PREFIX%/}/$(basename "$DMG_PATH")"
artifact_size="$(stat -f '%z' "$STAGED_DMG")"
release_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S %z')"

CTRLX_APPCAST_PATH="$STAGED_APPCAST" \
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

write_artifact_metadata "$STAGED_DMG"
publish_local_package "$STAGED_DMG" "$DMG_PATH"
mv "$STAGED_APPCAST" "$APPCAST_PATH"
prune_local_artifacts "$DMG_PATH" macOS
RELEASE_COMPLETE=true
log_success "Release artifact: $DMG_PATH"
log_success "Appcast: $APPCAST_PATH"
log_success "Corresponding source: https://github.com/jicezeng/CtrlX/tree/$SOURCE_REVISION"
