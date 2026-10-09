# Services Reference

Detailed documentation for Ctrlx services. Reference when modifying specific components.

## macOS Services

### FileBrowserClient / HostFileBrowser

Dependency-injected, read-only Host filesystem operations for Mac Host, Mac Viewer
and iOS Files tabs. `HostFileBrowser` is an independent I/O actor; per-connection
`FileBrowserCommandQueue` keeps file requests outside the keyboard receive loop.
See [Host-backed Files tabs](file-browser.md) for capabilities, bounds and tests.

### AppCoordinator (`CtrlxServerFeature/Coordinators/AppCoordinator.swift`)

`@Observable @MainActor` central coordinator for all services.

**Responsibilities:**
- Creates and owns all services
- Wires callbacks between services (hook events, pane changes, commands)
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
also accepts the compact `shift+← to answer` hint observed in Codex 0.158.0 and
the optional question age (`? 1 question · 14s`, including h/m/s duration parts).
Age is presentation-only: ticks neither restart the 350 ms stability check nor
re-arm a dismissed queue. Other shortcuts, arbitrary suffixes, incomplete hints
and drafts still fail closed. Mac/iOS-side
recognition and the Host's screen recheck use the same `CtrlxCommon` parser. The
native wrapper checks a stable screen after 350 ms; only the key window's focused,
visible terminal at the live bottom is eligible (no editor overlay, text selection,
mouse drag or marked IME text). Typing postpones the check. It neither changes
focus nor sends Enter/answers, and does not change the agent's working state.

Local panes call `TmuxService.expandCodexQuestions`; viewers enqueue the additive
`ExpandCodexQuestions(expectedCount:)` intent behind existing keyboard input.
The Host checks the foreground command, cursor, copy mode and actual screen before
sending `S-Left`. Host-wide queue-count deduplication prevents duplicate automatic
opens from multiple viewers, tab remounts and Escape/redraws. Queue reductions
do not auto-open; a verified empty normal composer resets the baseline. Closed
panes discard their state. There is no polling timer or history/rollout scan.

This is intentionally a conservative TUI convenience, not an App Server question
API: unknown/localized layouts, custom empty placeholders and equal-count question
replacements without an observed queue reduction stay manual. A missed/failed
attempt is not retried against the same footer. Existing Shift+Left remains usable.
For remote auto-expansion, update **both Macs**; an old Host safely rejects the new
command (no raw-key fallback). The elapsed-footer compatibility fix also requires
an updated **Host Mac and viewing client (Mac/iOS)**: supporting the wire command
alone is not enough, because the Host independently parses the footer. For example,
Host 3.0.40 rejects both the compact shortcut and elapsed suffix. Relay deployment
is unnecessary; the command and wire format are unchanged.

On iOS, `TerminalCodexQuestionExpansion` runs outside SwiftUI observable state.
The selected pane's native wrapper reads at most nine live rows, after parsing
terminal output, and checks again after 350 ms. Unrelated output does not extend
the deadline; a changed/partial footer does. It requires the input proxy's focus,
an active scene, a ready stream, both native viewports at the bottom, no copy/menu,
IME, cursor-navigation operation, drag or mouse-scroll momentum, and no blocking
response form/quick-action overlay. Typing, stream reset, resize, focus loss and
view teardown cancel pending checks. It never moves focus or scrolls the viewport
to force eligibility. Counts enter the same `KeystrokeDebouncer` FIFO as text and
mouse input; Host-wide dedup also covers an iPhone and Mac viewing the same pane.
Tests: `CodexQuestionPromptElapsedTests`, `CodexQuestionExpansionTests`,
`TerminalCodexQuestionExpansionTests` and
`KeystrokeDebouncerTests.questionExpansionFIFO`. Opening and answering the elapsed
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
- Handles hook events (SessionStart opens window, SessionEnd closes)
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

`@Observable @MainActor` bridging SwiftTerm to SwiftUI.

