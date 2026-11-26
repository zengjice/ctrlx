#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
with_worktree_lock "$@"
cd "$SCRIPT_DIR/.."
cache=".build-local/orbie-web-assets"
npm install --prefix "$cache" --ignore-scripts --no-audit --no-fund --save-exact \
    generative-frame@0.0.12 safe-content-frame@0.0.34 esbuild@0.27.0 \
    highlight.js@11.11.1 github-markdown-css@5.8.1
node scripts/build-orbie-chat-assets.mjs
