# Modifications

- **Distribution**: CtrlX
- **Fork point**: `919c7772928531d4d0bb266bdf275691d361901e`
- **Fork date**: 2026-08-14
- **Maintainer**: ZengJice `<jicezeng@gmail.com>`
- **Upstream**: [gpambrozio/Gallager](https://github.com/gpambrozio/Gallager)
- **License**: GNU AGPL-3.0

## 3.0.46 — Fork callback isolation and verified session recovery

- Keep Host and shared Mac/iOS Fork callbacks explicitly on MainActor across
  suspended I/O, correcting the Host crash when Fork is requested from iOS.
- Persist native Codex/Claude conversation UUIDs with the pane, stable window
  and kernel process identity. Restore only a matching live process after a
  Host restart; reject reused processes, ambiguous panes and stale records.
  Legacy sessions need one fresh native Agent event to establish the binding.
- Keep identity writes off live status/notification delivery, serialize
  conversation changes, and preserve native IDs during automatic approvals.
  Unavailable Fork actions now expose their specific reason on Mac and iOS.
- Validation: 2,460 Swift tests passed on serial rerun after a parallel-process
  SIGPIPE interruption; two environment-dependent Apple Intelligence evaluations
  were excluded. Mac and unsigned iOS device-target compilation passed.
  Real-device Fork acceptance remains pending installation of the correction.
- This publication packages Mac only. No Relay deployment, iOS package/install
  or local Mac replacement is performed.

## 3.0.45 — Packaging disk checks and worktree-local storage management

- Check available build-volume space before packaging and warn below 20 GiB.
  Add opt-in `--save-space` to local Mac/iOS packaging, removing only the selected
  platform's compiler intermediates and module/SDK caches after success while
  preserving installable apps, packages and downloaded dependencies.
- Keep incremental compilation by default. Remove packaging indexes, duplicate
  dependency copies and verified public-download copies from completed releases;
  retain publication evidence and preserve failed or active publication downloads.
- Add offline regressions for cleanup boundaries, successful/failed packaging,
  argument handling, disk warnings and primary/linked-worktree isolation.
- Include Relay source changes that bound WebSocket memory, close replaced/stale
  connections, add heartbeat/close deadlines and break the pairing/APNs retain cycle.
  These require a separate Relay deployment to take effect in production.
- Release validation: brand/technical boundaries and 143 offline script tests
  passed; 2,351 Swift tests passed. Two existing Apple Intelligence evaluations
  remain unavailable on this Mac (`deviceNotEligible`), so the full-suite result
  is not all green.
- This publication packages Mac only. No Relay deployment, iOS package/install
  or local Mac replacement is performed.

## 3.0.44 — Native conversation forks, terminal updates and internal naming cleanup

- Add native Codex and Claude Code conversation forks on Mac and iOS, using
  the current directory or a new Git worktree. Keep agent configuration scoped
  to the fork invocation, use the intended shell, and verify worktree ignore rules.
- Add Quick Phrase drag reordering on Mac and iOS. Include iOS terminal-fit,
  dollar-key and ordered clipboard-paste improvements from the merged branch.
- Pin the tested SwiftTerm iOS line-layout cache optimization. Package local iOS
  builds as optimized Release by default, retaining local signing overrides and
  a separate Debug artifact for same-source performance comparisons.
- Rename internal CLI, emoji, plugin-contract, path and E2E symbols to Ctrlx.
  Preserve the public ctrlx command, packaged CtrlXCLI binary, saved editor
  preferences, upstream attribution and third-party licenses.
- Support worktree-local packaging and bounded local artifact retention. Remove
  upstream results-repository defaults; make generated proof-video watch commands
  carry the upload repository and release tag, with offline regressions.
- This publication packages Mac only. iOS changes need a separate signed package
  and installation; no Relay deployment or local Mac replacement is performed.

## 3.0.43 — Manual resume identity and Mac command-panel recovery

- Keep the Mac agent-command button openable while pane identity is unavailable.
  Opening an unidentified local panel requests one fresh process snapshot and
  restores its catalog only for the same Host, pane and input revision.
- Suppress ended sessions by their observed old process IDs rather than the
  entire pane, allowing a new agent launched or resumed between scans to be
  recognized. Include agents that replace the pane shell with `exec`.
- Preserve hook authority, failed-probe state, stable panel identity and stale
  send protections. Background reconciliation remains at ten-second intervals;
  unchanged results do not publish observable state or Viewer snapshots.
- Add process-cache ordering, quick-resume, probe-failure and panel-target
  regressions. All 90 focused checks and 2,271 tests in the full run passed;
  two existing Apple Intelligence evaluations remain unavailable on this Mac
  (`deviceNotEligible`), so the full-suite result is not all green.
- This publication packages Mac only and excludes the separate window-Fork
  feature under development. No Relay deployment, iOS reinstall or SwiftTerm
  dependency update is required.

## 3.0.42 — Agent windows, terminal telemetry and Codex question expansion

- Add New Agent window panels on Mac and iOS with one launch card per enabled
  Host agent. Reuse the Host's launch configuration and working directory;
  capability checks preserve compatibility with older Hosts.
- Add Codex telemetry defaults to manual launches in newly created zsh
  terminals, including resume commands. Preserve explicit telemetry settings,
  user shell configuration and argument forwarding; retain Claude telemetry
  environment support. Existing terminals are not retroactively rewritten.
- Automatically expand recognized Codex queued questions on iOS through the
  existing input queue and Host-side guards. Accept legacy and compact shortcuts
  plus optional elapsed-time suffixes on Mac/iOS; timer ticks do not reopen
  dismissed questions or postpone the stable-screen check.
- Preserve draft, IME, selection, scrolling and multi-viewer safeguards. Add
  shared parser, launch, shell integration, scheduler and Host regressions.
  iPhone Air opening and answering passed manual acceptance with the updated Host.
- Update Host Mac and viewing clients for elapsed-footer compatibility. This
  publication packages Mac only; iOS requires its separate signed package/install.
  No Relay deployment or SwiftTerm dependency update is required.
- Release validation: 1,256 tests passed in the full run; all 1,006 Mac tests
  passed on serial rerun after parallel test-process SIGPIPE interruptions.
  Two existing Apple Intelligence evaluations remain unavailable on this Mac
  (`deviceNotEligible`); this is not an all-green full-suite result. Brand and
  technical boundaries, website/iOS builds and 10 publisher regressions passed.

## 3.0.41 — Configurable Mac New Browser and Codex compatibility

- Add Mac Settings → Browser → New Browser → Engine, defaulting to Chromium
  with WebKit as an option. Apply the device-local choice to explicit New
  Browser actions in both local and Viewer workbenches, without converting
  existing tabs or changing terminal-link routing and agent automation.
- Embed human-created Chromium tabs in the existing session/split layout.
  Share CtrlX's dedicated Chromium profile without granting agent control;
  preserve child-tab routing across session renames and workspace cleanup.
  Chromium tabs remain transient; existing WebKit restoration is unchanged.
- Recognize both legacy and compact Codex queued-question shortcut hints,
  retaining live-composer, input-queue and multi-viewer safeguards.
- Keep agent identity when a Host process probe is temporarily unavailable,
  rather than falsely reporting an agent exit. Include the source changes for
  an always-openable iOS command panel with explicit unavailable-state guidance.
- Add preference, routing, lifecycle, ownership and compatibility regressions.
  This publication packages Mac only; iOS needs a separate package/install.
  No Relay deployment or SwiftTerm update is required.

## 3.0.40 — Avoid redundant terminal drawing during fullscreen scrolling

- Commit completed synchronized frames once, avoiding a second delayed redraw
  of the same content. Preserve first-frame/timeout recovery, stable caret,
  ordinary output, and the Mac Retina correction from 3.0.39.
- Reuse Mac CoreGraphics layout for unchanged lines that move during scrolling.
  Bound the cache to visible lines, validate mutations/columns, and rebuild
  row-dependent image placeholders; retain selection and link safeguards.
- Pin the tested SwiftTerm revision and add native-window/cache regressions.
  Isolated Release measurements show reduced drawing work, not guaranteed
  three-device frame rates or elimination of every downward-scroll stall.
- Update each display client for its rendering fix: local/Viewer Mac and iOS.
  This publication packages Mac only; iOS requires a separate package/install.
  No Relay deployment, transport change or Codex setting change is required.

## 3.0.39 — Mac terminal first-frame and Retina correction

- Correct the custom SwiftTerm backing layer's native redraw policy so local
  and Viewer Mac terminals paint their first frame and ordinary output without
  scrolling or waiting for a synchronized-output boundary.
- Keep the backing layer's pixel scale aligned with its window on attachment
  and screen changes; preserve terminal dimensions, selection, cursor and the
  synchronized-presentation/stable-caret improvements.
- Add native-window lifecycle regressions, including SwiftUI hosting and
  Retina scaling, rather than relying only on forced offscreen layer drawing.
- Mac display-client correction only; no Relay deployment or iOS reinstall
  is required for this issue.

## 3.0.38 — Fullscreen terminal interaction and embedded Agent Browser

- Keep Codex's fullscreen transcript and fixed composer. Correct precise
  trackpad/touch distance for its three-row wheel step; preserve Mac native
  momentum and add bounded, interruptible iOS touch momentum. This does not
  claim pixel-smooth scrolling or remove remote network latency.
- Reuse the Host's existing tmux control connection for ordered raw mouse
  input. Never replay ambiguous writes through the process fallback. Preserve
  live subscribers across Host resynchronization and overlapping subscriptions.
- Pin SwiftTerm's synchronized-presentation and stable-caret fixes on both
  Apple platforms. Restore iOS single-tap cursor placement in mouse-reporting
  TUIs while retaining link, selection, IME and inactive-pane protections.
- Include session-routed embedded Chromium tabs for local Codex instances,
  a shared persistent browser profile, the default bounded Vercel engine and
  the retained CtrlX engine. Include scoped page capabilities and native
  DevTools lifecycle fixes; the existing WebKit browser remains available.
- Add regression coverage and document per-client rollout and remaining
  browser/scrolling limits. Update the Host and display clients for the full
  terminal changes; no Relay redeployment or protocol migration is required.
- This Qcloud package uses the existing Apple Development/private-distribution
  path. Developer ID notarization and distribution archives remain gated.

## 3.0.37 — Mac Codex question expansion and post-IME shortcuts

- Restore Shift+arrow terminal shortcuts after committing or clearing IME
  composition by pinning the tested SwiftTerm fix. Preserve candidate selection
  during composition, ordinary navigation, paste and mouse selection.
- Automatically expand Codex's recognized queued-question footer in the focused
  Mac Host or Viewer pane, only at an empty live composer. Reuse Codex's native
  form; never answer questions or send Return automatically.
- Defer while typing, composing, selecting or browsing history. Serialize the
  opener with keyboard input, validate the live screen on the Host and deduplicate
  queue growth across viewers. Unknown layouts remain manual via Shift+Left.
- Add footer, stale-input, multi-viewer, FIFO, post-IME and isolated tmux PTY
  regression coverage. Update both Macs for remote auto-expansion; no Relay
  redeployment is required, and this release adds no iOS auto-opener.

## 3.0.36 — Codex as the default agent

- Prefer Codex in the shared Mac/iOS directory-session form and Mac agent
  settings. Preserve explicit choices and existing project identities; fall
  back to an available Host agent when Codex is absent.
- Default new session requests and the project-start API to Codex. Send the
  CLI's choice explicitly and add `ctrlx start-project --agent` for overrides.
- Preserve Claude attribution when decoding legacy session requests that
  omitted the agent ID. Add default-selection and launch-API regressions.
- No Relay redeployment or SwiftTerm update is required.

## 3.0.35 — Host directory browsing and path completion

- Browse folders when starting a session on Mac (local or Viewer) and iOS,
  starting at the Host's home directory. Navigate into folders, go Home/Up,
  show hidden folders, or type a path to complete its final component.
- Keep browsing separate from launching: only Start in This Directory creates
  the session, using the existing agent launch and telemetry configuration.
- Perform read-only, one-level lookups on the selected Host over the existing
  encrypted command channel. Bound results by count and bytes; debounce input
  and discard late responses when the path or Host changes.
- Preserve manual entry for older Hosts and show missing-path, permission and
  connection errors without changing terminal state. Add filesystem, request
  ownership, Host-isolation and wire-compatibility regression coverage.
- Update both Host and client for directory browsing. No Relay redeployment
  or SwiftTerm change is needed.

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
