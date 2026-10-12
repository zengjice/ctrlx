#!/bin/bash
set -euo pipefail
SIM_ENV_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SIM_ENV_APP="${1:-$SIM_ENV_ROOT/.build-local/agent-simulator-probe/EnvironmentFixture.app}"
mkdir -p "$SIM_ENV_APP"
SIM_ENV_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun clang -O2 -fobjc-arc -fblocks -target arm64-apple-ios18.0-simulator -isysroot "$SIM_ENV_SDK" \
  -framework UIKit -framework Foundation -framework CoreLocation -framework UserNotifications \
  "$SIM_ENV_ROOT/experiments/agent-simulator-probe/EnvironmentFixture.m" -o "$SIM_ENV_APP/EnvironmentFixture"
python3 - "$SIM_ENV_APP/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as file:
    plistlib.dump({'CFBundleIdentifier': 'com.jicezeng.ctrlx.environment-fixture',
        'CFBundleName': 'EnvironmentFixture', 'CFBundleExecutable': 'EnvironmentFixture',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
        'MinimumOSVersion': '18.0', 'CFBundleSupportedPlatforms': ['iPhoneSimulator'],
        'UIDeviceFamily': [1, 2], 'UILaunchScreen': {},
        'NSLocationWhenInUseUsageDescription': 'Validate CtrlX simulated location on this isolated test device.',
        'UIBackgroundModes': ['remote-notification'],
        'CFBundleURLTypes': [{'CFBundleURLSchemes': ['ctrlx-environment-fixture']}],
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False,
            'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [
                {'UISceneConfigurationName': 'Default', 'UISceneDelegateClassName': 'EnvironmentScene'}]}}}, file)
PY
codesign --force --sign - "$SIM_ENV_APP"
printf '%s\n' "$SIM_ENV_APP"
