#!/bin/bash
# Copies every skill from the Claude plugin into the Codex plugin
# folder inside the built .app bundle. The skills live in the repo only
# once (under plugin/ctrlx/skills/) and are mirrored into
# plugin/codex/ctrlx/skills/ at build time so both plugins expose
# the same set without keeping a second copy in the repo.
#
# Runs after the "Copy Bundle Resources" phase, so the plugin/ tree is
# already in the .app when we get here. We never write into the source
# tree — only into the built product.

set -euo pipefail

APP_PLUGIN_DIR="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources/plugin"
SOURCE_DIR="${APP_PLUGIN_DIR}/ctrlx/skills"
DEST_DIR="${APP_PLUGIN_DIR}/codex/ctrlx/skills"

for marketplace in "$APP_PLUGIN_DIR" "$APP_PLUGIN_DIR/codex"; do
    if [ ! -f "$marketplace/ctrlx-hooks/hooks/hooks.json" ]; then
        echo "error: missing independent CtrlX hooks at $marketplace/ctrlx-hooks" >&2
        exit 1
    fi
    # Incremental folder copies can retain files removed from the source tree.
    # Remove the former hook component from built skills packages only.
    rm -rf "$marketplace/ctrlx/hooks" "$marketplace/ctrlx/scripts"
done

if [ ! -d "$SOURCE_DIR" ]; then
    echo "error: no skills directory at $SOURCE_DIR" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"

# rsync mirrors the whole skills tree, dropping any stale skills in the
# destination that no longer exist in the source. The trailing slash on
# SOURCE_DIR is intentional — it tells rsync to copy the contents, not
# the parent directory itself.
rsync -a --delete "$SOURCE_DIR/" "$DEST_DIR/"

# Log what made it across so build output explains itself.
if compgen -G "$DEST_DIR/*" > /dev/null; then
    echo "Synced skills into $DEST_DIR:"
    for entry in "$DEST_DIR"/*; do
        [ -e "$entry" ] && echo "  - $(basename "$entry")"
    done
else
    echo "Source skills directory is empty; nothing to copy."
fi
