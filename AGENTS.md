# CtrlX Repository Guide

Tmux-native remote workspaces with plugin-based coding-agent integration.

1. **Mac App** — local Host and remote Viewer; owns tmux, plugin runtime and Host files/browser pages.
2. **Relay** — Vapor (Docker/Linux), pairing, presence and encrypted message routing.
3. **iOS App** — Viewer, remote terminal input and agent interaction.

Start with [CONTRIBUTING.md](CONTRIBUTING.md) for the cross-AI workflow and
[docs/README.md](docs/README.md) for current references versus historical plans.
The current agent seam is `PluginCore` / `PluginHost`, with
`AgentSession.pluginID` and Unix-socket ingress; the old `CodingAgent` enum
and HTTP hook service are gone.

**Stack:** Swift 6.3+, SwiftUI (MV pattern), Swift Concurrency, SwiftTerm, Vapor, CryptoKit (E2EE)

**Targets:** macOS 15.0+, iOS 18.0+

**Development by platform:**
- macOS → `CtrlxPackage/Sources/CtrlxServerFeature/`
- iOS → `CtrlxPackage/Sources/CtrlxFeature/`
- Shared Apple-client UI/services → `CtrlxPackage/Sources/CtrlxCommon/`
- Shared wire models → `CtrlxPackage/Sources/CtrlxNetworking/`
- Agent contracts/cores → `CtrlxPackage/Sources/CtrlxPluginProtocol/`, `ClaudeCodePluginCore/`, `CodexPluginCore/`
- Encryption → `CtrlxPackage/Sources/CtrlxEncryption/`
- Relay implementation → `CtrlxPackage/Sources/CtrlxExternalServerLib/`; executable → `CtrlxPackage/Sources/CtrlxExternalServer/`

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
- actors for stateful I/O (TmuxControlClient, HostFileBrowser); dependency clients
  for system wrappers such as ProcessRunner
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
- Before direct Mac workspace builds, prepare the native components in order:
  `bash scripts/build-device-installer.sh`, `bash scripts/build-agent-browser.sh`,
  then `bash scripts/build-agent-simulator.sh`. Local Mac packaging does this
  automatically.
- Unit tests: `./scripts/unit-tests.sh` (pass filters after `--`). Uses Swift's
  `swiftbuild` backend without indexes; after success, prunes old native-backend
  outputs and test indexes. Do not alternate backends or build concurrently in
  the same package cache. Use `--save-space` to remove test compilation caches
  after success, keeping test products and dependencies.

### iOS builds and signing

Keep personal signing data out of Git. Copy `Config/Local.xcconfig.example` to
the ignored `Config/Local.xcconfig`, then set the development team and unique app
and notification-extension bundle identifiers there. Never hard-code a personal
team or provisioning profile in `project.pbxproj`.

For a fast simulator compile check that does not require an iPhone or device
provisioning:

