# Services Reference

Current component entry points and selected behavioral contracts. Paths below are
relative to `CtrlxPackage/Sources/` unless stated otherwise. Read the
[architecture](architecture.md) first and the [topic index](README.md) for scope.
Plugin/Viewer entry points were reconciled with `fa9c977` on 2026-10-11;
dated acceptance paragraphs retain their original test scope, not a fresh run.

## macOS Services

### FileBrowserClient / HostFileBrowser

Dependency-injected Host filesystem operations for Mac Host, Mac Viewer and iOS
Files tabs. Previews/search are bounded reads; explicit folder creation and
non-overwriting imports/uploads are supported. `HostFileBrowser` is an I/O actor
in `CtrlxServerFeature/Services/FileBrowserClient.swift`; `HostFileUploads` owns
upload state. Per-connection `FileBrowserCommandQueue` keeps file requests
outside the keyboard receive loop.
See [Host-backed Files tabs](file-browser.md) for capabilities, bounds and tests.

### AppCoordinator (`CtrlxServerFeature/Coordinators/AppCoordinator.swift`)

`@Observable @MainActor` central coordinator for all services.

**Responsibilities:**
- Creates and owns all services
- Wires callbacks between services (plugin events, pane changes, commands)
- Two-phase init: sync (core services) + async (`setupAllServices()` for E2EE, connections)
- Auto-connects to paired devices on startup
- Observes system wake for reconnection

### TmuxService (`CtrlxServerFeature/Services/TmuxService.swift`)

`@Observable @MainActor` class abstracting tmux CLI interactions.

**Methods:**
- `refreshPanes()` - discovers all panes across sessions
- `validatePane()` - checks if pane target exists
- `detectAgentPanesIfAvailable()` - reliable process snapshot for lifecycle checks;
  nil means unavailable, not an agent exit. `LivePluginHost` preserves that
  distinction through `PluginHost.agentPanesIfAvailable()` for Codex's exit
  monitor. A failed probe must not clear identity or trigger automatic pane close.
- `capturePane()` - captures scrollback with ANSI sequences
- `capturePaneWithScrollbackForStreaming()` - captures with cursor positioning for streaming init
- `getPaneDimensions()` / `getPaneId()` - dimension tracking
- `sendKeys()` / `sendInterrupt()` - send input to panes
- `createSession()` - creates new tmux session with dimensions
- `probeVisualConflict()` - detects whether the user's rc files clobber the `$VISUAL` CtrlX sets (see [Editor Override](#editor-override-ctrl-g) below)
- `injectVisualOverrideIntoExistingShellPanes()` / `clearInjectedOverrideTracking()` - manage the opt-in `export VISUAL` injection

**Config:** `tmuxPath` (default: `/opt/homebrew/bin/tmux`), optional `socketPath`, `overrideVisualInShellPanes` (mirrors `AppSettings.editorOverrideMode`)

**Modified arrows:** Mac Host and Viewer share `InteractiveTerminalView`. The
SwiftTerm fork encodes Shift+arrows as legacy `ESC [ 1 ; modifier A/B/C/D`
without requiring Kitty negotiation. `TmuxKey.from(bytes:)` preserves these
modified sequences as `.text`, rather than collapsing them to plain arrows.
They use the existing wire format and literal tmux paths (`send-keys -H` in
control mode, `send-keys -l --` in the process fallback), bypassing tmux root
key bindings. Update the Mac where the keyboard input originates; an older
host can already receive these literal bytes, and no Relay update is needed.
Composition is determined by SwiftTerm's actual marked text (`hasMarkedText()`),
not a separate keyboard-protocol flag: arrows remain IME-owned while choosing
candidates, but committing or clearing the marked text restores terminal routing.
Regression coverage: `MacTerminalInputTests`, `TmuxKeyCsiParsingTests`, and
`LocalKeystrokeInputTests` (including post-IME-commit arrows and isolated real-PTY
checks). The fork's `MacModifiedArrowTests` also covers composition cancellation,
empty marked text, bracketed paste, and starting a new composition in both protocols.

**Codex question auto-expansion (Mac Host, Mac Viewer and iOS):**
`CodexQuestionPrompt` recognizes the live `Queued follow-up inputs / ? N questions /
shift + ← to answer` footer immediately above Codex's known empty composer. It
also accepts the compact `shift+← to answer` hint observed in Codex 0.158.0,
the no-plus `shift← to answer` hint observed in 0.160.0, and
the optional question age (`? 1 question · 14s`, including h/m/s duration parts).
The current recognizer accepts `shift` (case-insensitive) or `⇧`, followed by
`←` or `Left`, with or without `+` and whitespace. Examples:
`⇧← to answer`, `Shift + Left to answer`, and `⇧ + ← to answer`.
Only the complete nearby footer is joined across wrapped rows; modifier/arrow
order is not arbitrary, and other keys or additional modifiers are rejected.
Braille animation is ignored only around known footer/empty-composer structure,
not inside a user's draft. Source: `CtrlxCommon/Models/CodexQuestionPrompt.swift`.
Age is presentation-only: ticks neither restart the 350 ms stability check nor
re-arm a dismissed queue. Other shortcuts, arbitrary suffixes, incomplete hints
and drafts still fail closed. Mac/iOS-side
recognition and the Host's screen recheck use the same `CtrlxCommon` parser. The
native wrapper checks a stable screen after 350 ms; only the key window's focused,
visible terminal at the live bottom is eligible (no editor overlay, text selection,
mouse drag or marked IME text). Typing postpones the check. It neither changes
focus nor sends Enter/answers, and does not change the agent's working state.

Local panes call `TmuxService.expandCodexQuestions`; viewers enqueue the additive
`ExpandCodexQuestions(expectedCount:expectedQuestionID:)` intent behind existing keyboard input.
The intent requires an explicit `codexQuestionsHandled` acknowledgement. The Host
reports true after tmux accepts the opener, when another viewer already handled
that count, or after accepting a reduced/empty queue baseline; it reports false
when a guard defers the attempt. This confirms Host handling, not TUI rendering.
The Host checks the foreground command, cursor, copy mode and actual screen before
sending `S-Left`. When tmux reports a shell wrapper instead of `codex`, the Host
reuses the agent-process scanner with a fresh snapshot to verify Codex in that pane, then rechecks
the live screen before claiming the opener. Non-shell commands and missing/failed
process snapshots fail closed. Duplicate counts do not repeat the process scan.
The Host commits a growing count only after sending the opener successfully;
clients commit their count only after a positive acknowledgement. Host-wide
queue-count deduplication within each question identity prevents duplicate automatic
opens from multiple viewers, tab remounts and Escape/redraws. The Codex question hook
supplies a session-qualified `tool_use_id` through `NotificationSpec.questionID`.
The Host publishes it as optional `PaneState.codexQuestionID`; this field advertises
identity-check support for that pane. A new identity resets both Host and native
client deduplication, so two consecutive single-question calls do not require a
visible empty queue between them. Repeated snapshots of the same identity do not
reset it. Intents carry the observed identity; the Host rejects stale identities,
including changes during an awaited screen check or key send, and clients ignore
acknowledgements from an older identity. Notifications still leave agent lifecycle
and response forms unchanged. Queue reductions
do not auto-open; a verified empty normal composer resets the baseline. Closed
panes discard their state. Pane refreshes preserve question IDs received or changed
while awaiting tmux, together with their handled counts; the next refresh reconciles
them even if the pane list is unchanged. There is no polling timer or history/rollout scan.

This is intentionally a conservative TUI convenience, not an App Server question
API: unknown/localized layouts and custom empty placeholders stay manual. Without
question hooks or when paired with an older Host that omits the identity, the
count-only fallback still needs an observed queue reduction for equal-count
replacements. A missed/failed
attempt can retry on a later native output/focus/eligibility event, without a
polling loop. A successful attempt remains deduplicated after Escape/redraw.
Existing Shift+Left remains usable. For remote auto-expansion, update the
**Host Mac and viewing client (Mac/iOS)**. The Viewer requires the optional
`supportsCodexQuestionAcknowledgement` capability before sending an intent;
older Hosts remain manual, without a raw-key fallback or response wait.
The elapsed/no-plus footer compatibility fixes also require
an updated **Host Mac and viewing client (Mac/iOS)**: supporting the wire command
alone is not enough, because the Host independently parses the footer. For example,
Host 3.0.40 rejects both the compact shortcut and elapsed suffix. Relay deployment
is unnecessary; the new response and capability fields are optional and travel
inside the existing encrypted payload. The `CodexQuestions` OSLog category records
Host refusal/send results, client eligibility (focus, selection, scrollback and
composer recognition), deduplication and acknowledgement results without
question/draft content or hook IDs. Native eligibility diagnostics are emitted only
when their reason changes.

On iOS, `TerminalCodexQuestionExpansion` runs outside SwiftUI observable state.
The selected pane's native wrapper reads at most nine live rows, after parsing
terminal output, and checks again after 350 ms. Unrelated output does not extend
the deadline; a changed/partial footer does. It requires the input proxy's focus,
an active scene, a ready stream, both native viewports at the bottom, no copy/menu,
IME, cursor-navigation operation, drag or mouse-scroll momentum, and no blocking
response form/quick-action overlay. Typing, stream reset, resize, focus loss and
view teardown cancel pending checks. It never moves focus or scrolls the viewport
to force eligibility. Counts enter the same `KeystrokeDebouncer` FIFO as text and
mouse input, with a two-second acknowledgement timeout. Pending acknowledgements
suppress duplicate enqueues; queue cancellation reports failure to the scheduler.
Host-wide dedup also covers an iPhone and Mac viewing the same pane.
Tests: `CodexQuestionPromptElapsedTests`, `CodexQuestionExpansionTests`,
`CodexQuestionShellWrapperTests`, `TerminalCodexQuestionExpansionTests` and
`KeystrokeDebouncerTests`; wire compatibility is covered by
`CodexQuestionAcknowledgementTests` and the isolated encrypted relay fixture in
`TerminalPasteTransportTests`. Opening and answering the elapsed
footer passed manual acceptance on iPhone Air with the updated Host (2026-09-30).
The complete UIKit focus/scroll/menu matrix still needs on-device acceptance;
the scheduler and Host guards run in unit tests.

