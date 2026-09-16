# CtrlX Repository Guide

Distributed system for monitoring coding-agent sessions (Anthropic Claude Code and OpenAI Codex CLI, behind a shared `CodingAgent` abstraction in `CtrlxNetworking`). Three components:
1. **Mac App** - tmux pane mirroring, receives hooks from both agents, forwards to server
2. **External Server** - Vapor relay (Docker/Linux), device pairing, WebSocket routing
3. **iOS App** - Remote monitoring, command dispatch

**Stack:** Swift 6.3+, SwiftUI (MV pattern), Swift Concurrency, SwiftTerm, Vapor, CryptoKit (E2EE)

**Targets:** macOS 15.0+, iOS 18.0+

**Development by platform:**
- macOS → `CtrlxPackage/Sources/CtrlxServerFeature/`
- iOS → `CtrlxPackage/Sources/CtrlxFeature/`
- Shared → `CtrlxPackage/Sources/CtrlxNetworking/`
- Encryption → `CtrlxPackage/Sources/CtrlxEncryption/`
- Server → `CtrlxPackage/Sources/CtrlxExternalServer/`

## Critical Rules

### Only necessary code outside Packages

The code in the Xcode project should be the absolute minimal. If code can be in a package then it should. 

### No ViewModels

Use native SwiftUI data flow:
- `@State` for view-specific state
- `@Observable` for model classes
- `@Environment` for app-wide services
- `@Binding` / `@Bindable` for two-way flow
- `.task` for async (auto-cancels), never `Task {}` in `onAppear`

### SF Symbols

Never use string literals. Add to `CtrlxCommon/UI/Symbols.swift`:
```swift
@SFSymbol
public enum Symbols: String {
    case starFill = "star.fill"
}
```
Use: `Symbols.starFill.image` or `Label("Text", symbol: .starFill)`

### Concurrency

- `@MainActor` for all UI
- actors for I/O (ProcessRunner, TmuxControlClient)
- No GCD, Swift Concurrency only
- All cross-boundary types must be `Sendable`

### Dependencies (Dependency Injection)