```bash
python3 scripts/local_build.py run -- xcodebuild \
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

The script can run in any Git worktree. Configure that worktree's ignored
`Config/Local.xcconfig`; caches and artifacts remain worktree-local. It builds
both the app and its notification extension, selects matching installed provisioning profiles,
signs and verifies the result, and defaults to an optimized Release build:

- Installable app: `.build-local/DerivedData/iOS/Build/Products/Release-iphoneos/CtrlX.app`
- IPA: `dist/CtrlX-<version>.ipa`
- Integrity metadata: adjacent `.sha256` and `.manifest.json` files

For same-source performance comparisons, `--configuration Debug` produces
`Debug-iphoneos/CtrlX.app` and a separate `CtrlX-<version>-Debug.ipa`. Install the
configuration printed by the script; do not reuse the other configuration's app.

This is a local-development IPA. TestFlight/App Store upload remains deliberately
blocked by `scripts/testflight.sh` pending the review documented in `RELEASE.md`.

Both provisioning profiles must belong to the same team. The app bundle ID must
also match the Relay's APNs configuration for background notifications to work.
Do not try to install an intermediate app produced with
`CODE_SIGNING_ALLOWED=NO`; install the script's final, verified `CtrlX.app`.

### Packaging and storage

Both platform packaging scripts accept `--app-only` to build/sign/verify without
creating a DMG/IPA. Successful builds write `CtrlX.app.build.json` beside the App;
rebuilding invalidates the previous record. Packaging validates staged artifacts
before replacing packages and their sidecars.

Keep incremental caches by default. Successful packaging retains two packages per
platform/configuration and prunes completed artifacts. `--save-space` removes
compilation caches only after success, retaining signed apps and downloads.
The next build is slower; this flag cannot make room for the current build.
Packaging warns below 20 GiB free, without deleting caches before building.

Script-managed builds, tests, installation and **worktree cleanup** share an
operation lock. Raw Xcode/Swift commands are not covered: serialize them against
the same caches or use `python3 scripts/local_build.py run -- <command>`.
Stop affected builds, tests and installs before applying cleanup. Cleanup modes
preview by default; inspect that output before adding `--yes`.

- Prefer `python3 scripts/clean-build.py idle` for an inactive worktree; it keeps
  signed apps, packages and downloads. `deep` also deletes built apps and downloaded
  build dependencies. Neither scans other worktrees. Scope and other modes:
  [Local build storage](RELEASE.md#local-build-storage).
- Mark diagnostics/backups with `.ctrlx-cleanup-ready` only after their consumers
  stop and the evidence is no longer needed. An App backup also needs a verified
  replacement and retained rollback package. See [packaging cleanup](RELEASE.md#packaging-and-test-cleanup).
- Run managed disposable verification/backup workflows through
  `python3 scripts/clean-build.py use-artifact --path <directory> -- <command>`.
  The command must stop all consumers before returning; never wrap a detached app
  or ongoing simulator environment. Failed/unmarked copies remain; never bulk-adopt
  them. See [artifact retention](RELEASE.md#verification-copies-and-local-install-backups).
- `python3 scripts/clean-build.py system-temp` is a separate, current-user macOS
  scope shared across worktrees. It selects only recognized signing clones and
  legacy E2E compilation caches; it is never invoked by packaging or `idle`.
  Stop E2E builds/tests before applying it. See [scope, retention and exclusions](RELEASE.md#macos-user-temporary-caches).

E2E builds default to `.build-local/DerivedData/E2E`; worktree `idle` covers its
compilation caches. See [E2E testing](docs/e2e-testing.md) for explicit overrides.

### Local installation

Use the unified local installer for build/sign/install/launch and cleanup.
It supports any worktree and does not publish or deploy the Relay:

```bash
python3 scripts/install-local.py macos
xcrun devicectl list devices
python3 scripts/install-local.py ios --device '<CoreDevice UUID>'
```

The installer builds with `--app-only` by default. `--skip-build` instead verifies
and installs the recorded, signed App, which may differ from current source; it
prints that build's identity before installation. No DMG/IPA is required. Builds
without a record need one fresh build. iOS accepts `--configuration Debug`
(default Release).

Mac installation gracefully quits the exact installed App and retains a managed
rollback backup; it never force-kills CtrlX or touches tmux sessions. iOS installs
in place without uninstalling the App or data. Installation locks the destination
across worktrees. Cleanup, including optional `--save-space`, runs only after
install/launch succeeds. See [installation and rollback](RELEASE.md#local-overwrite-installation).

Prefer the CoreDevice UUID from `devicectl list devices` over a device name.
When discovery or installation fails, first verify that the phone is unlocked,
trusted, in Developer Mode, and shown as available. For signing errors, verify
`Config/Local.xcconfig`, the Apple Development certificate, and both installed
provisioning profiles before changing build settings.

**Killing Mac app:** Use `osascript -e 'quit app "CtrlX"'` — `pkill`/`killall` don't work reliably.

**Cross-AI workflow:** Follow [CONTRIBUTING.md](CONTRIBUTING.md) regardless of the
agent in use. Claude Code hooks are optional automation, not the only source of
formatting, documentation or test requirements. Do not assume another agent ran
them. See [repo hooks](docs/repo-hooks.md).

## Architectural guardrails

- Live terminal bytes and bootstrap snapshots use the same ordered tmux control
  connection. `pipe-pane` is scan-only for OSC side effects, never a second feed.
- Viewer pane identity includes the Host `pairId`; do not key multiple Hosts
  by tmux pane ID alone. Gate new commands by advertised capabilities.
- Files and browser requests must not block the keyboard receive loop. Resolve
  remote paths on the Host, not against the Viewer's filesystem.
- A recognized agent process is not a verified native conversation ID for Fork.
  Keep process-instance ownership, conversation identity and display routing separate.
- Chromium uses CEF's native AppKit message loop. Never restore the external timer
  pump or enter `CefRunMessageLoop` inside a Swift main-actor job. Close pages/tools,
  finish transports/cookie flush, quit the loop, then shut down CEF.
- Use isolated signed E2E apps, private browser profiles and tmux sockets for
  tests. The user handles Keychain authorization; do not send test input to live
  tasks or replace the installed app without authorization.
- SwiftTerm changes need a published fork revision and updated dependency pins
  before release; changing a sibling checkout does not change the pinned package.
- Production release tooling and secrets remain outside Git. Missing maintainer
  tooling is a blocker, not permission to reconstruct deployment commands.

## Reference Docs

Use [the documentation index](docs/README.md) for task routing and history status.
Read the relevant contract before changing these areas:

- [Architecture](docs/architecture.md) and [services](docs/services-reference.md):
  Host/Viewer roles, plugin runtime, launch/Fork, Questions, telemetry and input.
- [Swift patterns](docs/swift-patterns.md): data flow, Sendable, DI and tests.
- [Streaming](docs/streaming-architecture.md), [Mac sizing](docs/swiftterm-sizing.md),
  [iOS viewport/input](docs/swiftterm-ios-scrolling.md) and
  [rendering investigations](docs/terminal-rendering-investigation.md).
- [Files](docs/file-browser.md) and [workspace persistence](docs/folder-layout-persistence-plan.md):
  Host-backed tabs, uploads, previews, path links and private layout restoration.
- [Browser](docs/agent-browser.md), [engines](docs/agent-browser-engines.md),
  [TODO](docs/agent-browser-todo.md) and [capability audit](docs/agent-browser-capability-audit.md):
  CEF lifecycle, owned CLI operations, Viewer leases and acceptance limits.
  Run native engine suites sequentially in an isolated signed app.
- [Agent iOS](docs/agent-simulator-design.md) and
  [agent operations](plugin/ctrlx/skills/agent-ios/references/operations.md):
  Codex-owned native iOS Simulator tabs, private devices, optional simslim profile,
  recording and input limits. `ctrlx ios run -- codex` supplies `--no-daemon`.
  Validate in an isolated signed app; preserve caches
  and reuse unaffected evidence after source-impact review. Local acceptance does
  not establish cross-machine compatibility or public distribution readiness.
- [Sidecar contract](docs/plugins/sidecar-authoring.md): manifest, ingress versus
  stdio wire casing, supervision, distribution and telemetry. Agent-specific
  lifecycle, subagent filtering, response keystrokes and test commands live in
  [pi](plugins/pi/README.md), [omp](plugins/omp/README.md) and
  [opencode](plugins/opencode/README.md), not a shared-agent enum.
- [Quick actions](docs/terminal-quick-actions.md), [CLI](docs/ctrlx-cli-api.md)
  and [emoji](docs/emoji-search.md).
- [E2E](docs/e2e-testing.md), [repo hooks](docs/repo-hooks.md) and
  [stop-finality evaluations](docs/stop-finality-eval.md): isolation, test
  prerequisites and evidence; unavailable evaluations are not passing tests.
- [Self-hosting](docs/self-hosting.md), [staging](docs/staging-relay.md),
  [monitoring](docs/monitoring.md) and [release](RELEASE.md).
- [E2EE design](docs/e2ee-encryption-plan.md) and
  [push notifications](docs/push-notifications-plan.md): consult current source
  alongside historical design sections. Actionable replies must validate the
  current request ID before injecting input.
- Hosted-relay licensing design:
  [base](docs/superpowers/specs/2026-07-13-hosted-relay-monetization-design.md) and
  [trial-start follow-up](docs/superpowers/specs/2026-07-15-trial-status-badge-and-pairing-trial-start-design.md).
  Trial starts on completed pairing, not registration; keep self-hosting free
  of implicit hosted-service configuration. These are design records, not
  deployment authorization.
