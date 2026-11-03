#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_ROOT/Config/Shared-Base.xcconfig"
LOCAL_CONFIG="$PROJECT_ROOT/Config/Local.xcconfig"

# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

CONFIGURATION=Release
SAVE_SPACE=true
APP_ONLY=false
SIGNING_MODE=""
LOCAL_BUILD_ARGUMENTS=("$@")
while [ "$#" -gt 0 ]; do
    case "$1" in
        --app-only)
            APP_ONLY=true
            shift
            ;;
        --configuration)
            [ "$#" -ge 2 ] || log_error '--configuration requires Release or Debug.'
            CONFIGURATION="$2"
            shift 2
            ;;
        --signing-mode)
            [ "$#" -ge 2 ] || log_error '--signing-mode requires development or ad-hoc.'
            SIGNING_MODE="$2"
            shift 2
            ;;
        --save-space)
            SAVE_SPACE=true
            shift
            ;;
        --keep-build-cache)
            SAVE_SPACE=false
            shift
            ;;
        --help|-h)
            printf '%s\n' 'Usage: package-local-ios.sh [--configuration Release|Debug] [--signing-mode development|ad-hoc] [--app-only] [--save-space|--keep-build-cache]' \
                '--app-only: build and verify the signed device App without producing an IPA.' \
                '--signing-mode: override CTRLX_IOS_SIGNING_MODE in Local.xcconfig (default development). Ad Hoc uses production APNs.' \
                'Default: Release; remove compilation caches after success. Debug writes a separate -Debug.ipa for comparison.' \
                '--save-space: explicitly select the default; keep App, IPA and downloads. Next build is slower.' \
                '--keep-build-cache: retain compilation caches for repeated iOS builds.'
            exit 0
            ;;
        *) log_error "Unknown argument: $1" ;;
    esac
done
case "$CONFIGURATION" in
    Release|Debug) ;;
    *) log_error 'Configuration must be Release or Debug.' ;;
esac

assert_git_worktree
# Bash 3.2 treats an empty array as unset under nounset.
with_worktree_lock ${LOCAL_BUILD_ARGUMENTS[@]+"${LOCAL_BUILD_ARGUMENTS[@]}"}
[ -f "$LOCAL_CONFIG" ] \
    || log_error 'Missing Config/Local.xcconfig. Copy Config/Local.xcconfig.example and configure your personal team and bundle ID.'
EXPECTED_TEAM_ID="$(read_xcconfig_value "$LOCAL_CONFIG" CTRLX_IOS_DEVELOPMENT_TEAM)"
[ -n "$EXPECTED_TEAM_ID" ] || log_error 'Configure CTRLX_IOS_DEVELOPMENT_TEAM in Config/Local.xcconfig.'
SIGNING_MODE="${SIGNING_MODE:-$(read_xcconfig_value "$LOCAL_CONFIG" CTRLX_IOS_SIGNING_MODE)}"
SIGNING_MODE="${SIGNING_MODE:-development}"
case "$SIGNING_MODE" in
    development|ad-hoc) ;;
    *) log_error 'Signing mode must be development or ad-hoc.' ;;
esac

VERSION="$(get_version)"
BUILD_STAMP="$(get_build_stamp)"
SOURCE_REVISION="$(get_source_revision)"
LOCAL_BUILD_ROOT="$PROJECT_ROOT/.build-local"
DERIVED_DATA="$LOCAL_BUILD_ROOT/DerivedData/iOS"
SOURCE_PACKAGES="$LOCAL_BUILD_ROOT/SourcePackages"
DIST_DIR="$PROJECT_ROOT/dist"
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos/CtrlX.app"
EXTENSION_PATH="$APP_PATH/PlugIns/CtrlxNotificationExtension.appex"
IPA_PATH="$DIST_DIR/CtrlX-$VERSION.ipa"
if [ "$CONFIGURATION" = Debug ]; then
    IPA_PATH="$DIST_DIR/CtrlX-$VERSION-Debug.ipa"
fi
if [ "$SIGNING_MODE" = ad-hoc ]; then
    IPA_PATH="${IPA_PATH%.ipa}-AdHoc.ipa"
fi

check_build_space "$PROJECT_ROOT"
if [ "$SAVE_SPACE" = true ]; then
    log_warning 'Space-saving mode: compilation caches are removed only after success. App and downloads are kept; the next build is slower.'
fi
mkdir -p "$DERIVED_DATA" "$SOURCE_PACKAGES" "$DIST_DIR"
PACKAGE_ROOT=""
PROFILE_ROOT=""

cleanup_ios_workspace() {
    [ -z "$PACKAGE_ROOT" ] || /bin/rm -rf -- "$PACKAGE_ROOT"
    if [ -n "$PROFILE_ROOT" ]; then
        /bin/rm -rf -- "$PROFILE_ROOT"
    fi
}
trap cleanup_ios_workspace EXIT

