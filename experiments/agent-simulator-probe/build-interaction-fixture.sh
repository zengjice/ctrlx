#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:-$ROOT/.build-local/agent-simulator-probe/InteractionFixture.app}"
mkdir -p "$APP"
SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun clang -O2 -fobjc-arc -fblocks -target arm64-apple-ios18.0-simulator -isysroot "$SDK_PATH" \
  -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
  "$ROOT/experiments/agent-simulator-probe/InteractionFixture.m" -o "$APP/InteractionFixture"
python3 - "$APP/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as file:
    plistlib.dump({'CFBundleIdentifier':'com.jicezeng.ctrlx.interaction-fixture',
        'CFBundleName':'InteractionFixture','CFBundleExecutable':'InteractionFixture',
        'CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0',
        'MinimumOSVersion':'18.0','CFBundleSupportedPlatforms':['iPhoneSimulator'],
        'UIDeviceFamily':[1,2],'UILaunchScreen':{},
        'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,
            'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[
                {'UISceneConfigurationName':'Default','UISceneDelegateClassName':'InteractionScene'}]}},
        'UISupportedInterfaceOrientations':[
            'UIInterfaceOrientationPortrait','UIInterfaceOrientationPortraitUpsideDown',
            'UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight']},file)
PY
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
