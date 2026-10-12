#!/bin/bash
set -euo pipefail
SIM_BUILD="${DERIVED_FILE_DIR}/agent-simulator"
CTRLX_SIMULATOR_SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}" \
  bash "${SRCROOT}/scripts/build-agent-simulator.sh" "$SIM_BUILD"
SIM_DEST="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}"
mkdir -p "$SIM_DEST/Helpers" "$SIM_DEST/Resources/AgentSimulator"
ditto "$SIM_BUILD/CtrlxSimulatorHost" "$SIM_DEST/Helpers/CtrlxSimulatorHost"
ditto "$SIM_BUILD/simslim" "$SIM_DEST/Helpers/simslim"
ditto "${SRCROOT}/CtrlxPackage/Sources/CtrlxSimulatorBridge/ThirdParty/idb-LICENSE" \
  "$SIM_DEST/Resources/AgentSimulator/idb-LICENSE"
ditto "$SIM_BUILD/simslim-LICENSE" "$SIM_DEST/Resources/AgentSimulator/simslim-LICENSE"
ditto "$SIM_BUILD/simslim-NOTICES.txt" "$SIM_DEST/Resources/AgentSimulator/simslim-NOTICES.txt"
ditto "$SIM_BUILD/simslim-build.json" "$SIM_DEST/Resources/AgentSimulator/simslim-build.json"
codesign --verify --strict "$SIM_DEST/Helpers/CtrlxSimulatorHost"
codesign --verify --strict "$SIM_DEST/Helpers/simslim"
