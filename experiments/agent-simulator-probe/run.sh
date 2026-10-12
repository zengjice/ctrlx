#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/.build-local/agent-simulator-probe"
mkdir -p "$BUILD"
xcrun clang -fobjc-arc -fblocks -framework Foundation -framework IOSurface -framework CoreGraphics -framework CoreImage -framework ImageIO \
  -I "$ROOT/CtrlxPackage/Sources/CtrlxSimulatorBridge/include" \
  "$ROOT/CtrlxPackage/Sources/CtrlxSimulatorBridge/Device.m" \
  "$ROOT/CtrlxPackage/Sources/CtrlxSimulatorBridge/Connection.m" \
  "$ROOT/experiments/agent-simulator-probe/main.m" -o "$BUILD/probe"
DEVELOPER_DIR_PATH="$(xcode-select -p)"
exec "$BUILD/probe" "$DEVELOPER_DIR_PATH" "$@"