Use [Point-Free Dependencies](https://github.com/pointfreeco/swift-dependencies) for services that wrap system APIs or perform I/O. This enables testability without real system interaction.

**When to use `@DependencyClient`:**
- Stateless utilities wrapping system APIs (UserDefaults, Keychain, SMAppService, IOKit, etc.)
- Process execution and filesystem access
- Services that are hard to test without mocking (network, push notifications)

**When NOT to use it:**
- `@Observable` classes with complex state and many wired callbacks (use init injection instead)
- Services already using Vapor's DI container (external server)
- Simple value types or pure functions

**Pattern:** Define as `@DependencyClient struct`, conform to `DependencyKey`, provide `liveValue` and optional `inMemory()`. See `docs/swift-patterns.md` for full examples.

**Usage in `@Observable` classes:**
```swift
@ObservationIgnored
@Dependency(MyService.self) private var myService
```

**Usage in initializers:**
```swift
@Dependency(MyService.self) var service
```

**Testing:**
```swift
try await withDependencies {
    $0[MyService.self] = .testValue
} operation: {
    // code under test
}
```

### Error Handling

- `guard let` / `if let` for optionals
- No force-unwrap without certainty
- `do/try/catch` with meaningful errors
- No empty catch blocks

## Building & Testing

Run build commands from the repository root and use `Ctrlx.xcworkspace`, not
the `.xcodeproj`, so local packages and shared schemes resolve consistently.

- macOS scheme: `CtrlxServer`
- iOS scheme: `Ctrlx`
- Unit tests: `swift test --package-path CtrlxPackage`

### iOS build, package, and device install

Keep personal signing data out of Git. Copy `Config/Local.xcconfig.example` to
the ignored `Config/Local.xcconfig`, then set the development team and unique app
and notification-extension bundle identifiers there. Never hard-code a personal
team or provisioning profile in `project.pbxproj`.

For a fast simulator compile check that does not require an iPhone or device
provisioning:

```bash
xcodebuild \
  -workspace Ctrlx.xcworkspace \
  -scheme Ctrlx \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build-local/DerivedData/iOS-Simulator \
  -skipMacroValidation \
  build
```

For a signed local-device package, use the repository script rather than
reimplementing its signing steps:

```bash
./scripts/package-local-ios.sh
```

The script must run in the primary worktree. It builds both the app and its
notification extension, selects matching installed provisioning profiles,
signs and verifies the result, and writes these artifacts:

- Installable app: `.build-local/DerivedData/iOS/Build/Products/Debug-iphoneos/CtrlX.app`
- IPA: `dist/CtrlX-<version>.ipa`
- Integrity metadata: adjacent `.sha256` and `.manifest.json` files

This is a local-development IPA. TestFlight/App Store upload remains deliberately
blocked by `scripts/testflight.sh` pending the review documented in `RELEASE.md`.

Both provisioning profiles must belong to the same team. The app bundle ID must
also match the Relay's APNs configuration for background notifications to work.
Do not try to install an intermediate app produced with
`CODE_SIGNING_ALLOWED=NO`; install the script's final, verified `CtrlX.app`.

Discover a connected, trusted, unlocked device and install the exact app that
was just built:

```bash
xcrun devicectl list devices

DEVICE_ID='<CoreDevice UUID>'
APP_PATH='.build-local/DerivedData/iOS/Build/Products/Debug-iphoneos/CtrlX.app'
APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"

xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
xcrun devicectl device process launch \
  --device "$DEVICE_ID" \
  --terminate-existing \
  "$APP_BUNDLE_ID"
```

Prefer the CoreDevice UUID from `devicectl list devices` over a device name.
When discovery or installation fails, first verify that the phone is unlocked,
trusted, in Developer Mode, and shown as available. For signing errors, verify
`Config/Local.xcconfig`, the Apple Development certificate, and both installed
provisioning profiles before changing build settings.

**Killing Mac app:** Use `osascript -e 'quit app "CtrlX"'` — `pkill`/`killall` don't work reliably.

**Opening a PR:** A `PostToolUse` hook (`.claude/hooks/pr-checklist.py`) fires on `gh pr create` and injects a checklist of post-PR chores (docs, `AGENTS.md`, CLI/`ctrlx` skill, e2e scenarios). Work through it before stopping. See `docs/repo-hooks.md`.

## Reference Docs

- **Code examples:** `docs/swift-patterns.md` - SwiftUI patterns, Sendable, Dependencies, testing
- **Services:** `docs/services-reference.md` - TmuxService, PaneStream, CodingAgent, project scanners, etc.
- **Architecture:** `docs/architecture.md` (Mac app) and `docs/distributed-architecture-plan.md` (Mac/Server/iOS)
- **Codex CLI integration:** `docs/codex-cli-integration-plan.md` - `CodingAgent` abstraction, hook bridge, project discovery
- **Folder layout persistence (macOS):** `docs/folder-layout-persistence-plan.md` - Per-folder workbench restore (file/browser tabs, split, sidebar); `LayoutStore`, seed-on-birth, auto-save. Covers local *and* remote/viewer sessions (§4.8 — remote is browser-tabs + split only, keyed by host `pairId`)
- **Encryption:** `docs/e2ee-encryption-plan.md`
- **Actionable push notifications (#710):** `docs/push-notifications-plan.md` §6.1 - answer permission requests (Yes/Always/No) and AskUserQuestion forms (one question at a time, option buttons + free-text "Other") straight from iOS notifications. `NotificationActionContext` rides the encrypted `NotificationContent`/`AgentNotificationMessage` (additive optional — relay never sees it); the NSE attaches categories (dynamic per-question ones carry option labels); `NotificationActionService` submits via the live manager or a short-lived connection; the host's `AgentResponseSubmissionGuard` drops blocking answers whose requestId no longer matches the pane's open form (stale lock-screen taps must not inject keystrokes).
- **E2E testing:** `docs/e2e-testing.md` - Test framework, running tests, writing scenarios, video recording (`--record`, issue #621), in-browser proof-video watching (`scripts/e2e-watch-video.sh <asset|url|scenario>` — resolves the ~1h signed URL via gh and opens the static player `scripts/e2e-video-player.html`; release-asset links otherwise download), automatic proof-video cleanup (daily sweep, 3-day grace after PR close; watch hints struck alongside links), shell-history isolation (every e2e shell runs under a `$ZDOTDIR` shim so typed commands never reach `~/.zsh_history`)
- **Stop-finality eval (#644):** `docs/stop-finality-eval.md` - Hill-climbing eval for the false-stop judge on Apple's Evaluations framework (macOS 27 beta Mac) + transcript-mining/labeling pipeline (`scripts/stop-finality-dataset.py`) + macOS 26 cross-check (`swift run StopFinalityEval`). Mined dataset lives in `~/.ctrlx/eval/`, never committed.
- **Self-hosting:** `docs/self-hosting.md` - Zero-parameter Relay setup and configuration priority. `MinClientVersionGate` is controlled by `MIN_CLIENT_VERSION` and `MIN_CLIENT_VERSION_REJECT_UNKNOWN`; `PAIRING_PAUSED_MESSAGE` pauses new registrations. `/health`, `/ready`, `/version` and `/source` expose operational and corresponding-source state. Production secrets stay in the server's ignored `.env.production` and are never copied from the repository.
- **Hosted-relay licensing (#392):** `docs/superpowers/specs/2026-07-13-hosted-relay-monetization-design.md` (trial-start/UI follow-on: `docs/superpowers/specs/2026-07-15-trial-status-badge-and-pairing-trial-start-design.md`) - Lemon Squeezy subscription gate for host Macs on the hosted relay: `LicensingService` actor (7-day trial keyed by host deviceId — **the trial clock starts when a viewer completes pairing** (`completePairing`→`startTrialIfNeeded`), NOT on register/first-touch; `checkEntitlement` is a pure gate with a `.preTrial` allowed state; license keys with cached verdicts; enforcement/gating at pairing register + host WS connect + daily sweep). Host WS connect *also* starts the trial for pre-existing **ACTIVE** pairs (gated on `getPair`≠nil, pending pairs excluded) — a one-time migration so pairings completed before licensing was enabled aren't grandfathered into permanent free access. UI: Mac License section in Remote Access settings **plus a trial/expired badge in the panes-window toolbar (left of Disconnect, shown only for paired hosts) opening a buy/activate popover** (`TrialStatusToolbarItem`), viewer "subscription expired" states. Entirely disabled unless `LEMONSQUEEZY_STORE_ID`/`LEMONSQUEEZY_PRODUCT_ID` are set — self-hosting needs no config. Enablement gates (LS dashboard setup, real `LicensingLinks` URLs replacing `CHECKOUT-VARIANT-UUID`, `VersionCompatibility` bump) live in the plan's Task 18 checklist (`docs/superpowers/plans/2026-07-13-hosted-relay-monetization.md`)
- **Release and updates:** `RELEASE.md` - `scripts/release.sh` is zero-parameter, requires a clean tagged primary worktree, signs/notarizes `CtrlX-<version>.dmg`, and emits the appcast, SHA-256 and source manifest. Production Relay and installer publishing run on Qcloud through an external maintainer runbook and script; the retired home-Mac path must not be used. Sparkle remains disabled until an owned feed and EdDSA key are configured.
- **Staging relay:** `docs/staging-relay.md` - isolated data, secrets, APNs and hostname with the generic `caddy/ctrlx-staging.caddy`; no domain is hard-coded.
- **Emoji search:** `docs/emoji-search.md` - internal `GallagerEmoji` module (keyword-aware emoji index shared by the Mac/iOS picker and the `ctrlx` CLI). Data is generated by `scripts/generate-emoji-data.py` from CLDR annotations into `EmojiData.swift`.
- **Repo hooks:** `docs/repo-hooks.md` - Project-scoped Claude Code hooks (swiftformat, PR checklist)
- **Terminal sizing (macOS):** `docs/swiftterm-sizing.md`
- **Terminal scrolling (iOS):** `docs/swiftterm-ios-scrolling.md`
- **Terminal quick actions:** `docs/terminal-quick-actions.md` - Shared iOS/Mac command catalog and local-first phrase library; per-pair bilateral opt-in E2EE phrase sync, stable IDs/tombstones and v1→v2 migration. Existing opaque relay needs no deployment. Mac toolbar popovers target the last focused native pane and reuse its keyboard queue.
- **Terminal rendering bugs:** `docs/terminal-rendering-investigation.md` - Hypotheses, test results, fix priorities
- **Sidecar plugin authoring:** `docs/plugins/sidecar-authoring.md` - External contract for v2 sidecar plugins: manifest schema, JSON-RPC vocabulary, spawn env, hook ingress, crash policy, distribution, security model. A manifest `otlp` field (`{namespace, token_event}`, #617) opts a plugin's OTLP log records into the per-session token/cost/latency meter: records named `<namespace>.<token_event>` must mirror Claude's `api_request` attribute keys (additive semantics, `session.id` join); the resolved namespace table is pushed to `OTLPReceiver` whenever the enabled-plugin set changes (`refreshOTLPPluginNamespaces`), and built-in namespaces can't be claimed. Note: sidecar child stderr goes to `~/.ctrlx/state/plugins/<id>/logs/stderr.log` (separate from `host.log()`'s `sidecar.log`). The bundled `ctrlx:create-agent-plugin` skill (`plugin/ctrlx/skills/create-agent-plugin/`) scaffolds one from a Python template + self-contained contract copy. Wire casing trap: `plugin.json` and the ingress *socket* frame are snake_case (`plugin_id`); the stdio *transport* (RPC params/results) is camelCase (`pluginID`, `sessionID`, …). URL-installed plugins auto-update via `PluginUpdateManager` (checks on app-version change + daily, per-plugin toggle + "Check Now" in Settings → Agents, hot-restart + `install` RPC re-invoke when idle, deferred to next launch when busy); a changed bundle host (`sourceChanged`) is never auto-installed and requires the manual trust flow instead.
- **pi sidecar plugin (real example):** `plugins/pi/` - a complete working sidecar adding pi (`@earendil-works/pi-coding-agent`) support: Python `bin/sidecar` + a pi *extension* bridge (`pi-bridge/ctrlx.ts`, TypeScript via jiti, installed to `~/.pi/agent/extensions/ctrlx.ts`, marker `CtrlXPiBridge`; per-project installs go to `<configRoot>/.pi/extensions/`). pi's event bus is complete — real `session_start` (launch + `/new`//`/resume`//`/fork`) and `session_shutdown` (quit incl. Ctrl+C/Ctrl+D/SIGHUP/SIGTERM) — so **no synthetic lifecycle frames and no WORKING/SEEN state machine** (contrast opencode): `session_start`→idle, `agent_start`→working, `agent_end`→doneWorking (summary = last assistant text, bridge-trimmed to 300 chars; stopReason `error`→errorMessage, `aborted`→"Interrupted"), `session_shutdown reason=quit`→`sessionEnded` keyed by PANE id (other reasons ignored — a `session_start` re-stamps the pane immediately; ending there would flicker the sidebar row). **Telemetry (#617):** the bridge POSTs one OTLP record per assistant `message_end` (event `pi.api_request`, Claude's attribute keys; usage comes complete on pi's AssistantMessage — thinking already folded into `output`; `duration_ms` = wall-clock `message_start`→`message_end`; `session.id` = pi's session UUID from `ctx.sessionManager.getSessionId()`, same id every PluginEvent reports). Projects scan reads `~/.pi/agent/sessions/*/` — dir names are lossy cwd munges, but each session file's FIRST line is a `SessionHeader` with the exact `cwd`; newest file per dir wins, `lastUsed` = mtime. Gotchas: pi's `ps` comm is `node` (a script), so manifest `process_names: ["pi"]` never matches a live pane — bridge events cover detection, but a pi already idle when CtrlX launches stays invisible until its next event; pi quits on *rapid double* Ctrl+C (a lone one clears input); `-ne`/`--no-extensions` also disables provider packages (e.g. `pi-ollama-cloud`) → "No API key" (smoke-test with `-e path/to/ctrlx.ts`, not `-ne -e`). Core pi has no permission gating → no awaiting* forms. Tests: `python3 plugins/pi/tests/test_sidecar.py` (30). `./scripts/dev-install.sh` copies to `~/.ctrlx/plugins/pi/`.
- **omp sidecar plugin (real example):** `plugins/omp/` - a complete working sidecar adding omp (oh-my-pi, https://omp.sh — can1357's pi fork, native binary so `process_names: ["omp"]` actually matches) support: Python `bin/sidecar` + an omp *extension* bridge (`omp-bridge/ctrlx.ts`, installed to `~/.omp/agent/extensions/ctrlx.ts`; per-project → `<root>/.omp/extensions/`). Event vocabulary diverged from pi (verified v17.1.8): `session_start` = initial load only (no reason); replacement is `session_switch`/`session_branch`/`session_tree` (bridge re-labels them as session_start frames → idle re-stamp); `session_shutdown` = process exit ONLY → always `sessionEnded` (no reason filtering, awaited flush); `agent_end` has `willContinue` (auto-retry continuation — bridge drops it, else spurious "Finished" mid-turn). **Subagents:** omp re-binds the same extensions in-process against a headless runtime per `task` subagent — every bridge handler gates on `ctx.hasUI` (the opencode #670 lesson). **Approval forms:** omp HAS a tool-approval gate (default yolo) with `tool_approval_requested`/`resolved` observability events → `awaitingPermission` (requestID = toolCallId; detail captured from the earlier `tool_call` interception event since the approval event only carries the tool name); answered by KEYSTROKE injection into the TUI's Approve/Deny select (allow → Enter, deny → Down+Enter, deny-feedback typed after as a steer); `isAutoApprovable: false` (never override the user's non-yolo choice). **Ask-tool question forms:** omp's `ask` tool (blocking question dialog) has no dedicated event, but `tool_execution_start`/`end` bracket it with full `questions` in `args` → `awaitingReplies` (requestID = toolCallId, option ids `q<i>-o<j>`, questions cached in the pending map for answer translation) + "Question:" push; answered by keystrokes against the rich ask dialog (cursor starts on `recommended`, Up/Down CLAMP → normalize with Up×rowCount then Down×target; single-select Enter auto-advances, multi Space-toggles then Right, free text = Enter on the Other row + delay + text + Enter, final Enter on the Submit tab when >1 question or any multi); local TUI answers and omp's ask-timeout auto-select clear the form via tool_execution_end. Gotcha: a non-empty prompt draft at dialog-open engages omp's input guard (keys go to the draft editor, injected answers eaten). **Telemetry (#617):** one OTLP record per finalized assistant `message_end` (`omp.api_request`, Claude attribute keys; dedup by `id` ?? `responseId`; `duration_ms` = omp's own `message.duration`, wall-clock fallback; join = omp session UUID via `ctx.sessionManager.getSessionId()`). Projects scan: `~/.omp/agent/sessions/*/` like pi BUT the `cwd`-bearing `type=="session"` header is usually line 2 (a rewritable `title` record precedes it) → scan first lines, and skip per-session artifact SUBdirs (`__advisor.jsonl`). Tests: `python3 plugins/omp/tests/test_sidecar.py` (49). `./scripts/dev-install.sh` copies to `~/.ctrlx/plugins/omp/`.
- **opencode sidecar plugin (real example):** `plugins/opencode/` - a complete working sidecar adding opencode (sst) support: Python `bin/sidecar` + an opencode `event`-bus bridge plugin (`opencode-bridge/ctrlx.js`, installed to `~/.config/opencode/plugin/`) since opencode removed shell hooks. Maps `session.status`/`session.idle`/`session.error` to working/done/idle (per-session machine so a turn-end `idle` raises attention but a fresh-session `idle` doesn't); `permission.asked` → `awaitingPermission`; `question.asked` → `awaitingReplies` (multi-question + multi-select + free text). **Subagents (#670):** opencode runs each `task`-tool subagent in a child session (`info.parentID` set) that emits its own busy/idle — but `session.status`/`session.idle` OMIT `parentID` (opencode #30043), so the bridge also forwards `session.created`/`session.updated` (the only events carrying it), the sidecar records children in a `CHILD` map (child→parent), and DROPS all lifecycle events (`session.status`/`session.idle`/`session.error`) for child sessions. Only the root session drives the pane, so N subagents → exactly one "Finished working". Child `permission.asked`/`question.asked` are NOT dropped — opencode's TUI shows a child's prompt in the root session's view and blocks the turn — but are re-keyed to the root session (`_root_session` walks the parent chain) so a child id never becomes the pane's session. Ordering: opencode fires plugin `event` hooks without awaiting, so the bridge serializes all ingress frames through a FIFO send chain (awaited in the hook) — `session.created` always beats the child's churn. Bridge change ⇒ existing installs must re-Install for the fix. **Turn summaries:** opencode's idle events carry no text, so at a root session's turn-end idle the bridge fetches `client.session.messages` on the in-process SDK client (reachable in-process despite the unix-socket server that blocks the *sidecar*'s HTTP route), attaches the last assistant message's text (synthetic/ignored parts filtered, 300-char trim) as `properties.ctrlxSummary` — fetched at idle-arrival but awaited INSIDE the FIFO send chain (awaiting in the hook would let a new turn's `busy` overtake the idle frame), 2s self-timeout, never rejects; sidecar surfaces it as `doneWorking(summary)` + notification body, falling back to "Finished — project". **Session lifecycle:** opencode fires NO event on a fresh idle launch or on quit, and the host's 10-second process reconciliation is only a fallback for missing lifecycle signals — so the bridge emits two *synthetic* frames for immediate, authoritative state: `ctrlx.lifecycle.started` (on plugin load ≈ TUI start → sidecar emits `idle`, session appears) and `ctrlx.lifecycle.stopped` (from opencode's `dispose` hook ≈ graceful quit → sidecar emits `AppAction.sessionEnded` keyed by the PANE id → host removes the session). Mirrors Claude's SessionStart/SessionEnd (no notifications); `closePaneEligible` honors `close_pane_on_session_end`. dispose fires on `/exit` AND Ctrl-C (verified v1.17.11); a hard SIGKILL skips it (stale session lingers). **Forms are answered by KEYSTROKE injection** into the pane (opencode's TUI talks to its server over a unix socket — no reachable HTTP endpoint; the sidecar emits `send_keys` and CtrlX just relays, so each agent's keystroke mapping is plugin-owned). opencode's question prompt uses number keys `1`-`9` (jump+toggle/pick) with a tabbed Confirm-submit for multi/multi-question. Projects surface in the sidebar "+" menu by reading opencode's SQLite store (`~/.local/share/opencode/opencode.db`, `project` table). opencode keys a project by its git *repo*, not folder, and stores only the FIRST worktree it saw — so a repo with multiple `git worktree`s would show just one, whichever opencode recorded. The scan expands each stored `worktree` into EVERY worktree of its repo via `git worktree list --porcelain` (so main + linked worktrees are each launchable, deduped across rows; falls back to the raw path for non-git dirs / missing git). The stored worktree keeps opencode's own `name`; other worktrees are labeled by basename. The scan opens the DB `mode=ro` (WAL-aware) not `immutable=1`, so a freshly-created project sitting in the WAL surfaces immediately (WAL readers never block the writer); it falls back to `immutable=1` only when `mode=ro` can't open (stale `-wal`, no `-shm`, no dir write access = opencode not running). **Telemetry (#617):** the bridge POSTs one OTLP/JSON record per *completed* assistant message (`message.updated` with `time.completed`, deduped by message id, never forwarded to the ingress socket) to the receiver's `/v1/logs`, event name `opencode.api_request`, Claude's exact attribute keys (reasoning folded into `output_tokens`), `session.id` = **opencode's `ses_…` session id** — the host re-stamps the pane's join key from every sidecar-reported event, and real opencode events report the ses id (the pane id, reported only by the synthetic launch frame, would stop joining at the first turn); the meter follows the pane's active session, resetting on session switch like `/clear`; the sidecar bakes the endpoint into the bridge at install via `__CTRLX_OTLP_ENDPOINT__` (from initialize's `otlpReceiverEndpoint`; `CTRLX_OTLP_ENDPOINT` env fallback for repo smoke tests; stale if the receiver's port changes → re-Install). Gotcha: `PluginEvent.appActions` is non-optional — a hand-built event JSON MUST include `"appActions": []` (or a populated list) or the host silently drops it. Tests: `python3 plugins/opencode/tests/test_sidecar.py` (42). `./scripts/dev-install.sh` **copies** it into `~/.ctrlx/plugins/` (folder-drop discovery skips symlinks).
- **Website:** `website/` - Astro static site with no hard-coded production hostname. Configure and publish it only after an owned domain exists; the generic Caddy file is `CtrlxPackage/caddy/website.caddy`.