APP_BUNDLE_ID="$(read_xcconfig_value "$LOCAL_CONFIG" CTRLX_IOS_APP_BUNDLE_IDENTIFIER)"
EXTENSION_BUNDLE_ID="$(read_xcconfig_value "$LOCAL_CONFIG" CTRLX_IOS_NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER)"
APP_ENTITLEMENTS_SOURCE="$(read_xcconfig_value "$LOCAL_CONFIG" CTRLX_IOS_APP_ENTITLEMENTS)"
EXTENSION_ENTITLEMENTS_SOURCE="$(read_xcconfig_value "$LOCAL_CONFIG" CTRLX_IOS_NOTIFICATION_EXTENSION_ENTITLEMENTS)"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-$(read_xcconfig_value "$PROJECT_ROOT/Config/Shared.xcconfig" CTRLX_IOS_APP_BUNDLE_IDENTIFIER)}"
EXTENSION_BUNDLE_ID="${EXTENSION_BUNDLE_ID:-$(read_xcconfig_value "$PROJECT_ROOT/Config/Shared.xcconfig" CTRLX_IOS_NOTIFICATION_EXTENSION_BUNDLE_IDENTIFIER)}"
APP_ENTITLEMENTS_SOURCE="${APP_ENTITLEMENTS_SOURCE:-$(read_xcconfig_value "$PROJECT_ROOT/Config/Shared.xcconfig" CTRLX_IOS_APP_ENTITLEMENTS)}"
EXTENSION_ENTITLEMENTS_SOURCE="${EXTENSION_ENTITLEMENTS_SOURCE:-$(read_xcconfig_value "$PROJECT_ROOT/Config/Shared.xcconfig" CTRLX_IOS_NOTIFICATION_EXTENSION_ENTITLEMENTS)}"
PROFILE_ROOT="$(/usr/bin/mktemp -d "$LOCAL_BUILD_ROOT/profiles.XXXXXX")"
python3 "$SCRIPT_DIR/ios_profiles.py" prepare --team "$EXPECTED_TEAM_ID" --signing-mode "$SIGNING_MODE" \
    --app-bundle-id "$APP_BUNDLE_ID" --extension-bundle-id "$EXTENSION_BUNDLE_ID" \
    --app-entitlements "$PROJECT_ROOT/$APP_ENTITLEMENTS_SOURCE" \
    --extension-entitlements "$PROJECT_ROOT/$EXTENSION_ENTITLEMENTS_SOURCE" --output-directory "$PROFILE_ROOT"
SIGNING_IDENTITY="$(/usr/bin/plutil -extract identity raw -o - "$PROFILE_ROOT/signing.json")"
APP_ENTITLEMENTS="$PROFILE_ROOT/app-entitlements.plist"
EXTENSION_ENTITLEMENTS="$PROFILE_ROOT/extension-entitlements.plist"

invalidate_local_app ios "$CONFIGURATION"
log_info "Building CtrlX $VERSION ($CONFIGURATION) from $PROJECT_ROOT"
/usr/bin/xcodebuild \
    -workspace "$PROJECT_ROOT/Ctrlx.xcworkspace" \
    -scheme Ctrlx \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=iOS' \
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
    CODE_SIGNING_ALLOWED=NO \
    build

[ -d "$APP_PATH" ] || log_error "Build did not produce $APP_PATH"
[ -d "$EXTENSION_PATH" ] || log_error "Build did not produce $EXTENSION_PATH"

[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")" = "$APP_BUNDLE_ID" ] \
    || log_error 'Built App bundle ID differs from prepared signing inputs.'
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$EXTENSION_PATH/Info.plist")" = "$EXTENSION_BUNDLE_ID" ] \
    || log_error 'Built extension bundle ID differs from prepared signing inputs.'
/bin/cp "$PROFILE_ROOT/app.mobileprovision" "$APP_PATH/embedded.mobileprovision"
/bin/cp "$PROFILE_ROOT/extension.mobileprovision" "$EXTENSION_PATH/embedded.mobileprovision"

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
python3 "$SCRIPT_DIR/ios_profiles.py" verify --app "$APP_PATH" --output-directory "$PROFILE_ROOT"
record_local_app ios "$CONFIGURATION"
if [ "$APP_ONLY" = true ]; then
    prune_local_artifacts "" iOS "$SAVE_SPACE"
    log_success "App: $APP_PATH"
    exit 0
fi

PACKAGE_ROOT="$(/usr/bin/mktemp -d "$LOCAL_BUILD_ROOT/package-ios.XXXXXX")"
STAGED_IPA="$PACKAGE_ROOT/$(basename "$IPA_PATH")"
mkdir -p "$PACKAGE_ROOT/Payload"
/usr/bin/ditto "$APP_PATH" "$PACKAGE_ROOT/Payload/CtrlX.app"
(
    cd "$PACKAGE_ROOT"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent Payload "$STAGED_IPA"
)
write_artifact_metadata "$STAGED_IPA"
publish_local_package "$STAGED_IPA" "$IPA_PATH"
prune_local_artifacts "$IPA_PATH" iOS "$SAVE_SPACE"

log_success "IPA: $IPA_PATH"
log_success "App: $APP_PATH"
log_success "Build: $VERSION ($(get_build_number)) · $CONFIGURATION · $BUILD_STAMP · $SOURCE_REVISION"
