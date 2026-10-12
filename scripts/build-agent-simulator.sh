#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/.build-local/agent-simulator}"
mkdir -p "$BUILD"
SIM_ARCHIVES=()
for SIM_ARCH in ${ARCHS:-$(uname -m)}; do
xcrun clang -arch "$SIM_ARCH" -mmacosx-version-min=15.0 -O2 -fobjc-arc -fblocks \
  -framework Foundation -framework IOSurface -framework Metal -framework CoreGraphics -framework Accelerate -framework ImageIO \
  -I "$ROOT/CtrlxPackage/Sources/CtrlxSimulatorBridge/include" \
  "$ROOT/CtrlxPackage/Sources/CtrlxSimulatorBridge/Device.m" \
  "$ROOT/CtrlxPackage/Sources/CtrlxSimulatorBridge/Connection.m" \
  "$ROOT/CtrlxPackage/Sources/CtrlxSimulatorBridge/Input.m" \
  "$ROOT/CtrlxPackage/Sources/CtrlxSimulatorBridge/Host.m" \
  "$ROOT/CtrlxPackage/Sources/CtrlxSimulatorBridge/ScreenshotImage.m" \
  "$ROOT/CtrlxPackage/Sources/CtrlxSimulatorHost/main.m" \
  -o "$BUILD/CtrlxSimulatorHost-$SIM_ARCH"
SIM_ARCHIVES+=("$BUILD/CtrlxSimulatorHost-$SIM_ARCH")
done
xcrun lipo -create "${SIM_ARCHIVES[@]}" -output "$BUILD/CtrlxSimulatorHost"
codesign --force --options runtime --sign "${CTRLX_SIMULATOR_SIGN_IDENTITY:--}" "$BUILD/CtrlxSimulatorHost"
bash "$ROOT/scripts/build-simslim.sh" "$BUILD"
printf '%s\n' "$BUILD/CtrlxSimulatorHost"
