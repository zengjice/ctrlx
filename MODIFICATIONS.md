# Modifications

- **Distribution**: CtrlX
- **Fork point**: `919c7772928531d4d0bb266bdf275691d361901e`
- **Fork date**: 2026-08-14
- **Maintainer**: ZengJice `<jicezeng@gmail.com>`
- **Upstream**: [gpambrozio/Gallager](https://github.com/gpambrozio/Gallager)
- **License**: GNU AGPL-3.0

## 3.0.34 — Agent sessions in arbitrary Host directories

- Add New Session → Start in Directory on Mac (local and Viewer) and iOS.
  Enter an existing absolute Host path or ~/… and choose an enabled agent;
  a directory no longer needs to appear in the Projects history first.
- Reuse a shared lightweight form and the existing plugin launch contract,
  including Codex's runtime telemetry arguments and plugin environment.
  Do not edit global agent configuration or intercept manually typed commands.
- Resolve and validate directories on the Host before creating tmux state.
  Explicit agent launches fail clearly when the plugin is unavailable or
  Auto-run is disabled, while existing Projects and New Terminal keep their
  optional auto-run and bare-shell behavior.
- Scope remote agent choices to each Host and preserve shell quoting and
  simple command aliases. Add path, launch, Host-isolation and wire-compatibility
  regressions alongside the existing Codex telemetry tests.
- Update both the launching client and the Host for this workflow. The existing
  Relay remains compatible and does not require redeployment.

## 3.0.33 — Expanded agent commands and iOS Shift shortcuts

- Expand the shared Mac/iOS command panels to 24 Codex and 27 Claude Code
  commands, with independent per-agent allowlists and stable display order.
- Check Claude commands against 2.1.276: add effort, diff, review, goal,
  autocompact, output-style, branch, rename and skill/plugin reload entries;
  remove the retired agents manager and omit duplicate or higher-risk actions.
- Keep one-tap submission, the host-side pause before Return, and existing
  draft, permission, connection and focused-pane protections. Bound the Mac
  command grid with scrolling so the expanded catalog remains accessible.
- Pin the published SwiftTerm extension-keyboard update for iOS: Shift arrows,
  Shift-Tab and Shift-Enter send complete chords without sticky Shift state or
  an extra Return. Keep both always-visible shortcut rows unchanged.
- Add command-catalog, submission-guard and Shift transport/accessory tests.
  New commands depend on the Claude/Codex version running on the actual host;
  the existing Relay protocol and phrase synchronization remain unchanged.

## 3.0.32 — Mac modified arrow-key input

- Send Shift+arrow keys through the shared Mac Host/Viewer terminal input path
  instead of letting AppKit consume them as unsupported selection commands.
- Preserve Shift/Alt/Control arrow modifiers in the existing literal keystroke
  transport, including Codex's Shift+Left shortcut for queued questions.
- Preserve ordinary arrows, Option word movement, Command shortcuts, IME
  composition and mouse selection; pin the tested SwiftTerm fork revision.
- Add native keyboard, wire round-trip and isolated real-tmux regressions for
  both control-mode and process-based input, including conflicting root bindings.
- Update the Mac where keyboard input originates. No tmux configuration change,
  Codex update or Relay redeployment is required for this input-path fix.

## 3.0.31 — Device-level quick phrase sync settings

- Unify Mac and iOS phrase synchronization in Settings → Quick Phrase Sync,
  with one local switch per paired device instead of separate Host/Viewer
  controls. Both devices must allow sharing; neither role has priority.
- Group reciprocal pairings by their trusted public key, not their name.
  Preserve consistent legacy choices and ask for confirmation when old
  connection switches disagree, without silently expanding sharing permission.
- Show actual connection and consent status. Preserve offline merges and
  deletion markers, and explain how phrases propagate through trusted devices.
- Include the iOS quick-action glass overlay improvements: keep the terminal
  and keyboard stationary, toggle panels from their toolbar buttons, and
  match the microphone button's appearance to other toolbar controls.
- Add migration, pairing lifecycle, reciprocal permission-combination and
  four-device convergence regressions. Update both clients for the unified
  settings; the existing Qcloud Relay needs no redeployment.

## 3.0.30 — Shared quick actions and phrase synchronization

- Add Mac toolbar panels for agent commands and saved phrases, targeting the
  focused local or remote pane and reusing its ordered keyboard input queue.
- Share the curated command catalog across iOS and Mac. Phrases remain usable
  in ordinary shells and are saved locally before optional synchronization.
- Add per-pair, bilateral opt-in phrase synchronization over the existing E2EE
  connection, with offline merge, stable IDs, permanent deletion markers,
  bounded snapshots and backward-compatible capability negotiation.
- Preserve existing phrases through v1-to-v2 storage migration. Synchronization
  is disabled by default and never submits commands or changes terminal rendering.
- Include the recent iOS quick-phrase, tap-to-record, paired-quote input and
  compact toolbar improvements. Update both clients for phrase synchronization;
  the existing Qcloud Relay remains compatible and is not redeployed.

## 3.0.29 — Mac completion attention

- Acknowledge completed agent tasks from each displayed terminal pane, covering
  local and remote windows on both sides of a split.
- Observe pane state instead of the local pending total, so remote completions
  and same-count state changes no longer leave task markers or Dock badges stale.
- Preserve unread hidden tabs, background completions, blocking approval/question
  forms, and manual state overrides. Reuse existing Host/Viewer state and badge
  synchronization; no Relay or iOS update is required for this Mac fix.
- Add regression coverage for visibility, activation, host-scoped pane identity,
  repeated acknowledgements, and state changes without a pending-count change.

## 3.0.28 — Mac selection during streaming output

- Keep Mac local selections through incoming text, cursor updates and linefeeds,
  independently of mouse-reporting permission. Do not pause or buffer output
  while selecting; application mouse reporting remains available.
- Invalidate buffer-relative selections on buffer replacement and real grid
  changes, not an unchanged AppKit layout pass. Preserve explicit click, text
  input, paste and shortcut cancellation, including CtrlX's direct input routes.
- Add streaming-drag regressions for both pane positions, Shift selection,
  fragmented control sequences and auto-copy in the shared Mac Host/Viewer view.
- This requires the fixed SwiftTerm dependency on the Mac displaying the pane.
  It does not require a Relay deployment or change iOS gesture policy. The
  reported machine-specific new-pane behavior still needs device acceptance.

## 3.0.27 — Mac terminal mouse selection

- Respect Shift-selection and disabled mouse reporting throughout the shared
  Mac Host/Viewer event path, including drags, scrolling and selection auto-copy.
- Preserve mouse modifiers when an application explicitly captures Shift.
- Recognize valid nine-byte SGR mouse reports near the top-left corner so
  press and release events reach the terminal application intact.
- Add regressions for both pane positions, local selection, application mouse
  input, auto-copy, multi-click selection, links, scrolling and short reports.
- Publish a new Mac package. No Relay redeployment is needed; the original
  report of selection failing only in a newly split pane still needs device
  verification and is not claimed as conclusively resolved.

## 3.0.26 — Focused agent skills and image review

- Reduce the two bundled skill entrypoints from 444 to 131 lines, with
  task-specific references for CLI workflows and sidecar contracts.
- Correct CLI targeting/JSON examples and sidecar permission encodings; ignore
  child-agent completion in the starter template. Add isolated protocol,
  resource-sync, and documentation-size regressions.
- Bump the bundled Claude plugin to 1.3.2 and Codex plugin to 1.1.1 so updated
  skills have distinct cache versions.
- Let iOS users open a pending image to review the compressed content, with
  pinch/double-tap zoom and a separate remove action.
- Publish a new Mac package; the existing 3.0.25 Relay remains compatible and
  does not require redeployment. Image review requires a separate iOS build.

## 3.0.25 — Ordered Relay forwarding

- Preserve wire order across text and binary WebSocket frames with one bounded
  inbound FIFO and one async forwarding worker per connection.
- Keep early frames behind pair/entitlement validation. Discard queued frames
  on close, replacement or overflow; recheck source ownership at the send boundary.
- Add lossless-loopback regressions for both directions, immediate upgrade
  traffic, chunked snapshots and the final SwiftTerm composer/status rows.
- Deploy the Relay first and reconnect viewers for a fresh snapshot. Existing
  3.0.24 Mac/iOS clients remain compatible and do not need rebuilding for this fix.

## 3.0.24 — Native terminal viewport synchronization

- Pin the SwiftTerm fork fix that synchronizes the iOS viewport after native
  size/inset changes, including repeated requests for the current bottom row.
- Present an iOS session's initial tail after its native view is attached and
  laid out, without waiting for another terminal output byte.
- Preserve manual history scrolling, selection, and gesture ownership. Add
  regression coverage for initial presentation and native viewport drift.
- Keep the 3.0.23 Host stream fixes unchanged. The iOS viewport correction
  requires an updated iOS build; installing this Mac package alone cannot
  activate it on an iPhone. No Relay deployment is needed for these changes.

## 3.0.23 — Host terminal stream consistency

- Keep snapshot capture and live output on one control connection per tmux
  session, including concurrent connections and pane reopen operations.
- Capture history, visible cells, and cursor in one tmux command transaction;
  drain late responses after timeouts without shifting subsequent requests.
- Add real-tmux regression coverage for duplicate output and inconsistent
  screen/cursor state. Update the Host Mac running the affected sessions;
  updating only a Viewer or Relay does not activate these fixes.

See [terminal rendering investigation](docs/terminal-rendering-investigation.md)
for reproduced causes and verification scope.

## Major changes

- Rebranded the macOS app, iOS app, CLI, Relay, and documentation as CtrlX.
- Isolated Apple bundle identifiers, App Group, Keychain, local state, sockets,
  environment variables, tmux metadata, update infrastructure, and telemetry
  from Gallager.
- Added explicit build-to-source metadata and Relay source-disclosure endpoints.
- Retained the pre-existing customized terminal, tmux, remote-control, Relay,
  notification, and performance work in the complete Git history.

Detailed implementation and acceptance status live in
[`docs/v3.0.0`](docs/v3.0.0/).

This file records distribution-level changes, not every individual commit.
Consult the Git history and release notes for detailed changes.