- Wraps SwiftTerm's `TerminalView`
- Uses **FlippedClipView** for top alignment
- Fixed dimensions in character cells
- CoreText font metrics for cell size
- Theme support (DefaultDark/Light, SolarizedDark/Light)

### HookServerService (`CtrlxServerFeature/Hooks/HookServerService.swift`)

`actor` HTTP server on a dynamically allocated port (written to `~/.ctrlx-port`). Accepts hook events from both Claude Code and Codex CLI.

**Endpoints:**
- `GET /health` - Health check
- `POST /api/hooks` - Hook event receiver

**Query params on `/api/hooks`:**
- `tmux_pane` - tmux pane target (e.g. `main:0.1`)
- `agent` - `claude-code` (default) or `codex`. Resolved via `HookQueryParams.resolvedAgent()` and stamped onto the resulting `HookEvent` so downstream UI and notification copy can branch on agent.

**Events:**
- `SessionStart` - auto-opens mirror window
- `SessionEnd` - auto-closes window (Claude Code only; Codex has no `SessionEnd` — see `docs/codex-cli-integration-plan.md` §5)
- `NotificationSend` - notification events
- `Stop` - stop events

Codex contributes additional events (`PreCompact`/`PostCompact`, `SubagentStart`, `PermissionRequest`); the server accepts any JSON payload of the right shape and does not validate event names against a Claude-specific enum.

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
- `sendHookEventToAll()` - forward hook events
- `sendTerminalStream(_:to:)` - forward terminal data to an explicit Viewer-ID set
- `pushSessionStateToAll()` - sync session state

**Callbacks (set by AppCoordinator):**
- `onCommand` - handle commands from any iOS device
- `onSessionStateRequest` - provide current session state
- `onPartnerKeyReceived` - persist E2EE partner keys

### ConnectedViewer (`CtrlxServerFeature/Services/ConnectedViewer.swift`)

`@Observable @MainActor` WebSocket connection to a single paired iOS device.

**States:** `disconnected` → `connecting` → `connected` | `reconnecting(attempt)` | `error`

- Manages WebSocket lifecycle with relay server
- E2EE encryption per device
- Auto-reconnects with exponential backoff
- Sends/receives all message types (hook events, commands, terminal stream, session state)

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

Actor executing commands from iOS devices.

- Receives `CommandMessage` from `ConnectedViewerManager`
- Dispatches to `TmuxService` (sendKeys, sendInterrupt, etc.)
- Returns `CommandResponseMessage` (success/failure)

### PluginService (`CtrlxServerFeature/Services/PluginService.swift`)

`@Observable @MainActor` managing Claude Code plugin detection and installation.

**States:** `unknown` → `checking` → `installed(version)` | `notInstalled` → `installing` → `installed` | `installationFailed`

- Detects plugin at `~/.claude/plugins/`
- Installs bundled plugin from app resources
- First-launch setup flow via `PluginSetupView`

### CodexPluginInstaller (`CtrlxServerFeature/Services/CodexPluginInstaller.swift`)

`Sendable struct` (Point-Free `@DependencyClient`) that installs the bundled `ctrlx` Codex plugin so Codex forwards hook events to the local hook server.

- Locates the bundled marketplace under `~/.ctrlx/marketplaces/ctrlx/` (copied out of the app resources at install time so Codex can re-discover it)
- Registers the marketplace via `codex plugin marketplace add` and installs the plugin via `codex plugin install ctrlx`
- Writes hooks at the **global layer** (`~/.codex/hooks.json`) to avoid per-project trust prompts on every repo
- Exposes `install` / `uninstall` / `isInstalled` closures; surfaced in Settings via `CodexPluginInstallerRow`

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
without process identity are not trusted for restoration: a fresh native Agent
event is required to establish the binding. Writes are serialized per pane and
do not block live status/notification delivery.

On iOS, open the window-title menu → **Fork → In Current Directory / In New
Worktree…**. The selected pane is the default source when there are multiple
recognized Agents. Mac and iOS share `AgentForkPanel`, including worktree review,
dirty-file acknowledgement and retrying the same request UUID. The iPhone sends
the captured source to its specific Host; it never constructs an Agent command
or touches local Git. Creation is serialized with New Terminal/New Agent. The
returned pane is selected when state arrives, unless the user has manually
changed windows or left the screen while creation was pending.

