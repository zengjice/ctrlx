#!/bin/sh

set -eu

cd "$(git rev-parse --show-toplevel)"

runtime_paths="Ctrlx CtrlxServer CtrlxNotificationExtension CtrlxE2ERunner Config CtrlxPackage/Sources CtrlxPackage/caddy CtrlxPackage/monitoring plugin plugins scripts sbin"
forbidden='GALLAGER_|CLAUDESPY_|@gallager-|\.gallager([/"[:space:]]|$)|\.claudespy([/"[:space:]]|$)|gallager\.sock|com\.claudespy|br\.eng\.gustavo|engineering\.dx\.gallager|XG2WG7U93U|relay\.gallager\.app|updates\.gallager\.app|gallager\.lemonsqueezy\.com'

if rg -n -g '!check-ctrlx-technical-boundary.sh' "$forbidden" $runtime_paths; then
  printf '\nCtrlX technical boundary check failed: an upstream runtime identity remains.\n' >&2
  exit 1
fi

internal_names='GallagerCLI|GallagerEmoji|GallagerPluginProtocol|GallagerPaths|GallagerProgressReporter|parseGallagerStateRoot|runGallager|resolveGallager|Sources/Gallager/'
if rg -n "$internal_names" CtrlxPackage/Package.swift CtrlxPackage/Sources \
  CtrlxPackage/Tests Ctrlx.xcodeproj CtrlxServerTests .github .vscode .claude \
  AGENTS.md docs/emoji-search.md docs/services-reference.md \
  docs/plugins/sidecar-authoring.md docs/agent-browser*.md scripts/generate-emoji-data.py; then
  printf '\nCtrlX technical boundary check failed: a legacy internal name remains.\n' >&2
  exit 1
fi
if rg --files CtrlxPackage/Sources CtrlxPackage/Tests | rg '(^|/)Gallager'; then
  printf '\nCtrlX technical boundary check failed: a legacy source path remains.\n' >&2
  exit 1
fi

required_patterns='com\.jicezeng\.ctrlx\.macos|com\.jicezeng\.ctrlx\.notification-service|group\.com\.jicezeng\.ctrlx|com\.jicezeng\.ctrlx\.shared|CTRLX_SOCKET|@ctrlx-description|\.ctrlx|ctrlx\.sock|CTRLX_SOURCE_REVISION|app\.get\("source"\)'
for pattern in $(printf '%s' "$required_patterns" | tr '|' ' '); do
  if ! rg -q "$pattern" $runtime_paths; then
    printf 'CtrlX technical boundary check failed: required identity not found: %s\n' "$pattern" >&2
    exit 1
  fi
done

if rg -n 'https?://([a-z0-9-]+\.)*ctrlx\.app' \
  Ctrlx CtrlxServer CtrlxNotificationExtension Config CtrlxPackage/Sources scripts sbin; then
  printf '\nCtrlX technical boundary check failed: an unowned production domain is hard-coded.\n' >&2
  exit 1
fi

printf 'CtrlX technical boundary check passed.\n'
