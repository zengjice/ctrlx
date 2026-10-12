#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:-$ROOT/.build-local/agent-simulator-probe/SimulatorFixture.app}"
mkdir -p "$APP"
SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun clang -O2 -fobjc-arc -fblocks -target arm64-apple-ios18.0-simulator -isysroot "$SDK_PATH" \
  -framework UIKit -framework Foundation -framework WebKit -framework CoreGraphics -framework QuartzCore \
  "$ROOT/experiments/agent-simulator-probe/fixture.m" -o "$APP/SimulatorFixture"
python3 - "$APP/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({'CFBundleIdentifier':'com.jicezeng.ctrlx.simulator-fixture', 'CFBundleName':'SimulatorFixture',
        'CFBundleExecutable':'SimulatorFixture', 'CFBundlePackageType':'APPL', 'CFBundleVersion':'1',
        'CFBundleShortVersionString':'1.0', 'MinimumOSVersion':'18.0', 'CFBundleSupportedPlatforms':['iPhoneSimulator'],
        'UIDeviceFamily':[1,2], 'UILaunchScreen':{},
        'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,
            'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[
                {'UISceneConfigurationName':'Default','UISceneDelegateClassName':'FixtureScene'}]}}}, f)
PY
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