`AgentForkService` rechecks the captured pane/window/session/Agent UUID/cwd on
the Host before launching in a new window of the same tmux session. It uses
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

On iOS, New Session uses a large system sheet for both project history and directory
browsing, rather than starting at half height. Project search is present only in
project-history mode; directory mode keeps its own path field without the unrelated
search toolbar. Back returns to the project list with the search text preserved.
Cancel and the system swipe-to-dismiss remain available; directory lookup and
Agent launch behavior are unchanged.

The iOS directory browser also offers **New Folder** beside Home/Up. It is
enabled only for an exact, successfully listed directory on a Host advertising
`supportsDirectoryCreation`; older Hosts show an update hint and receive no
creation command. The name prompt displays the chosen parent. Creation is an
acknowledged `CreateSessionDirectory` filesystem operation on the Host actor,
not terminal input: it accepts one literal child name, creates no intermediate
parents, and fails for existing files/directories/symlinks or insufficient
permissions. Success enters the new directory without launching a session.
Path navigation and Agent launch are disabled while creation is pending;
late replies cannot redirect a different Host/path or a reopened form. Both
iOS and the Host Mac need the update; the encrypted Relay remains unchanged.

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
`SessionDirectoryCapabilityTests`, and the existing Codex OTEL/launch tests.

### ClaudeProjectScanner (`CtrlxServerFeature/Services/ClaudeProjectScanner.swift`)

Actor scanning for Claude Code projects.

- Reads `~/.claude.json` for project paths
- Validates projects have `.claude` subdirectory
- Sorts by most recently used (session timestamps)
- Tags each result with `agent: .claudeCode`
- Results merged with `CodexProjectScanner` output by `AppCoordinator.scanProjects()` and sent to iOS for project list display

### CodexProjectScanner (`CtrlxServerFeature/Services/CodexProjectScanner.swift`)

`Sendable struct` (Point-Free `@DependencyClient`) discovering Codex projects.

