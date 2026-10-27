#!/bin/bash
# Build a self-contained installer; no Xcode, Homebrew or Configurator at runtime.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"
with_worktree_lock "$@"
python3 "$SCRIPT_DIR/build_device_installer.py"
