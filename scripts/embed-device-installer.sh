#!/bin/bash
set -euo pipefail
DI_SOURCE="${SRCROOT}/.build-local/device-installer"
DI_DEST="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}"
[[ -f "$DI_SOURCE/build.json" ]] || { echo 'error: Run bash scripts/build-device-installer.sh first.' >&2; exit 1; }
rm -rf "$DI_DEST/Helpers/DeviceInstaller" "$DI_DEST/Resources/DeviceInstaller"
mkdir -p "$DI_DEST/Helpers/DeviceInstaller" "$DI_DEST/Resources/DeviceInstaller"
ditto "$DI_SOURCE/Runtime" "$DI_DEST/Helpers/DeviceInstaller"
ditto "$DI_SOURCE/Licenses" "$DI_DEST/Resources/DeviceInstaller/Licenses"
ditto "$DI_SOURCE/build.json" "$DI_DEST/Resources/DeviceInstaller/build.json"
for di_binary in "$DI_DEST"/Helpers/DeviceInstaller/idevice* "$DI_DEST"/Helpers/DeviceInstaller/lib/*.dylib; do
  codesign --verify --strict "$di_binary"
done