- Walks `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, honoring `CODEX_HOME` if set (rollouts are date-partitioned, not project-partitioned, so the scanner must read each file's header)
- Reads each rollout's first JSON line (a `SessionMetaLine`) to recover the working directory. Accepts `cwd`, `working_directory`, or `payload.cwd` because Codex's schema is evolving
- Groups rollouts by working directory and emits one `ClaudeProjectInfo` per project with `agent: .codex`
- Output is merged with `ClaudeProjectScanner` results in `AppCoordinator.scanProjects()` and the project-list relay payload, so the iOS picker shows a unified "most recently used" list with a per-row agent badge

### ClaudePathDetector (`CtrlxServerFeature/Services/ClaudePathDetector.swift`)

Static utility detecting the `claude` CLI path.

- Checks common locations (`/usr/local/bin/claude`, homebrew paths, etc.)
- Used by `TerminalLauncher` for auto-running Claude in new sessions
- The matching `codex` path is resolved against `AppSettings.codexCommandPath` (default `codex`) rather than auto-detection

### TerminalLauncher (`CtrlxServerFeature/Services/TerminalLauncher.swift`)

`@MainActor` utility for launching tmux sessions in external terminals.

- Supports Terminal.app, iTerm2, Warp, Kitty, Alacritty, custom
- Attaches to existing tmux sessions
- Used from iOS "open in terminal" commands

### DockIconManager (`CtrlxServerFeature/Managers/DockIconManager.swift`)

`@MainActor` managing dock icon visibility and the dock tile badge.

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

### SleepPreventionManager (`CtrlxServerFeature/Managers/SleepPreventionManager.swift`)

`@MainActor` preventing Mac sleep during active sessions.

- Uses IOKit `IOPMAssertionCreateWithName` assertions
- Enabled/disabled via settings toggle
- Automatically releases when all sessions end

### LoginItemService (`CtrlxServerFeature/Services/LoginItemService.swift`)

Static utility for launch-at-login management.

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

## iOS Services

### RelayClient (`CtrlxFeature/Services/RelayClient.swift`)

`@Observable @MainActor` managing WebSocket from iOS to relay server.

- Connects via `MacConnection` wrapper per paired Mac
- Receives session state, hook events, terminal stream data
- Sends commands (keystroke, cancel, start/stop stream)
- Auto-reconnects with exponential backoff

### SessionStore (`CtrlxFeature/Services/SessionStore.swift`)

`@Observable @MainActor` tracking sessions from Mac.

- Stores sessions by pane ID
- Handles hook events
- Updates on full sync
- Clears on disconnect

## Utilities

### ProcessRunner (`CtrlxServerFeature/Utilities/ProcessRunner.swift`)

Actor for external processes.

- Async execution, stdout/stderr collection
- Thread-safe `OutputCollector` with NSLock
- Returns `ProcessResult` (exit code, stdout, stderr)

## Models

### CodingAgent (`CtrlxNetworking/Models/CodingAgent.swift`)

```swift
public enum CodingAgent: String, Codable, Sendable, CaseIterable, Hashable {
    case claudeCode = "claude-code"   // Anthropic Claude Code CLI (`claude`)
    case codex                         // OpenAI Codex CLI (`codex`)
}
```

Carries display metadata used to render agent-aware UI:

- `displayName` — `"Claude Code"` / `"Codex"` (full notification titles)
- `shortName` — `"claude"` / `"codex"` (lowercase in the bundled manifests since #691, so project-row agent badges read `claude`/`codex` verbatim with no casing transform in the UI; sidebar badges, compact toasts)
- `processName` — `"claude"` / `"codex"` (matched against tmux pane process trees in `TmuxService.detectAgentPanes`)

`HookEvent`, `ClaudeSession`, and `ClaudeProjectInfo` all carry an `agent` field that defaults to `.claudeCode` when missing, so older Mac builds and older relay payloads still decode cleanly.

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
- **Remote Access:** externalServerURL, deviceId, pairedDevices
- **Coding agents:** autoRunClaudeInProjects, claudeCommandPath, codexCommandPath. `commandPath(for: CodingAgent)` returns the right binary path for an agent
- **Prompt editor (Ctrl-G):** editorOverrideMode (`ask` / `overrideInCtrlxSessions` / `useMyEditor`) — see [Editor Override](#editor-override-ctrl-g)
- **Plugin:** hasCompletedPluginSetup

### PairedDevice (`CtrlxServerFeature/Models/Settings.swift`)

```swift
id, deviceName, partnerPublicKey, partnerPublicKeyId, pairedAt, customName
```

Represents a paired iOS device with E2EE key info.

## Push Notifications

**Configuration** (`.env`):
```bash
APNS_KEY_PATH=/secrets/AuthKey.p8
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=XXXXXXXXXX
APNS_BUNDLE_ID=com.example.app
APNS_ENVIRONMENT=development  # or "production"
```

**Key files:**
- `CtrlxExternalServer/Services/APNsService.swift`
- `CtrlxExternalServer/Services/PushTokenStore.swift`
- `CtrlxFeature/Services/PushNotificationService.swift`

**Events:** sessionStart, sessionEnd, permissionRequest, stop, notification

**Important:** APNs environment must match build type (Xcode=development, App Store=production)

## E2EE Encryption

See `docs/e2ee-encryption-plan.md` for full design.

**Primitives:**
- Key Exchange: X25519 ECDH
- Symmetric: ChaChaPoly (ChaCha20-Poly1305 AEAD)
- Storage: Keychain with shared access group

**Key files:**
- `CtrlxEncryption/E2EEService.swift`
- `CtrlxEncryption/KeyManager.swift`
- `CtrlxNotificationExtension/NotificationService.swift`

**Encrypted types:** hookEvent, sessionState, command, commandResponse, terminalStream

**Unencrypted types:** registerMac/registerIOS, ping/pong, iosConnected/Disconnected, encryptedPush
