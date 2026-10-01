#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_ROOT/Config/Shared-Base.xcconfig"
LOCAL_MAC_CONFIG="$PROJECT_ROOT/Config/Local-macOS.xcconfig"

# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

assert_git_worktree
[ -f "$LOCAL_MAC_CONFIG" ] \
    || log_error 'Missing Config/Local-macOS.xcconfig. Copy Config/Local-macOS.xcconfig.example and configure your personal team.'

VERSION="$(get_version)"
BUILD_STAMP="$(get_build_stamp)"
SOURCE_REVISION="$(get_source_revision)"
LOCAL_BUILD_ROOT="$PROJECT_ROOT/.build-local"
DERIVED_DATA="$LOCAL_BUILD_ROOT/DerivedData/macOS"
SOURCE_PACKAGES="$LOCAL_BUILD_ROOT/SourcePackages"
DIST_DIR="$PROJECT_ROOT/dist"
DMG_PATH="$DIST_DIR/CtrlX-$VERSION.dmg"
APP_PATH="$DERIVED_DATA/Build/Products/Release/CtrlX.app"
DEVELOPMENT_TEAM="$(read_xcconfig_value "$LOCAL_MAC_CONFIG" CTRLX_MAC_DEVELOPMENT_TEAM)"
[ -n "$DEVELOPMENT_TEAM" ] || log_error 'CTRLX_MAC_DEVELOPMENT_TEAM is empty.'
SIGNING_IDENTITY="$(find_apple_development_identity "$DEVELOPMENT_TEAM")"

[ -n "$SIGNING_IDENTITY" ] \
    || log_error "No Apple Development signing identity is available for team $DEVELOPMENT_TEAM."

mkdir -p "$DERIVED_DATA" "$SOURCE_PACKAGES" "$DIST_DIR"
PACKAGE_ROOT="$(/usr/bin/mktemp -d "$LOCAL_BUILD_ROOT/package-macos.XXXXXX")"

cleanup_macos_workspace() {
    /bin/rm -rf -- "$PACKAGE_ROOT"
}
trap cleanup_macos_workspace EXIT

CTRLX_AGENT_BROWSER_SIGN_IDENTITY="$SIGNING_IDENTITY" bash "$SCRIPT_DIR/build-agent-browser.sh"

log_info "Building CtrlX $VERSION from $PROJECT_ROOT"
/usr/bin/xcodebuild \
    -workspace "$PROJECT_ROOT/Ctrlx.xcworkspace" \
    -scheme CtrlxServer \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    -disablePackageRepositoryCache \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipMacroValidation \
    -skipPackagePluginValidation \
    COMPILER_INDEX_STORE_ENABLE=NO \
    INDEX_ENABLE_DATA_STORE=NO \
    CTRLX_BUILD_STAMP="$BUILD_STAMP" \
    CTRLX_SOURCE_REVISION="$SOURCE_REVISION" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    OTHER_CODE_SIGN_FLAGS=--timestamp=none \
    build

[ -d "$APP_PATH" ] || log_error "Build did not produce $APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH" \
    || log_error 'Built app signature is invalid.'

[ "$(/usr/libexec/PlistBuddy -c 'Print :CtrlXBuildStamp' "$APP_PATH/Contents/Info.plist")" = "$BUILD_STAMP" ] \
    || log_error 'Built app is missing the expected build stamp.'
[ "$(/usr/libexec/PlistBuddy -c 'Print :CtrlXSourceRevision' "$APP_PATH/Contents/Info.plist")" = "$SOURCE_REVISION" ] \
    || log_error 'Built app is missing the expected source revision.'

mkdir -p "$PACKAGE_ROOT/root"
/usr/bin/ditto "$APP_PATH" "$PACKAGE_ROOT/root/CtrlX.app"
/bin/ln -s /Applications "$PACKAGE_ROOT/root/Applications"

if [ -e "$DMG_PATH" ]; then
    /bin/rm -f -- "$DMG_PATH"
fi
/usr/bin/hdiutil create \
    -volname CtrlX \
    -srcfolder "$PACKAGE_ROOT/root" \
    -format UDZO \
    -ov \
    "$DMG_PATH"
/usr/bin/hdiutil verify "$DMG_PATH" >/dev/null
write_artifact_metadata "$DMG_PATH"
prune_local_artifacts "$DMG_PATH" macOS

log_success "DMG: $DMG_PATH"
log_success "Build: $VERSION ($(get_build_number)) · $BUILD_STAMP · $SOURCE_REVISION"
