#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${CTRLX_BASELINE_LABEL:-production}"
[[ "$MODE" =~ ^[a-z0-9-]+$ ]] || { printf 'Invalid experiment label\n' >&2; exit 2; }
BUILD="$ROOT/.build-local/agent-simulator-baseline-$MODE"
APP="$BUILD/DisplayBaseline.app"
BRIDGE="$ROOT/CtrlxPackage/Sources/CtrlxSimulatorBridge"
VIEW_SOURCE="${CTRLX_BASELINE_VIEW_SOURCE:-$ROOT/CtrlxPackage/Sources/CtrlxServerFeature/Views/SimulatorMetalView.swift}"
HARNESS_SOURCE="${CTRLX_BASELINE_HARNESS_SOURCE:-$ROOT/experiments/agent-simulator-probe/DisplayBaseline.swift}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$BUILD/modules"
python3 - "$MODE" "$VIEW_SOURCE" "$BUILD/build-metadata.json" <<'PY'
from pathlib import Path
import hashlib,json,re,sys
p=Path(sys.argv[2]);s=p.read_text()
drawable_count=re.search(r'maximumDrawableCount = (\d+)',s)
metal_layer='metalLayer = CAMetalLayer()' in s
renderer='metal' if metal_layer else ('raw-video' if 'AVSampleBufferDisplayLayer()' in s else 'iosurface-layer')
Path(sys.argv[3]).write_text(json.dumps({'mode':sys.argv[1],'source':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),
    'renderer':renderer,
    'maximumDrawableCount':int(drawable_count[1]) if drawable_count else None,
    'sourceDriven': 'let displayLink = CAMetalDisplayLink' not in s,
    'displaySyncEnabled': ('displaySyncEnabled = false' not in s) if metal_layer else None},indent=2))
PY
cat > "$BUILD/modules/module.modulemap" <<EOF
module CtrlxSimulatorBridge {
    header "$BRIDGE/include/CtrlxSimulatorBridge.h"
    export *
}
EOF
xcrun clang -O2 -fobjc-arc -fblocks -mmacosx-version-min=15.0 -I "$BRIDGE/include" \
    -c "$BRIDGE/Connection.m" -o "$BUILD/Connection.o"
xcrun swiftc -swift-version 6 -O -target arm64-apple-macosx15.0 -parse-as-library \
    -emit-module -emit-library -module-name CtrlxSimulatorProtocol \
    "$ROOT/CtrlxPackage/Sources/CtrlxSimulatorProtocol/SimulatorGeometry.swift" \
    -emit-module-path "$BUILD/modules/CtrlxSimulatorProtocol.swiftmodule" \
    -Xlinker -install_name -Xlinker @rpath/libCtrlxSimulatorProtocol.dylib \
    -o "$APP/Contents/Frameworks/libCtrlxSimulatorProtocol.dylib"
xcrun swiftc -swift-version 6 -O -target arm64-apple-macosx15.0 -parse-as-library \
    -I "$BUILD/modules" -L "$APP/Contents/Frameworks" -lCtrlxSimulatorProtocol \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -framework AppKit -framework IOSurface -framework Metal -framework QuartzCore \
    "$BUILD/Connection.o" "$VIEW_SOURCE" \
    "$HARNESS_SOURCE" -o "$APP/Contents/MacOS/DisplayBaseline"
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib,sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier':'com.ctrlx.simulator-display-baseline',
    'CFBundleExecutable':'DisplayBaseline','CFBundleName':'Simulator Display Baseline',
    'CFBundlePackageType':'APPL','NSHighResolutionCapable':True}))
PY
codesign --force --deep --sign - "$APP"
if [[ "${CTRLX_BASELINE_BUILD_ONLY:-0}" == 1 ]]; then
    printf '%s\n' "$APP"
    exit 0
fi
exec python3 "$ROOT/experiments/agent-simulator-probe/display-baseline.py" \
    "$APP/Contents/MacOS/DisplayBaseline" \
    "${CTRLX_BASELINE_HELPER:-$ROOT/.build-local/DerivedData/macOS/Build/Products/Release/CtrlX.app/Contents/Helpers/CtrlxSimulatorHost}" \
    "$(xcode-select -p)" "$1" "$2" "$BUILD"
