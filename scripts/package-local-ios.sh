#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_ROOT/Config/Shared-Base.xcconfig"
LOCAL_CONFIG="$PROJECT_ROOT/Config/Local.xcconfig"

# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

assert_git_worktree
[ -f "$LOCAL_CONFIG" ] \
    || log_error 'Missing Config/Local.xcconfig. Copy Config/Local.xcconfig.example and configure your personal team and bundle ID.'

VERSION="$(get_version)"
BUILD_STAMP="$(get_build_stamp)"
SOURCE_REVISION="$(get_source_revision)"
LOCAL_BUILD_ROOT="$PROJECT_ROOT/.build-local"
DERIVED_DATA="$LOCAL_BUILD_ROOT/DerivedData/iOS"
SOURCE_PACKAGES="$LOCAL_BUILD_ROOT/SourcePackages"
PACKAGE_ROOT="$LOCAL_BUILD_ROOT/package-ios"
DIST_DIR="$PROJECT_ROOT/dist"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/CtrlX.app"
EXTENSION_PATH="$APP_PATH/PlugIns/CtrlxNotificationExtension.appex"
IPA_PATH="$DIST_DIR/CtrlX-$VERSION.ipa"

mkdir -p "$DERIVED_DATA" "$SOURCE_PACKAGES" "$DIST_DIR"

log_info "Building CtrlX $VERSION from $PROJECT_ROOT"
/usr/bin/xcodebuild \
    -workspace "$PROJECT_ROOT/Ctrlx.xcworkspace" \
    -scheme Ctrlx \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    -disablePackageRepositoryCache \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipMacroValidation \
    -skipPackagePluginValidation \
    CTRLX_BUILD_STAMP="$BUILD_STAMP" \
    CTRLX_SOURCE_REVISION="$SOURCE_REVISION" \
    CODE_SIGNING_ALLOWED=NO \
    build

[ -d "$APP_PATH" ] || log_error "Build did not produce $APP_PATH"
[ -d "$EXTENSION_PATH" ] || log_error "Build did not produce $EXTENSION_PATH"

APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"
EXTENSION_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$EXTENSION_PATH/Info.plist")"
PROFILE_ROOT="$(/usr/bin/mktemp -d "$LOCAL_BUILD_ROOT/profiles.XXXXXX")"

cleanup_profiles() {
    if [ -d "$PROFILE_ROOT" ]; then
        /bin/rm -rf -- "$PROFILE_ROOT"
    fi
}
trap cleanup_profiles EXIT

find_profile() {
    local bundle_id="$1"
    local profile decoded identifier
    for profile_dir in \
        "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
        "$HOME/Library/MobileDevice/Provisioning Profiles"; do
        [ -d "$profile_dir" ] || continue
        while IFS= read -r profile; do
            decoded="$PROFILE_ROOT/candidate.plist"
            /usr/bin/security cms -D -i "$profile" -o "$decoded" >/dev/null 2>&1 || continue
            identifier=$(/usr/bin/plutil -extract Entitlements.application-identifier raw -o - "$decoded" 2>/dev/null || true)
            if [ "${identifier#*.}" = "$bundle_id" ]; then
                printf '%s\n' "$profile"
                return 0
            fi
        done < <(/usr/bin/find "$profile_dir" -maxdepth 1 -type f -name '*.mobileprovision' -print)
    done
    return 1
}

APP_PROFILE="$(find_profile "$APP_BUNDLE_ID")" \
    || log_error "No provisioning profile found for $APP_BUNDLE_ID"
EXTENSION_PROFILE="$(find_profile "$EXTENSION_BUNDLE_ID")" \
    || log_error "No provisioning profile found for $EXTENSION_BUNDLE_ID"

APP_PROFILE_PLIST="$PROFILE_ROOT/app-profile.plist"
EXTENSION_PROFILE_PLIST="$PROFILE_ROOT/extension-profile.plist"
APP_ENTITLEMENTS="$PROFILE_ROOT/app-entitlements.plist"
EXTENSION_ENTITLEMENTS="$PROFILE_ROOT/extension-entitlements.plist"
/usr/bin/security cms -D -i "$APP_PROFILE" -o "$APP_PROFILE_PLIST"
/usr/bin/security cms -D -i "$EXTENSION_PROFILE" -o "$EXTENSION_PROFILE_PLIST"
APP_TEAM_ID="$(/usr/bin/plutil -extract TeamIdentifier.0 raw -o - "$APP_PROFILE_PLIST")"
EXTENSION_TEAM_ID="$(/usr/bin/plutil -extract TeamIdentifier.0 raw -o - "$EXTENSION_PROFILE_PLIST")"
[ "$APP_TEAM_ID" = "$EXTENSION_TEAM_ID" ] \
    || log_error 'The app and notification extension provisioning profiles belong to different teams.'
SIGNING_IDENTITY="$(find_apple_development_identity "$APP_TEAM_ID")"
[ -n "$SIGNING_IDENTITY" ] \
    || log_error "No Apple Development signing identity is available for team $APP_TEAM_ID."
/usr/bin/plutil -extract Entitlements xml1 -o "$APP_ENTITLEMENTS" "$APP_PROFILE_PLIST"
/usr/bin/plutil -extract Entitlements xml1 -o "$EXTENSION_ENTITLEMENTS" "$EXTENSION_PROFILE_PLIST"
/bin/cp "$APP_PROFILE" "$APP_PATH/embedded.mobileprovision"
/bin/cp "$EXTENSION_PROFILE" "$EXTENSION_PATH/embedded.mobileprovision"

while IFS= read -r dylib; do
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$dylib"
done < <(/usr/bin/find "$APP_PATH" -type f -name '*.dylib' -print)
while IFS= read -r framework; do
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$framework"
done < <(/usr/bin/find "$APP_PATH" -type d -name '*.framework' -print)
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
    --entitlements "$EXTENSION_ENTITLEMENTS" --timestamp=none "$EXTENSION_PATH"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
    --entitlements "$APP_ENTITLEMENTS" --timestamp=none "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH" \
    || log_error 'Signed app verification failed.'

[ "$(/usr/libexec/PlistBuddy -c 'Print :CtrlXBuildStamp' "$APP_PATH/Info.plist")" = "$BUILD_STAMP" ] \
    || log_error 'Signed app is missing the expected build stamp.'
[ "$(/usr/libexec/PlistBuddy -c 'Print :CtrlXSourceRevision' "$APP_PATH/Info.plist")" = "$SOURCE_REVISION" ] \
    || log_error 'Signed app is missing the expected source revision.'

if [ -e "$PACKAGE_ROOT" ]; then
    /bin/rm -rf -- "$PACKAGE_ROOT"
fi
mkdir -p "$PACKAGE_ROOT/Payload"
/usr/bin/ditto "$APP_PATH" "$PACKAGE_ROOT/Payload/CtrlX.app"
if [ -e "$IPA_PATH" ]; then
    /bin/rm -f -- "$IPA_PATH"
fi
(
    cd "$PACKAGE_ROOT"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent Payload "$IPA_PATH"
)
write_artifact_metadata "$IPA_PATH"

log_success "IPA: $IPA_PATH"
log_success "Build: $VERSION ($(get_build_number)) · $BUILD_STAMP · $SOURCE_REVISION"