### Editor Override (Ctrl-G)

CtrlX points `$VISUAL` at the bundled `ctrlx edit` CLI (via tmux `-e` on every session) so Ctrl-G in Claude Code / Codex opens the in-app prompt editor. Spawned panes run a login shell that sources the user's rc files **after** the session env is applied, so a user with `export VISUAL=<their editor>` in `~/.zshrc`/`~/.bashrc` clobbers CtrlX's value and Ctrl-G opens *their* editor instead. The override is **consent-based** (issue #591) — CtrlX's env is a default, never a silent override.

Key files: `EditorOverride.swift` (pure helpers + `EditorOverrideMode`/`VisualProbeResult`), `TmuxService` (probe + injection), `AppCoordinator` (coordination), `EditorOverrideDialog.swift` (the dialog), `EditorsSettingsView.swift` (`PromptEditorOverrideSection`).

**1. Conflict probe.** At startup (only when `CtrlxCLI` is bundled, and in either `ask` or `overrideInCtrlxSessions` mode), `TmuxService.probeVisualConflict()` creates a detached probe session named `__ctrlx_probe` with `-e VISUAL=__ctrlx_probe__` and the normal `default-command` wrapper (real pty / env / startup), types `printf 'CTRLX_PROBE=%s\n' "$VISUAL"`, and polls `capture-pane` (~10s) for the marker. Sentinel intact → no conflict; a different value or empty → conflict (the user's value is remembered for the dialog copy). No CLI / unknown shell (nushell) / timeout → treated as no-conflict. The probe session is filtered out of every user-facing list by its name prefix (so injection never touches it — the probe stays honest even while override is active). Re-run on demand from Settings ("Re-check now").

**2. Dialog.** Deferred from launch to the **first session creation** (when "Ctrl-G" has context). Shows the conflicting value and three choices:
- **Fix it in your shell config (recommended)** — keeps the setting at *Ask*; shows a copyable guarded line `[ -n "$CTRLX_SOCKET" ] || export VISUAL='<their value>'` (CtrlX exports `CTRLX_SOCKET` before rc files run, so the rc can detect a CtrlX pane). The next launch's probe verifies; if fixed, the dialog never returns.
- **Override in CtrlX sessions** — enables keystroke injection (below).
- **Keep my editor, stop asking** — never override, never ask.
- Dismissing ("Decide later") leaves it at *Ask* — re-prompts on a later conflict probe.

**3. Injection (override mode).** Instead of tampering with shell startup, CtrlX types the export into shell panes:
- **New panes:** `refreshPanes()` injects a leading-space `export VISUAL='<ctrlx> edit'` (POSIX) / `set -gx VISUAL …` (fish) into each new known-shell pane. The bytes buffer until the first prompt, so they run *after* all rc files. The leading space keeps it out of history under `HISTCONTROL=ignorespace` / `HIST_IGNORE_SPACE`.
- **Existing panes** are injected when the setting is turned on.
- **App-launched agents** chain the export onto the agent command line in `createSession` (a direct-command pane never ran rc files, so the new-pane injector skips it).
- Per-pane dedup keeps it to one line per shell pane.

**4. Startup reconciliation.** A user who opted into the override only needs it while their rc actually clobbers `$VISUAL`. If they later remove their `export VISUAL` and CtrlX's `-e VISUAL` wins on its own, the per-pane injection becomes pure redundancy. So on launch in `overrideInCtrlxSessions` mode, `AppCoordinator` re-probes and, if the probe **positively** reports `.intact`, falls back to `.ask` (stops injecting) via `EditorOverride.shouldDropRedundantOverride(mode:probe:)`. A `.skipped` / not-yet-run probe is *not* treated as proof the conflict is gone, so the override is left in place. The same reconciliation runs on Settings → "Re-check now". If the conflict later returns, `.ask` re-prompts.

**Settings:** `AppSettings.editorOverrideMode` (`ask` / `overrideInCtrlxSessions` / `useMyEditor`). The pre-rename persisted override value is migrated on load without changing the user's choice. `AppCoordinator.setEditorOverrideMode(_:)` is the single mutation point — it persists the choice and mirrors it onto `TmuxService.overrideVisualInShellPanes`.

**Limitations:** the injected line is visible in scrollback; a nested shell (`exec zsh`) re-sources rc with no re-injection; changing the setting doesn't affect already-running agents; the override also affects `git commit`/`crontab` in those panes; typing within the first ~second of a pane opening (or an rc ending in `exec`) can interleave with / swallow the injected line. All are accepted trade-offs for users who explicitly opted in.

`baseEnvironmentVars` (injected via tmux `-e`, so they reach both app-launched and manually-typed `claude`) sets the Claude rendering/update flags **and** the OTEL export vars that point Claude Code at the Mac-local `OTLPReceiver` (`CLAUDE_CODE_ENABLE_TELEMETRY=1`, `OTEL_*` → `http://127.0.0.1:<OTLPReceiver.advertisedPort>`; issue #597). No content gates are enabled. The endpoint port is `OTLPReceiver.advertisedPort` — the port the receiver **actually bound** (its preferred port, or a fallback candidate when that was taken), published before any pane can be created, so the bind and the advertisement can't drift. When the receiver failed to bind every candidate, the OTEL block is skipped entirely (no dead endpoints). The property is computed per creation, not cached, so it always reads the settled bind.

### Prompt editor request lifetime

`EditorSessionManager` creates a new UUID for each live `ctrlx edit` request.
Mac Viewer submit/cancel commands include that UUID as optional
`expectedSessionID`; the Host checks it against the currently active editor
before writing or cancelling, without suspending between validation and the
operation. A replaced or completed request returns failure. Old commands without
the field remain decodable and keep their legacy active-pane targeting.

The Viewer also retains the terminal binding from the displayed editor, so a
known Host/tmux incarnation change rejects a delayed outgoing action. Only a
successful Host response clears the submitted text, and later edits survive that
response. Restored workspace drafts are text only and never recreate editor
requests or submit callbacks.

The local API captures the original pane identity before reading its temporary
file. Publication and submit require that same physical pane. Discovery retires
an editor whose pane disappears or changes before broadcasting replacement
metadata, returns an error to the waiting CLI, and retains its text against the
original persistent UUID. It never assigns that draft to a recycled pane number.
A live pane moved to another window/session keeps its editor.

The Host registers the editor completion continuation before publishing its
state, allowing a fast Viewer response while the broadcast awaits transport.
File-write failure leaves the request, continuation and edits available for
retry; it must not be reported as successful submission.

### Closing terminals across workspace reconstruction

Mac and iOS close actions retain the target identity from before the running-
process query and confirmation dialog. On capable Hosts, process queries and
close commands carry that original identity. A session check follows the physical
session, independently of its current children; a window check follows the physical
window. Replacement targets produce an error and require a fresh user action.
Older Hosts keep the existing optional-field compatibility path.

Ordinary tmux discovery assigns missing session/window/pane UUIDs independently
of recovery snapshots. Turning recovery off or failing to read a journal does
not leave new live terminals without an identity. Discovery and recovery capture
only fill empty metadata on the originally observed tmux server, then reread its
actual values; concurrent captures cannot overwrite each other's UUIDs. Identity
assignment runs in batches of at most 16 guarded commands so large workspaces
stay below tmux's command-message limit. A failed batch leaves existing UUIDs
intact; the next discovery/capture fills only still-missing identities. Local
close actions wait for this metadata rather than creating an unbound confirmation.

`TmuxService` validates the expected identity before entering the recovery close
transaction, then tmux checks the captured server/object identity in the same
command queue as `kill-*`. The close and journal update remain serialized, so a
checkpoint cannot recreate an explicitly deleted item. This does not authorize
replay of other queued operations; outstanding recovery acceptance is tracked in
[Stage 4](v3.0.76/STAGE4_TODO.md).

Window-name editors similarly retain the window binding from when editing
began. Discovery can update the tab underneath an open editor without retargeting
its Save action. Mac local, Mac Viewer and iOS use the physical window ID;
capable Viewer commands carry the original identity, and tmux checks the server
and window UUID in the same queue as `rename-window`. A replaced pane inside the
same window does not invalidate a window rename. Rejection is shown to the user;
older Hosts retain the optional-identity path.

Session-name editors capture the original session action on Mac and iOS, including
the Viewer's binding before any queued task. The Host checks the actual tmux server
and session UUID in the same queue as `rename-session`, after checking name
availability. Replacing a child window or pane does not retire a session editor.
Private layout migration requires matching persistent identities when available;
recycled pane numbers alone cannot establish that a reconstructed session was
renamed. Identity-free snapshots retain the existing legacy rename detection.

Session descriptions, colors, emoji and manual state changes use the same
session binding. Description/emoji editors retain their original callbacks;
the iOS More sheet keeps them through dismissal and the subsequent editor.
Persistent metadata checks the server/session before listing window overrides,
clearing each override and writing the session option. The Host acknowledges
only after persistence succeeds, and cached rows update only if they still
belong to that session. Manual state remains transient and checks the current
session identity before changing its cached panes. Failures reach the client
instead of being reported as successful saves.

New-window requests retain the originating session binding from the Mac/iOS
button or Agent dialog through launch preparation and the tmux mutation. Pending
selection must still refer to that session when the reply/snapshot arrives.
iOS retains this binding until the created tab's delayed automatic Fit is consumed.
`new-session` and `new-window` return their physical server incarnation and pane
ID in the creation command itself; later naming and startup input are conditional
on that original server/pane. Discovery may assign persistent UUIDs afterward.
This also avoids assuming that the first window and pane indexes are zero.
New-session replies additionally carry the captured server incarnation and Host
state-root identity in optional `createdPaneScope`. Local selection checks the
created server; Mac/iOS Viewers wait for a matching live catalog before adopting
the pane number. iOS carries the resolved session binding into delayed Fit.
Older Hosts retain the previous numeric-ID behavior; a capable Host with missing
creation identity does not silently fall back to it.

Local CLI mutations resolve their target once and retain its workspace identity
through subsequent awaits. Layout application keeps the original session and
each created pane through metadata, options, splits, delayed input and focus;
it checks the session before and after each host-shell hook. It stops after a
target change without replaying remaining commands on reconstructed objects.
Already-running user hooks are ordinary shell processes, not cancellable
transactions. Bootstrap windows use their actual creation result and indexes.

Window reorder and shared-layout requests also carry the original session
binding. Reorder checks it while listing windows, applying each swap and rolling
back a partial failure; a replacement session is never the rollback destination.
UI continuations recheck identity before migrating selection/tab state. Shared
layout debounce resolves the final layout after SwiftUI settles while retaining
the originating session. The Host validates tmux identity and any newer cached
identity before accepting the canonical layout. Existing window-set validation
and optional-field compatibility remain in force.

The discovery callback synchronizes `MirrorWindowManager` before publishing its
snapshot. It cannot rely on a later UI observer or the periodic caller to do so:
a broadcast sent first would retain an old identity indefinitely during otherwise
quiet polling. This synchronization performs no additional tmux query and keeps
Viewer snapshot construction read-only.

### TmuxControlClient (`CtrlxServerFeature/Services/TmuxControlClient.swift`)

Actor managing a `tmux -C attach -f ignore-size` control connection for commands, event notifications, snapshots, and live pane output.

**Features:**
- Connects with `-f ignore-size`, so the invisible client cannot affect geometry but `%output` remains available
- Sends commands and receives responses via `%begin/%end` blocks (FIFO command queue)
- Decodes tmux's byte-level octal escaping in `%output` and sanitizes the result before delivery
- Invokes an optional response-boundary callback before parsing later notifications
- Parses event notifications: `%layout-change`, `%session-changed`, `%exit`
- Tracks per-pane cached dimensions for change detection
- Uses AsyncStream + single consumer for strict ordering of control mode messages

**Callbacks:**
- `onDimensionChange(paneId, width, height)` - pane resized (from `%layout-change`)
- `onPaneExited(paneId)` - pane closed
- `onSessionChanged(sessionId, name)` - session switched
- `onExit(reason)` - control mode connection closed
- `onOutput(paneId, data)` - decoded live bytes for enabled panes

### TmuxControlClientManager (`CtrlxServerFeature/Services/TmuxControlClientManager.swift`)

`@Observable @MainActor` managing `TmuxControlClient` instances per session.

**Methods:**
- `getClient(for:)` - returns existing or creates new client for session
- `registerPaneDimensions()` / `unregisterPane()` - register/unregister pane for dimension tracking
- `sendCommand(_:sessionName:)` - send tmux command through the control client
- `setPaneOutputEnabled()` - enable/disable live output for a pane with subscribers
- `setOnDimensionChange()` - forward dimension changes to PaneStreamManager
- `setOnPanesChanged()` - callback when panes exit (for cleanup)
- `extractSessionName(from:)` - parses session from pane target

Multiple panes in the same session share one control connection. Snapshots and live output therefore have one observable order.

### PipePaneReader (`CtrlxServerFeature/Services/PipePaneReader.swift`)

`actor` managing a scan-only FIFO copy from tmux `pipe-pane` for a single pane. One reader lives for the pane's full lifetime and never feeds terminal content.

**Features:**
- Creates per-pane FIFO (`/tmp/ctrlx-pipe-<id>.fifo`)
- Starts `pipe-pane -O "cat > fifo"` via control mode command
- Reads raw PTY bytes only to parse OSC 9/777/9;4/0/2/52 side effects
- AsyncStream + single consumer task for strict FIFO ordering
- Forwards notifications, titles, clipboard updates, and progress through `PipePaneReaderDelegate`; all ordinary terminal bytes are discarded

**Lifecycle:**
- `setDelegate(_:)` - attach the delegate that receives OSC side effects
- `startPipePane(controlClientManager:sessionName:)` - create FIFO, send pipe-pane command, and start scanning
- `stopPipePane()` - clean up FIFO, close file handle (called when the pane disappears)

### PaneStreamManager (`CtrlxServerFeature/Services/PaneStreamManager.swift`)

`@Observable @MainActor` owning one scan-only `PipePaneReader` per known pane and multiplexing control-mode terminal output to subscribers.

**Per-pane lifecycle:**
- New pane discovered → `startReader` creates a `PipePaneReader`, attaches the manager as delegate, calls `startPipePane()` (scan-only mode)
- Pane disappears → `tearDownReader` calls `stopPipePane`, unregisters dimensions, drops the entry

**Data Flow:**
```
tmux ──control mode──→ TmuxControlClient ──%output──→ PaneStreamManager ──→ subscribers

tmux ──pipe-pane──→ FIFO ──→ PipePaneReader ──OSC side effects──→ PaneStreamManager
```

**Subscribe flow (first subscriber on a pane):**
1. Register a private subscriber bootstrap gate and enable `%output`
2. Refresh dimensions and capture through the same control connection
3. At the visible capture's `%end`, discard pre-boundary overlap already present in the snapshot
4. Publish `snapshot + post-boundary bytes`, then switch the subscriber to live routing

**Unsubscribe flow (last subscriber leaves):**
- Disable `%output` for the pane. The scan-only FIFO stays attached so OSC side effects keep flowing.

**Methods:**
- `startMonitoring(panes:)` - create readers for all initial panes (called once on startup)
- `updateMonitoring(panes:)` - tear down readers for dead panes, start readers for new panes (called on periodic refresh and on `%session-changed`)
- `subscribe(paneId:target:onData:onDimensionChange:onTitleChange:onNotification:onClipboard:)` - subscribe with callbacks
- `unsubscribe(_:)` - remove subscription (disables pane output if last)
- `currentContent(for:)` - capture current terminal content without subscribing (for multi-device initial state)
- `updateDimensions(paneId:width:height:)` - propagate dimension changes
- `reportTitleChange(paneId:title:fromSubscription:)` - forward a title detected by a subscriber's SwiftTerm to other subscribers
- `mouseModeSequences(for:)` - DEC private mode escape sequences for the pane's current mouse tracking mode
- `disconnectAll()` - shutdown cleanup

**Internal state:** A single `readers: [String: ReaderContext]` dictionary keyed by paneId. Each context holds the reader, target, sessionName, dimensions, subscriber UUIDs, and the latest known title.

### MirrorWindowManager (`CtrlxServerFeature/Managers/MirrorWindowManager.swift`)

`@Observable @MainActor` managing NSWindow lifecycle.

- Tracks sessions and windows by pane target
- Applies plugin-owned session state, lifecycle actions and attention updates
- Respects user-closed state (won't reopen until session ends)
- Periodic session validation cleans up stale sessions
- `updatePaneStates(from:)` syncs pane state from tmux, removing stale entries
- Persists the Claude `session.id` as `PaneState.claudeSessionID` (the OTEL join key, issue #597) and exposes `applyTelemetry` / `applyPermissionMode` to stamp the joined pane; cleared on session end
- `refreshGitBranches()` (run on the validation tick) detects each pane's git
  branch with a single cheap `git rev-parse --abbrev-ref HEAD`. The Git tab's
  changed-file badge (issue #573) is separate — read live from the per-session
  GitWorkbench store's `summary`, kept fresh by the store's own repository
  watcher — so it isn't computed here

### TerminalContainerView (`CtrlxServerFeature/Views/TerminalContainerView.swift`)

`NSViewRepresentable` bridging native SwiftTerm views to SwiftUI.

- Wraps SwiftTerm's `TerminalView`
- Uses **FlippedClipView** for top alignment
- Fixed dimensions in character cells
- CoreText font metrics for cell size
- Theme support (DefaultDark/Light, SolarizedDark/Light)

### Plugin ingress and event dispatch

- `CtrlxServerFeature/Plugins/IngressSocketServer.swift`: app-owned Unix-domain
  socket receiving length-prefixed JSON `IngressFrame` values.
- `CtrlxServerFeature/Plugins/PluginRegistry.swift`: manifests and enabled
  `PluginCore` actors. Built-in cores live in `ClaudeCodePluginCore/` and
  `CodexPluginCore/`; external cores use `Plugins/Sidecar/SidecarPluginCore.swift`.
- `CtrlxServerFeature/Plugins/PluginEventDispatcher.swift`: translates a core's
  `PluginEvent` into app state, notifications, auto-approval and app actions.
- `CtrlxServerFeature/Plugins/LivePluginHost.swift`: callback adapter for
  projects, input, process discovery and plugin logs.
- `CtrlxServerFeature/Plugins/AgentResponseSubmissionGuard.swift`: validates
  current request identity before delivering responses.
- `CtrlxServerFeature/Plugins/PluginResponseContext.swift`: retains the original
  physical pane, plugin, conversation and form request through response delivery.
  Native core calls inherit the context; sidecars retain it through their ordered
  response notifications. Each text/key sink revalidates it, and tmux checks the
  actual server/pane identity in the same queue as the write. Live pane moves
  remain valid; reconstructed terminals and retracted requests do not.

Structured Viewer responses use the existing workspace-input capability to carry
an optional expected pane identity. Old Hosts retain their compatibility path.
iOS notification actions wait for the first usable pane snapshot as well as the
encrypted connection before submitting. Submission still acknowledges transport,
not native Agent consumption; persisted drafts are not cleared on that basis.

`AppCoordinator.setupPluginRuntime()` wires these services. Shared state uses
`AgentSession.pluginID` / `AgentState`; agent-specific payload parsing and
keystroke delivery stay inside the owning core. The legacy HTTP hook service is
removed. Do not send hooks to `/api/hooks` or introduce a second ingress path.
The OTLP HTTP receiver below is a separate telemetry channel.

See [sidecar authoring](plugins/sidecar-authoring.md) for manifest and wire casing,
supervision and distribution, plus [architecture](architecture.md) for the
end-to-end flow.

### OTLPReceiver (`CtrlxServerFeature/Telemetry/OTLPReceiver.swift`)

`actor` — a Mac-local OpenTelemetry receiver that **augments** the hook channel with quantitative, content-free data from a coding agent's OTEL export — Claude Code (issue #597) and Codex (issue #602). One-way push only; nothing is ever sent back into the agent. The receiver/decoder/accumulator are agent-blind; each log record is classified by its event-name namespace (`claude_code.` vs `codex.`) and parsed with that agent's vocabulary into the same `SessionTelemetry`.

- Loopback-only `NWListener` bound **explicitly to the IPv4 loopback address** (`requiredLocalEndpoint = 127.0.0.1:<port>` + `requiredInterfaceType = .loopback`, so no Local Network Privacy prompt and unreachable off-host). The explicit IPv4 bind matters: a port-only bind creates a dual-stack IPv6 wildcard socket that silently *coexists* with another process's IPv4-specific listener on the same port — the kernel then routes all IPv4 traffic (exporters dial `127.0.0.1`) to the other process and the meter starves with no error anywhere (observed live: a Docker OTLP collector holding `127.0.0.1:4318` swallowed every export). The IPv4-specific bind turns that into an `EADDRINUSE` the receiver reacts to. Accepts `POST /v1/metrics` and `POST /v1/logs` as OTLP/JSON; responds `200 {}`. No protobuf/gRPC dependency. The hand-rolled HTTP parser frames bodies by **both** `Content-Length` *and* `Transfer-Encoding: chunked` — Claude Code's real exporter (observed on 2.1.198) sends every export chunked with no `Content-Length` at all, so a length-only parser acks `200` while dropping every record (and then misreads the chunk bytes as the next request's headers).
- **Port** — the receiver probes candidates in order (`OTLPReceiver.portCandidates`): the preferred port (`preferredPort` = `defaultPort` `24318` in production, or an `--otlp-port <port>` launch override), then up to four fallbacks at +100 strides. `defaultPort` is deliberately **not** the OTLP-standard `4318` — that's the first port any local collector binds. The port that wins is published as `OTLPReceiver.advertisedPort`, the one value every advertisement reads (env injection, `PluginEnv.otlpReceiverEndpoint`, the E2E `GET /otlp-port` query on the `TestAccessibilityServer`); `nil` when every candidate was taken, in which case consumers skip OTEL config. E2E passes a per-instance preferred port (`MacOSDriver.defaultOTLPPort + instance`, base `14318`, spacing 1 — the +100 fallback stride can never land on a sibling's preferred port) and the orchestrator re-reads the actually-bound port after launch to repoint `${otlpEndpoint}`. The OTEL channel's counterpart to the per-instance accessibility port / ingress socket / tmux socket.
- Decoding lives in `OTLPModels.swift` (tolerant: int64 may arrive as a JSON string or number). Accumulation lives in `OTLPTelemetryAccumulator.swift` (pure value logic, unit-tested), keyed by the session join id (Claude `session.id` / Codex `conversation.id`):
  - **Claude** `claude_code.api_request` log events → summed tokens (by type), summed `cost_usd`, latest `duration_ms`/`model`, and a capped ring of the last ~20 turns.
  - **Claude** `claude_code.commit.count` / `pull_request.count` counters → milestone deltas between exports **and** the cumulative count carried onto the snapshot (issue #598, for the recap).
  - **Claude** `claude_code.active_time.total` counter → cumulative active seconds; `claude_code.lines_of_code.count` (`type=added/removed`) → per-type line counts; `claude_code.tool_result` log events → a per-event tool count (issue #598).
  - **Claude** `claude_code.permission_mode_changed` events → the pane's current permission mode + trigger.
  - **Codex** `codex.sse_event` (`event.kind = response.completed`) → tokens + `model`. OpenAI's `cached_token_count` is nested *inside* `input_token_count` (unlike Claude's disjoint buckets), so it's mapped to the cache-read field and excluded from the headline. **`input_token_count`/`cached_token_count` are cumulative** — `response.completed` fires once per model call (several per turn with tool use), each re-reporting the whole growing context — so the accumulator adds only the positive **delta** per session (output is per-call and summed as-is); summing raw per-event input would multiply-count the same context (~1.5× over on a 3-tool turn, confirmed live on Codex 0.140). Codex emits no cost.
  - **Codex** `codex.turn_ttft` → the turn's time-to-first-token `duration_ms` (`SessionTelemetry.recordTurnLatency`, which back-fills the just-completed token turn's sparkline point; the headline is authoritative, the back-fill best-effort). Tokens and latency arrive on *separate* events. Both `codex.sse_event` and `codex.turn_ttft` carry `conversation.id`; `codex.api_request` does **not** (it's the `/models` capability check, and turn calls run over websocket), so it can't be joined. Codex metrics also omit `conversation.id` (openai/codex#15905), so the `codex.turn.*` metrics can't be joined to a pane and are ignored.
- The permission-mode chip is seeded from the **hook channel** for both agents. For Claude it has a second source — OTEL `permission_mode_changed` (which only fires on a *change*) — so `UserPromptSubmit`/`PreToolUse`/`PostToolUse`/`Stop` also carry `permission_mode`, which the translator puts on the `PluginEvent` and `MirrorWindowManager.applyState` stamps onto the pane (a `nil` never clobbers a known mode). Codex reports a Claude-compatible `permission_mode` on the same events (`CodexTranslator` passes it through); it has no OTEL mode-change signal, so the hook channel is its sole source.
- **Injection differs by agent.** Claude reads `OTEL_*` env vars, injected via `TmuxService.baseEnvironmentVars` (`CLAUDE_CODE_ENABLE_TELEMETRY=1`, `OTEL_*`). Codex does *not* read `OTEL_*` — OTEL is configured only through its `config.toml` schema, and `otel` is denylisted from project-local config — so app-launched Codex panes instead get `-c otel.…` runtime overrides (`CodexOtelConfig.launchOverrides`, gated on the per-agent `export_telemetry` setting), which point `otel.exporter` at `http://127.0.0.1:<port>/v1/logs` (`protocol = "json"`), set `otel.metrics_exporter = "none"`, and leave `log_user_prompt = false`. The runtime-override layer is exempt from the `otel` denylist, and nothing is written to the user's global `~/.codex/config.toml` (so a launch can't corrupt the user's own config). No content gates are enabled for either agent, so no prompt/tool/body content leaves the process.
- `AppCoordinator` wires the receiver's callbacks: telemetry → `MirrorWindowManager.applyTelemetry` (joined to a pane by `claudeSessionID`, then a throttled ~1/sec viewer push); milestones → one notification each via the existing `handlePluginNotification` path; mode changes → `MirrorWindowManager.applyPermissionMode`. The accumulated state is evicted on session end. See `MirrorWindowManager` and `PaneState.telemetry` / `.permissionMode`.

**Manual Codex in New Terminal:** `TerminalAgentShellIntegration` adds a shell-local
function to newly created zsh panes only, using the same core-generated OTEL
arguments as UI launches. User aliases/functions and explicit OTEL overrides win;
no global dotfiles/config changes or input injection into existing panes. The
registry supplies the enabled core's current arguments, independently of Auto-run.
Settings take effect in new terminals. Unsupported shells and explicit custom
split commands retain their original startup behavior. See
[Codex manual-launch boundaries](plugins/codex.md#manual-launch-in-a-ctrlx-terminal).

### Retrospective telemetry consumers (issue #598)

Two **aggregate** consumers built on the same OTEL stream, surfacing data that outlives a live session.

- **End-of-session recap** — `SessionRecap` (`CtrlxNetworking`) is a snapshot of the session's accumulated telemetry (tokens, cost, commits, active time, tools, lines). `AppCoordinator` stamps it onto `PaneState.recap` when a turn finishes (`doneWorking`) — cleared when a new turn starts (`working`) or the session ends — and pushes a one-shot recap notification on `sessionEnd` (`finalizeEndedSession`, reusing `NotificationSpec` → `handlePluginNotification`). The recap card renders in iOS `SessionInfoView`; the Mac surfaces it via the desktop-notification push. Shared formatting (`recapDetailLine`) lives in `CtrlxCommon`.
- **iOS reply-after-stop summary persistence (issue #707)** — the agent's last-message summary shown in the iOS reply box (`StopResponseView`) rides the transient `AgentState.doneWorking(summary:)`, which viewing the session flips to `.idle` (`markHandled`), so navigating away and back used to lose it. `SessionStore.lastTurnSummaryByPane` caches it per pane with the **same lifecycle as `PaneState.recap`** (set on `doneWorking`, cleared on `working`/session-end) so it survives the handled-flip and re-entry; `SessionDetailService.replyForm` falls back to that cache, then to `recap.summary` for a fresh reconnect where the cache is empty. Telemetry-independent, so it works even when no recap was stamped. (The expanded summary also scrolls within a capped height so a long message isn't cropped.)
- **Cost/usage overview** — `UsageAggregationStore` (`CtrlxServerFeature/Telemetry/UsageAggregationStore.swift`) is an `actor` persisting per-`(project, day)` totals as JSON under `~/.ctrlx/state/usage-aggregates.json` (so they survive session end **and** app restart). It folds each telemetry snapshot into the bucket as a *delta* against a persisted per-session baseline — cumulative OTEL counters are attributed to the day they occur, with no double-counting across a restart. `overview(asOf:)` builds the wire `UsageOverview` (today totals, a top-N per-project ranking, a per-day trend). It rides the existing `SessionStateMessage` as an optional field (`usageOverview`, `decodeIfPresent`-friendly like `agentProjects`), is shown atop the iOS session list and Mac sidebar as a collapsed one-line "Today" cell (`UsageOverviewView` in `CtrlxCommon` — a disclosure chevron expands it in place to the Projects/Recent-days details, transient state, always starts collapsed), and powers the Mac menu-bar "today" total.

### ConnectedViewerManager (`CtrlxServerFeature/Services/ConnectedViewerManager.swift`)

`@Observable @MainActor` managing connections to all paired Viewer devices.

**Features:**
- Wraps multiple `ConnectedViewer` instances (one per paired Viewer)
- Broadcasts shared state, while terminal payloads are routed to pane subscribers
- Combined state for UI display (`combinedState`)
- Auto-reconnect on system wake

**Broadcasting Methods:**
- `sendAgentSessionStatusToAll()` - forward plugin session state
- `sendTerminalStream(_:to:)` - forward terminal data to an explicit Viewer-ID set
- `pushSessionStateToAll()` - sync session state

**Callbacks (set by AppCoordinator):**
- `onCommand` - handle commands from a paired Mac or iOS Viewer
- `onSessionStateRequest` - provide current session state
- `onPartnerKeyReceived` - persist E2EE partner keys

### ConnectedViewer (`CtrlxServerFeature/Services/ConnectedViewer.swift`)

`@Observable @MainActor` Host-side WebSocket connection to a paired Mac or iOS Viewer.

**States:** `disconnected` → `connecting` → `connected` | `reconnecting(attempt)` | `error`

- Manages WebSocket lifecycle with relay server
- E2EE encryption per device
- Auto-reconnects with exponential backoff
- Routes encrypted agent state, commands/responses, terminal streams and session snapshots

### PairingManager (`CtrlxServerFeature/Services/PairingManager.swift`)

`@Observable @MainActor` managing device pairing.

**States:** `idle` → `generatingCode` → `waitingForPairing(code, expiresAt)` | `error`

- Generates 6-char alphanumeric codes (excludes I and O)
- Registers with external server (includes E2EE public key)
- Polls for pairing completion
- Supports multiple paired devices
- `onDevicePaired` callback triggers connection to newly paired device
- Partner public keys received via WebSocket after pairing

### TerminalStreamService (`CtrlxServerFeature/Services/TerminalStreamService.swift`)

`@Observable @MainActor` streaming terminal data to subscribed Viewer devices.

**Batching:** 16ms fixed cadence, 8KB max batch size

**Multi-Device Support:**
- Idempotent Viewer-ID ownership set per pane
- `startStreaming()` reuses an existing stream and stages a private bootstrap for the requester
- A joining Viewer's snapshot boundary is itself queued with terminal data, so unprocessed pre-boundary bytes cannot re-enter its private buffer
- Bootstrap success waits for initial state and all pre-barrier bytes to enter the encrypted send chain
- `stopStreaming()` removes one owner; the stream stops when no owners remain
- `stopStreaming(force: true)` bypasses ownership for system-level cleanup
- `stopAllStreams()` / `stopStreamsForClosedPanes()` always use `force: true`

**Message Types:** `initialState`, `dataChunk`, `dimensionChange`, `streamEnd`

### TmuxCommandExecutor (`CtrlxServerFeature/Services/TmuxCommandExecutor.swift`)

Actor executing commands from paired Mac/iOS Viewers.

- Receives `CommandMessage` from `ConnectedViewerManager`
- Dispatches to `TmuxService` (sendKeys, sendInterrupt, etc.)
- Returns `CommandResponseMessage` (success/failure)

### Plugin installation and settings

`PluginCore.install(configRoot:)`, `uninstall` and `installStatus` are the
shared contract in `CtrlxPluginProtocol/PluginCore.swift`. Built-in cores own
their CLI installation implementations: `ClaudeCodeCLIInstaller.swift` and
`CodexCLIInstaller.swift` in their respective core modules. Config roots are
scoped by the plugin, not hard-coded into shared settings UI.

The built-in cores also expose the local-only `AgentPluginMaintenance`
capability. It reads the **Agent-side** manifest shipped in this app
(`plugin/codex/ctrlx/.codex-plugin/plugin.json` or
`plugin/ctrlx/.claude-plugin/plugin.json`), not the sidecar manifest version.
After startup, `AgentPluginInstallations` checks enabled local agents and their
configured roots asynchronously. Known older installed versions produce a
dismissible banner linking to that agent's settings. The check runs once per
launch; unknown versions and query failures are not classified as up to date.
No remote Host or Agent process is changed by checking.

Settings shows each configuration folder's installed and bundled versions,
Check, Install/Reinstall, and Uninstall. Operations are serialized per folder
across settings views. Reinstall validates the marketplace source first and
verifies the installed version afterward. Codex marketplace queries check the
exit status before decoding stdout, preserving the CLI's exit code and stderr.
Successful queries with invalid JSON or an unsupported schema report the failing
command and expected format; replacement does not proceed without source verification.
Codex 0.162.1 `plugin add` refreshes
even a same-version cache; an `already installed` response is not treated as a
reinstall. Claude Code 2.1.276 has no force flag: refresh the local marketplace,
uninstall the exact user-scoped `ctrlx@ctrlx` with `--keep-data`, then install
and verify it. If the install fails after removal, the error explicitly reports
the partial operation and settings re-queries the remaining state for retry.
Other plugins, authentication and running Agent sessions are not removed or
restarted. Successful changes display a reminder to restart the corresponding
Agent sessions, not the CtrlX app. Older CLIs that reject these commands fail
visibly rather than falling back to editing agent configuration files.

`PluginRegistry` owns enabled cores; `PluginRegistryStore.swift` persists
registry entries, and `CtrlxPaths` defines the state layout. Per-agent settings
are decoded by `ClaudeCodeSettings`, `CodexSettings`, or the sidecar's settings
contract. The old `PluginService` / `CodexPluginInstaller` are not live services.

External bundle installation/update lives in
`CtrlxServerFeature/Distribution/`. Installing a CtrlX sidecar bundle and
installing its event bridge into an agent are distinct operations. See
[sidecar authoring](plugins/sidecar-authoring.md) and the plugin's own README.

### Start an agent window in an existing session (Mac and iOS)

Mac session tab strips (local and Viewer) also expose **+ → New Agent…**.
iOS exposes **New Agent…** in the title's window-switcher menu, alongside
**New Terminal** (formerly "New Window"). Both use `CtrlxCommon.NewAgentTabPanel`;
Mac presents a popover, iOS an adaptive-width sheet without a nested navigation
container. The iOS path inherits its selected pane's cwd, not a stale Host focus.
Each enabled Host agent has its own card, editable directory and Start button;
there is no agent picker or separate hard-coded list. Codex is placed first
when available. The directory starts from the last focused terminal in this
Host/session (falling back to the selected window's active pane, then `~/`).
**Choose Directory…** reuses the directory browser below. Merely opening the
panel does no directory I/O. Cards capture their Host/session when opened;
editing a path never expands it using the Viewer's home.

Starting a card creates a **window/tab in the existing tmux session**, not a
new session or split pane. `TmuxWindowCreation` shares Host-side
`SessionLaunchPreparation` and the same tmux startup-command helper as session
creation, retaining telemetry arguments, plugin environment and the opted-in
editor override. Disabled Auto-run/unavailable agents/invalid directories fail
before creation; errors are shown rather than silently falling back to a shell.
Pending creation disables all cards. A delayed state push does not repeat the
launch or switch away from a different session the user navigated to.

The additive `CreateTmuxWindow.pluginID` is sent only after the Host advertises
`SessionStateMessage.supportsAgentWindowLaunch == true`, rechecked on Start.
Older Hosts get an upgrade message, not an agent request they would ignore.
Old requests without `pluginID` keep ordinary Terminal behavior. Both Host and
the Viewer (Mac/iOS) need this update; the opaque Relay needs no changes.
iOS follows the returned pane as state arrives, without a fixed sleep or retrying
creation. Manually changing windows or leaving the screen cancels that pending
selection. Ordinary Terminal requests still omit `pluginID`, and the Host creates
them through `TmuxService`, including its manual Codex shell integration and
Claude telemetry environment. No agent command/config is constructed by iOS.

### Fork a native Agent conversation (Mac/iOS)

Right-click a local or Viewer terminal-window tab → **Fork → In Current
Directory / In New Worktree…**. Codex and Claude Code implement the optional
`AgentSessionForking` capability; sidecars retain their existing wire contract.
Both modes open the shared naming panel before creation. The entered name is
used for the new window; current-directory names may contain spaces or Unicode.
Multiple Agent panes require a source choice, defaulting to native focus or the active pane.
Detection without a native conversation UUID is not enough to enable Fork.
Unavailable Fork actions show whether the Host is offline/outdated, the native
conversation ID is unverified, or the working directory is missing.

The Host stores verified native conversation identities in
`<stateRoot>/agent-session-identities.json`, binding each UUID to its pane,
session, stable window, plugin, and kernel process identity (PID + start time).
After an app restart, process reconciliation restores only that UUID when exactly
one outermost matching Agent process is still alive. Nested helpers such as a
Codex TUI's `codex app-server` do not count as independent sessions; their startup
or exit does not invalidate the main process identity. A reused PID/pane,
mismatched window or Agent, and multiple independent matching processes fail
closed. A cached helper PID cannot substitute for the main process. Restoration
does not replay old working, approval, telemetry, or notification state; recovered
identities are rechecked during reconciliation and Fork preparation. Legacy correlation files
without process identity are not trusted for restoration. When a Codex pane has
no valid cached identity (notably a newly forked, idle TUI), the Host inspects only
its unique main process's writable rollout file via native file-descriptor APIs.
The bounded first `session_meta` record must identify a CLI conversation and match
the filename UUID; the same writer and process start identity must still be live
after reading. Parent IDs in `codex fork` arguments, read-only history files and
ambiguous writers are never used. Successful recovery uses the same cache, so
subsequent reconciliations need no further file-descriptor inspection. A native
event arriving during recovery always takes precedence. Writes are serialized per pane and
do not block live status/notification delivery.

Workspace checkpoints cache only successfully verified resume descriptors for
the same source and process incarnation. A failed native-history lookup remains
visible in the saved pane and is retried on later checkpoints, because the
history file may be written after the Agent's initial lifecycle notification.

On iOS, open the window-title menu → **Fork → In Current Directory / In New
Worktree…**. The selected pane is the default source when there are multiple
recognized Agents. Mac and iOS share `AgentForkPanel`, including worktree review,
dirty-file acknowledgement and retrying the same request UUID. The iPhone sends
the captured source to its specific Host; it never constructs an Agent command
or touches local Git. Creation is serialized with New Terminal/New Agent. The
returned pane is selected when state arrives, unless the user has manually
changed windows or left the screen while creation was pending.

`AgentForkService` rechecks the captured pane/window/session/Agent UUID/cwd and
workspace incarnation through preparation, checkout and cached retries. Sources
without the optional workspace identity still decode; the Host captures its
current identity before asynchronous work. Actual creation guards both source
pane and parent session in the tmux command queue. Mac/iOS retain the original
Viewer binding and reject replaced sessions before adopting the returned pane
or issuing delayed Fit. It launches in a new window of the same tmux session using
`codex fork <UUID> -C <cwd>` or `claude --resume <UUID> --fork-session`, preserving
the source's config root and existing telemetry shell integration. Configuration
overrides are applied to the Agent invocation after login startup files, scoped
to that invocation and never passed to the parent shell through tmux `-e`; the
default Claude root explicitly unsets `CLAUDE_CONFIG_DIR`. After the Agent exits,
ordinary launches retain the shell's normal configuration root.
Fork explicitly starts the same Host login shell used to validate its command,
independently of Codex telemetry or the tmux session's custom shell defaults.
POSIX-style login shells (including zsh and bash) are supported; unsupported
shells fail before creating the new pane rather than restoring from a wrong root.
Ordinary Terminal windows keep their existing tmux startup behavior.
Fork is an explicit action, independent of Auto-run. It does not send `/fork`,
use the last session, send a continuation prompt, or copy source telemetry/approval
state.
All UI-facing Fork callbacks retain explicit `@MainActor` function types,
including the shared Mac/iOS panel and Host refresh/launch callbacks. Network
callers and suspended I/O must hop back before accessing pane/UI state.

Worktrees start from the source workspace's HEAD, with branch `<name>` at
the primary repository's `.worktrees/<name>` and the same window name. An existing
branch or directory is rejected with a prompt to choose another name; the panel
keeps the draft, and editing the name creates a new request UUID rather than
replaying a failed request. Names are single safe Git branch/path components;
no prefix or automatic suffix is added. Linked source worktrees and source
subdirectories are supported. A local `info/exclude` rule is added when needed,
then Git's effective ignore status is verified before checkout. If `.gitignore`
negation overrides the rule, Fork fails with an actionable message rather than
editing tracked ignore rules or creating a worktree that `git add .` can stage.
Dirty/untracked files require acknowledgement and are never copied; ignored
files are not copied either. Tab close never removes a worktree. Partial checkout
or Agent-launch errors report retained paths/panes rather than deleting them.

Viewer commands require `supportsAgentFork == true`. Preparation is read-only;
the Host creates Git/tmux state. A request UUID deduplicates concurrent/repeated
delivery (including partial failures; last 128 completed requests per Host
process). The Host and Viewer (Mac/iOS) need the feature; the opaque Relay needs
no update.

### Start a session in an arbitrary directory

Mac (local and Viewer) and iOS expose **New Session → Start in Directory…**.
The shared form starts at `~/` **on the target Host**. Click a folder to enter
it, use Home/Up to navigate, or type/paste an absolute path or `~/…` to complete
the final component. Existing directory paths list their children. Hidden
folders are optional (typing a dot-prefixed component also reveals matches).
Click **Start in This Directory** to launch the selected agent; browsing and
pressing Return in the path field never create sessions. Project history is
only a shortcut list, not an allowlist; a directory need not already appear
there. No directories are
created automatically. Do not add shell quotes around paths with spaces.

Enable **Create a new branch and worktree** to start a fresh Agent session in
a new checkout. The form shares Fork's name validation, branch/path/HEAD preview
and dirty-file acknowledgement. The name is used for the new session, its first
window, the branch and the primary repository's `.worktrees/<name>` directory.
The source may be a subdirectory or linked worktree; checkout starts at that
source's HEAD and retains its relative working directory. Uncommitted, untracked
and ignored files are not copied. Existing branches/directories are rejected;
HEAD changes require a refreshed preview. Agent availability is checked before
checkout, then its launch command is resolved again in the new directory. Closing
the session leaves the worktree in place; partial failures report retained paths.

`PrepareSessionWorktree` performs read-only Host inspection; the optional
`CreateTmuxSession.worktree` carries the reviewed HEAD, name and acknowledgement.
Both commands require `supportsSessionWorktrees`, including a transport-level
gate so an older Host cannot silently ignore the worktree option. Preview and
checkout run outside the keyboard receive loop. Changing the Host/path or
refreshing invalidates the preview and acknowledgement. This starts a new
conversation and works with any launchable plugin; no existing Agent conversation
or native Fork support is required. Mac local, Mac Viewer and iOS share this flow;
remote use requires updated Host and Viewer apps, with no Relay change.

On iOS, New Session uses a large system sheet for both project history and directory
browsing, rather than starting at half height. Project search is present only in
project-history mode; directory mode keeps its own path field without the unrelated
search toolbar. Back returns to the project list with the search text preserved.
Cancel and the system swipe-to-dismiss remain available; directory lookup and
Agent launch behavior are unchanged.

The Mac local, Mac Viewer and iOS directory browsers offer **New Folder** beside Home/Up. It is
enabled only for an exact, successfully listed directory on a Host advertising
`supportsDirectoryCreation`; older Hosts show an update hint and receive no
creation command. The name prompt displays the chosen parent. Creation is an
acknowledged `CreateSessionDirectory` filesystem operation on the Host actor,
not terminal input: it accepts one literal child name, creates no intermediate
parents, and fails for existing files/directories/symlinks or insufficient
permissions. Success enters the new directory without launching a session.
Path navigation and Agent launch are disabled while creation is pending;
late replies cannot redirect a different Host/path or a reopened form. Both
the Viewer and Host Mac need the update for remote use; the encrypted Relay remains unchanged.

`AgentLaunchDefaults` makes Codex the initial choice on iOS, Mac local and Mac
Viewer, and in Mac Agents settings. An explicit selection is preserved; when
Codex is unavailable on that Host, the picker falls back to its first available
agent (or has no selection if empty). Existing project identities are unchanged.
New `CreateTmuxSession` requests and `project.start` also default to Codex;
`ctrlx start-project --agent <plugin-id>` overrides it. Legacy wire payloads
without an agent identity retain their historical Claude decoding behavior.

`SessionLaunchRequest` and `DirectorySessionForm` are shared in `CtrlxCommon`.
Remote choices use presentations cached **per Host**, so connecting to Home
cannot overwrite Office's available-agent list. `SessionLaunchPreparation` is
the common Host-side path for local/remote creation: `SessionDirectoryClient`
expands `~`, validates directory access on an actor, and calls the selected
plugin's existing `commandForLaunch` before any tmux mutation. Command, arguments
and environment are preserved, including Codex's runtime OTEL overrides when
Export Telemetry is enabled and the receiver is available. This directory-launch
flow does not change global Codex config; manual commands are handled separately
by the shell-local integration described above.

Explicit directory requests set `CreateTmuxSession.requireAgentLaunch = true`.
Unavailable plugins or disabled Auto-run produce an error instead of a
successful bare-shell session. Existing Projects retain optional auto-run;
New Terminal remains a shell in the Host's home. Missing wire flags decode as
`false` for older viewers. Update both the launching client and the Host for
the new flow/strict validation; the opaque Relay requires no update.

iOS New Terminal uses `session` as its default session name. On upgrade, a
one-time settings migration replaces the old saved default `claude` with
`session`, preserving other saved names and leaving existing tmux sessions
untouched. After migration, all explicit name changes are preserved, including
`claude`. This naming fix requires only an iOS update.

Directory browsing uses `ListSessionDirectories` / the optional
`CommandResponseMessage.directoryListing` over the existing encrypted command
channel, not a shell command or a recursive filesystem scan. Both local and
remote requests use `SessionDirectoryClient.list` on the Host's filesystem
actor; only direct child directories and directory symlinks are returned, no
file content. Replies are capped at 200 entries / 128 KiB of encoded entries;
truncated results ask the user to refine the path. Permission and missing-path
errors stay visible, with Refresh to retry and manual entry still available.

The Host enumerates direct POSIX directory entries, not Foundation URL-property
prefetch. Known directory entries (including mount points) need no child metadata
request: an unresponsive NFS mount inside Home cannot block the whole list just
to determine its type. Hidden-name filtering and partial-path matching run before
any fallback lookup; only symlinks and unknown entry types require `fstatat` to
preserve directory-only results. Opening a mount or following a directory link
still requires the underlying filesystem to respond; this is not a general I/O
timeout. The selected directory is validated as before, user-visible alias paths
are preserved, and cancellation/error/response-size limits remain unchanged.
An optional read-only real-Home probe can be run with
`CTRLX_VERIFY_HOME_DIRECTORY=1 ./scripts/unit-tests.sh -- --filter SessionDirectoryBrowsingTests`.
On the affected Mac, the real resolver returned 14 Home directory entries in
13.5 ms without restarting OrbStack. Directory/launch/capability regressions and
the Mac Release app build passed; the popover was not tested in an installed app.

`SessionStateMessage.supportsDirectoryBrowsing` is an optional per-Host
capability, forwarded by `withPairId` and cleared on disconnect/downgrade.
Older Hosts receive no new lookup command and retain manual entry. iOS and Mac
Viewer bind each source to the selected Host connection. The SwiftUI browser
uses `.task(id:)`, 250 ms input debounce, cancellation checks and unique request
ownership, so a late reply (including A → B → A) cannot overwrite current
results. No navigation container is added. Update Host and viewer apps for
browsing; no Relay deployment, SwiftTerm change, or agent-launch change is needed.

Regression coverage: `SessionLaunchRequestTests`, `SessionLaunchAgentTests`,
`DirectorySessionCommandTests`, `SessionLaunchPreparationTests`,
`SessionDirectoryResolverTests`, `SessionDirectoryBrowsingTests`,
`SessionDirectoryListingTests`, `SessionDirectoryBrowseStateTests`,
`SessionDirectoryCapabilityTests`, `SessionWorktreeStateTests`,
`SessionWorktreePreparationTests`, `AgentForkWorktreeTests`,
`TerminalPasteTransportTests`, and the existing Codex OTEL/launch tests.

### Agent project discovery and command resolution

`ClaudeCodePluginCore/ClaudeCodeScanner.swift` scans Claude's config/project
roots, including additional configured roots. `CodexPluginCore/CodexScanner.swift`
reads bounded date-partitioned rollout headers under the selected Codex home and
groups existing project directories by cwd. Both emit `AgentProject` tagged by
`pluginID`; their owning core controls scheduling and refresh.

Cores push projects through `PluginHost.setProjects`; `AppCoordinator` merges
per-plugin lists. Sidecar project discovery uses the same contract. There is no
Host-owned pair of legacy `ClaudeProjectScanner` / `CodexProjectScanner` services.

New Session labels this list **Recent Directories** on Mac and iOS and explains
that entries come from agent history on the selected Host. Rows keep their path
and agent badge and show the recorded last-used time when available. Identity
remains `(pluginID, path)`: the same directory used by two agents has two launch
choices. Choosing a row starts a new session there; it does not resume an old
conversation. Discovery, sorting and per-plugin auto-run settings are unchanged.

Launch commands come from the owning core's `commandForLaunch` and per-plugin
settings, with Host login-shell path validation. Ordinary shell launch, explicit
Agent launch and Fork have different preconditions; see the launch/Fork sections
above. Do not restore `AppSettings.commandPath(for: CodingAgent)` or infer an
agent from a window's display name.

### TerminalLauncher (`CtrlxServerFeature/Services/TerminalLauncher.swift`)

`@MainActor` utility for launching tmux sessions in external terminals.

- Supports Terminal.app, iTerm2, Warp, Kitty, Alacritty, custom
- Attaches to existing tmux sessions
- Used from iOS "open in terminal" commands

### DockIconService (`CtrlxServerFeature/Managers/DockIconManager.swift`)

`@DependencyClient` wrapping a main-actor `LiveDockIconManager`, managing
dock icon visibility and the dock tile badge.

- App runs as accessory (no dock icon) when no windows visible
- Switches to regular mode when windows open
- Ignores menu bar and popover windows
- Owns the badge (`setBadgeCount`): `NSDockTile.badgeLabel`'s setter dedups
  unchanged values in-process while the Dock discards tile state on
  `.accessory` transitions, so the manager clears the label before every set
  and re-applies it on policy updates (issue #217)

**Mac completion/read handling:** `VisiblePaneAttentionModifier` is attached to
each rendered terminal tile in `WindowPaneLayoutView` and
`RemoteWindowPaneLayoutView`, including both split sides and fallback layouts.
It observes that pane's agent state (not the global pending count), checks on
mount and app activation, and only acknowledges while mounted and the app is
active. Hidden file/browser tabs do not acknowledge terminal tasks. Remote
readers also require a connected host/relay and scope pane IDs by host.
`VisiblePaneAttention` rechecks the live store and only clears `doneWorking` to
`idle`; permission/question/plan forms and manual Set State overrides remain
untouched. A real local clear pushes the existing session snapshot/badge update;
a remote clear updates `SessionStore` and sends the existing `MarkHandled`
command to its host. Dock totals and task markers continue to derive from these
same stores. Regression coverage: `VisiblePaneAttentionTests`.

Queued `MarkHandled` and Yolo toggles retain the pane identity observed by the
caller. Capable Viewers reject a retired binding before transport, and the Host
checks the supplied identity before clearing attention or enabling auto-approval.
iOS detail services retain their original binding through teardown; an old service
cannot clear a replacement pane's local attention state. Live moves of the same
physical pane remain valid, and older peers keep the optional-identity path.

### SleepPreventionService (`CtrlxServerFeature/Managers/SleepPreventionManager.swift`)

`@DependencyClient` wrapping the `LiveSleepPreventionManager` actor for IOKit
assertions during active sessions.

- Uses IOKit `IOPMAssertionCreateWithName` assertions
- Enabled/disabled via settings toggle
- Automatically releases when all sessions end

### LoginItemService (`CtrlxServerFeature/Services/LoginItemService.swift`)

`@DependencyClient` wrapping launch-at-login management.

- Uses `SMAppService.mainApp` for registration
- Appears in System Settings > General > Login Items

### GitWorkbenchProviderClient (`CtrlxServerFeature/Services/GitWorkbenchProviderClient.swift`)

`@Dependency` factory that vends a `GitWorkbenchProvider` for the Git tab (the
[GitWorkbench](https://github.com/gpambrozio/GitWorkbench) component embedded to
the right of the file explorer).

- `provider(repositoryURL:)` returns a provider rooted at a repo directory (the
  same folder the file explorer uses for the session)
- `liveValue` → `CLIGitProvider` (system `git` CLI, from `GitWorkbenchGitKit`)
- `mock` / `previewValue` / `testValue` → `MockGitProvider` (stable fixtures,
  zero latency); the E2E entry point installs `.mock` under `--e2e-test`
- `MainView` retains one `GitWorkbenchStore` per session (`gitWorkbenchStores`),
  rebuilt when the working directory changes, so the git UI state survives
  tab/session switches like `FileBrowserState`

**Changes-tab file actions** (`GitBrowserView`): right-clicking a changed file
shows the *same* native context menu as the file explorer, and double-clicking
opens it in its default app.

- The store's `WorkbenchConfiguration.repositoryURL` is set to the working-tree
  root so GitWorkbench's `onChangesRightClick` / `onChangesDoubleClick` hooks
  hand back **absolute** file URLs.
- The right-click menu is built by the shared `fileContextMenuItems(…)`
  (extracted from `FileContextMenu`, also used by the file tree / search list /
  tab strips) and shown via `presentStableContextMenu(items:with:for:)`, which
  goes through AppKit's `NSMenu.popUpContextMenu(_:with:for:)`. GitWorkbench
  reports the click from `rightMouseDown`; the AppKit contextual-menu path keeps
  the menu open across the press/release and exposes it to accessibility,
  whereas a bare `NSMenu.popUp` would be dismissed by the trailing mouse-up.
- `MainView.gitPane` supplies the "Open in New Tab" / "Show in File Explorer"
  handlers (the reveal logic is the shared `revealInFileExplorer`) so the menu
  reaches full parity with the file explorer.

### UpdaterController (`CtrlxServerFeature/Services/UpdaterController.swift`)

`@Observable @MainActor` wrapping Sparkle updater for SwiftUI.

- Exposes `canCheckForUpdates` binding
- `checkForUpdates()` action

### PluginUpdateManager (`CtrlxServerFeature/Distribution/PluginUpdateManager.swift`)

`@Observable @MainActor` orchestrating auto-update for URL-installed sidecar
plugins (spec `docs/superpowers/specs/2026-07-25-plugin-auto-update-design.md`).
Init-injected `Callbacks` struct wired by `AppCoordinator` at plugin boot;
exposed as `coordinator.pluginUpdateManager`.

- Triggers: first launch after an app-version change, >24h staleness at launch,
  and a daily loop while running (all disabled under `--e2e-test`); per-plugin
  `autoUpdate` toggle and manual `checkNow` (throwing `PluginUpdateChecker.checkOne`
  so manual failures surface inline; automatic checks stay best-effort silent).
- Applies through `PluginInstaller.install`, then hot-restarts the sidecar only
  when the plugin has no active sessions and re-runs the `install` RPC wherever
  `install_status` reports installed; busy plugins get `needsBridgeRefresh`
  persisted on their registry entry, swept at the next launch.
- All check/apply work is serialized on one run chain (`applyUpdateSerialized`
  is the CLI's out-of-band entry point); source-changed updates are never
  auto-installed. Observable `restartNotices`/`inlineStatus`/`lastCheckDate`
  drive the Agents settings banner and Updates section.
- `finishReinstall(id)` is the out-of-band reinstall hook: any install that
  replaces an already-installed plugin outside the manager's own apply flow
  (the source-changed Review… trust sheet, CLI `ctrlx plugin install`, the
  Add Plugin sheet, zip installs) triggers the same post-install steps via
  `AppCoordinator.installPluginFromURL`/`installPluginFromZip` — hot-restart
  if idle + bridge refresh, else the deferred flag. The manager's own install
  callback opts out (`postInstall: false`) to avoid double-applying.
- Notice wording: `needsAppRestart == false` means the sidecar was hot-swapped
  while nothing was running, so banner/inline/notification show a plain
  "updated to X" with no restart advice; only the busy/deferred path says
  "restart CtrlX and your <agent> sessions".

### LayoutStore (`CtrlxServerFeature/Services/LayoutPersistence/LayoutStore.swift`)

`@DependencyClient` that persists per-folder workbench layouts (open file/browser
tabs, split arrangement, sidebar width) so a session restores its workbench
across app restarts and a new session on a known folder inherits the folder's
last-known layout. See `docs/folder-layout-persistence-plan.md`.

- One record per folder, keyed by `(host, folder)` (`SavedFolderRecord`);
  `record(for:)` returns the folder's layout for both cold-launch restore and
  new-session seeding. Keyed by folder — not tmux session name — so a recycled
  session name picks up the folder's current layout, not a dead session's stale
  one. Two sessions on a folder share the record (most-recent write wins).
- `save` / `remove` / `prune`; `liveValue` writes a single JSON file under the
  CtrlX state root (`~/.ctrlx/state/Layouts/`, or `--ctrlx-state-root`
  under E2E), `inMemory()` for previews/tests.
- `MainView` drives it: `seedLayoutIfNeeded()` restores once-while-empty on
  session selection/launch; a 2s `.task` auto-saves changed layouts via
  `persistChangedLayouts()`. `LayoutSnapshotMapper` translates the live
  `SessionFileTabsState` ⇄ the `SavedFolderLayout` snapshot.

### Worktree merge status

The Mac Host's existing five-second pane validation also reads Git worktree
metadata. `WorktreeStatusReader` groups live terminal and visible local Git-tab
directories by their canonical common Git directory, enumerates all existing
worktrees (including those without sessions), and compares their captured HEADs
with each repository's unique **local** `main` or `master` branch. Exactly one
must exist: both present is ambiguous even when their tips match; neither present
is unavailable. Remote-tracking refs and similarly prefixed names are not bases.
Counts use commit ancestry (`rev-list --count <base>..HEAD`),
not upstream tracking, dirty files, or squash/cherry-pick patch equivalence.
Successful counts are cached by repository/base commit/HEAD; a change to the base refreshes
all affected comparisons. There is no fetch, merge or filesystem mutation.
Detached HEAD, missing/ambiguous/unborn bases and read/comparison errors are unavailable
states, never a zero count. Prunable/missing and bare worktree entries are omitted.
Discovery covers repositories referenced by live panes or visible local Git tabs;
this is not a disk scan or a persistent catalog of repositories whose sessions
and Git tabs have all closed.

`PaneState.gitWorktreePath` joins a pane to the Host's canonical worktree path.
For absorbed submodules and `--separate-git-dir` repositories, Git may list the
primary worktree by its metadata directory. The Host matches an observed checkout
whose own Git directory equals the common directory, or lets Git resolve a
submodule's `core.worktree`. A separate Git directory without that reverse pointer
cannot locate an unobserved primary checkout; only that entry becomes unavailable,
and linked worktrees retain their branches and counts. The common Git directory
remains the repository key.
`SessionStateMessage.worktreeRepositories` carries one optional repository list
per snapshot, including each repository's optional `baseBranch`. Older Host
snapshots omit the base name and their successful counts refer to main.
Counts against master use an additive `pendingBaseCommitCount` wire field;
the original `pendingCommitCount` key remains main-only. Older Viewers therefore
show master comparisons as unavailable instead of labeling them as main.
A changed count or base triggers a Viewer push even when the terminal's
branch name did not change. These fields are additive; old snapshots omit them,
old Viewers ignore them, and no new command or Relay change is required.
`SessionStore` scopes this metadata by Host pair ID and clears it on downgrade
or disconnect. Viewers never inspect those paths on their own filesystem.

Mac local/Viewer sidebars and the iOS session list show a compact status button
at the trailing edge of each session: an orange branch for pending commits, a
secondary checkmark when all selected worktrees are in their own local base,
or a dash when comparison is unavailable. Sessions without Git metadata omit
the button. Mac hovering shows the status/count without increasing row height;
iOS keeps a 44-point tap target within the session row. These buttons are
independent of configured sidebar fields and notification state.
A session's terminal panes select worktrees by their current directory, including
ordinary repositories' primary checkouts. Non-Git paths contribute no status;
sessions with only those paths omit the icon. Several panes in one worktree count
it once. Different worktrees and repositories compare independently. Any pending
worktree takes icon priority, with a tooltip note if other comparisons are
unavailable; without pending commits, any unavailable comparison takes priority
over the merged checkmark. The detail list names each repository's base.
Status buttons
open the complete associated repository list; the Host section's Worktrees
entry remains available when everything is merged. The local Mac Git page also
has a Worktrees entry. Mac uses a popover and iOS a sheet; their contents follow
incoming snapshots. A missing comparison shows its reason instead of claiming
that the branch is merged. “No commits pending merge” is not a clean-worktree or
safe-to-delete assertion.

## Shared Viewer services (Mac and iOS)

### ViewerConnectionManager / ViewerConnection (`CtrlxCommon/Services/`)

`@Observable @MainActor` connection manager and per-Host connection. These are
shared by Mac Viewer and iOS, not an iOS-only `RelayClient`.

- Own connections by `pairId`, dispatch commands to the selected Host.
- Handle encrypted session/agent state, terminal streams and command responses.
- Negotiate peer compatibility and invalidate pending work on connection changes.
- Expose separate Host-presence and Relay-transport interruption callbacks.

### SessionStore (`CtrlxCommon/Services/SessionStore.swift`)

`@Observable @MainActor` state received from multiple Hosts.

- Pane identity is `PaneKey(pairId, paneId)`, never a bare tmux pane ID.
- Tracks per-Host projects, launch choices, capabilities and shared terminal layouts.
- Applies session snapshots and agent-state updates; disconnect handling clears
  Host-specific live state/capabilities.
- Keeps last-turn summaries through the handled-state transition.

The platform UI owns selection and viewport state; this shared store does not
make every Viewer layout or tab selection global.

## Utilities

### ProcessRunner (`CtrlxCommon/Services/ProcessRunner.swift`)

`@DependencyClient` for asynchronous external processes; macOS provides the live
implementation, and tests can inject process results without launching commands.

- Async execution, stdout/stderr collection
- Thread-safe `OutputCollector` with NSLock
- Returns `ProcessResult` (exit code, stdout, stderr)

## Models

### AgentSession / AgentState / PluginPresentation

Current wire types are in `CtrlxNetworking/Models/AgentSession.swift`,
`AgentState.swift` and `Plugin/PluginPresentation.swift`.

- `AgentSession` identifies the pane and owning `pluginID`, with one
  `AgentState` for lifecycle and open response forms.
- `isWorking` / `needsAttention` are derived state, not parallel state machines.
- `PluginPresentation` supplies agent display metadata; `AgentProject` carries
  discovered project identity.
- Native conversation IDs used for telemetry/Fork are distinct from a tmux pane ID.

The former `CodingAgent` enum is removed. Add agents through plugin contracts
and manifests rather than adding shared enum cases.

### PaneInfo (`CtrlxServerFeature/Models/PaneInfo.swift`)

```swift
id, target, sessionName, windowIndex, paneIndex
command, currentPath, width, height, isActive
```

### AppSettings (`CtrlxServerFeature/Models/Settings.swift`)

`@Observable @MainActor` with UserDefaults:

- **Terminal:** fontName, fontSize, scrollbackLines, theme
- **Behavior:** openPanesWindowOnLaunch, showStatusBar, autoConnectToServer, preventSleepDuringSessions
- **Tmux:** tmuxPath, tmuxSocket
- **Remote Access:** externalServerURL, deviceId, pairedViewers, pairedHosts
- **Coding agents:** owned by plugin settings/registry, not per-agent fields in AppSettings
- **Prompt editor (Ctrl-G):** editorOverrideMode (`ask` / `overrideInCtrlxSessions` / `useMyEditor`) — see [Editor Override](#editor-override-ctrl-g)

### PairedViewer / PairedHost

`PairedViewer` in `CtrlxServerFeature/Models/Settings.swift` describes a peer
viewing this Host. `PairedHost` in `CtrlxNetworking/Models/PairedHost.swift`
describes a Host this client views. Keep role, pair identity and key metadata
distinct; both peers may be Macs.

## Push Notifications

Codex `PreToolUse` events for `request_user_input` and `request_user_input_async`
produce a question notification on the Host, independently of terminal visibility
or focus. The plugin deduplicates by `(session_id, tool_use_id)` and leaves Agent
state and response forms unchanged: an asynchronous question does not stop the
Agent. This uses the existing wildcard hook bridge, not terminal polling or
question auto-expansion. The hook fields and both tools were checked against
[Codex 0.162.1](https://github.com/openai/codex/blob/rust-v0.162.1/codex-rs/core/src/hook_runtime.rs).

Notifications carry a bounded question preview through the existing Mac local,
Mac Viewer and encrypted iOS delivery paths. The additive `isQuestion` marker
allows the iOS live notification to alert even while the app is active and
prevents an unrelated recent pane alert from swallowing it. Older structured
question notifications are recognized through their action context as well.
Background APNs and tap-to-open routing are retained. Codex tool-hook questions
offer tap-to-open rather than fabricated answer buttons; actual structured forms
retain their existing answer actions. Update the Host for new question detection
and iOS for foreground alerts; Relay changes are unnecessary.

See [push notifications](push-notifications-plan.md) for design/history and
actionable replies, and [self-hosting](self-hosting.md) for current configuration.
Current entry points:

- `CtrlxExternalServerLib/Services/APNsService.swift`: APNs delivery.
- `CtrlxExternalServerLib/Services/PairingService.swift`: pair persistence,
  including registered push tokens.
- `CtrlxFeature/Services/PushNotificationService.swift`: iOS registration.
- Repository `CtrlxNotificationExtension/NotificationService.swift`: decrypts
  notification content and attaches supported actions.
- `CtrlxFeature/Services/NotificationActionService.swift`: submits iOS notification responses.

APNs bundle/topic, signing entitlements and environment must match the installed
build. Do not copy a maintainer's keys into Git. Stale permission/question replies
must fail the Host's current-request check, not inject input into a newer form.

## E2EE Encryption

See [E2EE design](e2ee-encryption-plan.md) for primitives and historical implementation planning; current wire cases are in `CtrlxNetworking/Models/WebSocketMessage.swift`.

**Primitives:**
- Key Exchange: X25519 ECDH
- Symmetric: ChaChaPoly (ChaCha20-Poly1305 AEAD)
- Storage: Keychain with shared access group

**Key files:**
- `CtrlxEncryption/E2EEService.swift`
- `CtrlxEncryption/KeyManager.swift`
- `CtrlxNotificationExtension/NotificationService.swift`

Application state, commands/responses, terminal content and plugin messages travel
inside the peer-encrypted envelope. Registration/presence/heartbeat and routing
metadata remain Relay-visible. Push content is encrypted separately; the Relay
can route it without decrypting it. Consult the current wire enum when adding a
message rather than treating a historical list of cases as exhaustive.
