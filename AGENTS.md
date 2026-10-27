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
- Before direct Mac workspace builds, run `bash scripts/build-device-installer.sh`
  to prepare the bundled IPA installer. Local Mac packaging runs it automatically.
- Unit tests: `./scripts/unit-tests.sh` (pass filters after `--`). Uses Swift's
  `swiftbuild` backend without indexes; after success, prunes old native-backend
  outputs and test indexes. Do not alternate backends or build concurrently in
  the same package cache. Use `--save-space` to remove test compilation caches
  after success, keeping test products and dependencies.

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

The script can run in any Git worktree. Configure that worktree's ignored
`Config/Local.xcconfig`; caches and artifacts remain worktree-local. It builds
both the app and its notification extension, selects matching installed provisioning profiles,
signs and verifies the result, and defaults to an optimized Release build:

- Installable app: `.build-local/DerivedData/iOS/Build/Products/Release-iphoneos/CtrlX.app`
- IPA: `dist/CtrlX-<version>.ipa`
- Integrity metadata: adjacent `.sha256` and `.manifest.json` files

Both platform packaging scripts accept `--app-only` to build/sign/verify without
creating a DMG/IPA. A successful build records its identity in `CtrlX.app.build.json`
beside the App; the old record is invalidated before rebuilding. Full local packaging
validates a staged package before replacing the old package and its sidecars.

Packaging deletes temporary App copies on exit and keeps two local IPA/DMG
packages per platform/configuration. Successful packaging removes old platform
indexes, duplicate dependency copies and completed public-download verification
copies; reusable build/download caches and installable apps remain worktree-local.
Successful packaging also removes explicitly completed immediate child directories
under `.build-local/app-backups/` and `.build-local/diagnostics/`: add an empty
`.ctrlx-cleanup-ready` file only after their processes have stopped and the backup
or evidence is no longer needed. App backups require a verified replacement and
a retained rollback package. Unmarked directories and every worktree's incremental
caches remain. `python3 scripts/clean-build.py housekeeping` previews this cleanup;
add `--yes` to apply it without rebuilding. See `RELEASE.md`.
Packaging warns below 20 GiB free before building. Local Mac/iOS packaging accepts
`--save-space`: only after success, remove that platform's compilation intermediates
and module/SDK caches, retaining signed installable apps and downloaded dependencies.
The next build is slower; this mode cannot free space before the current build.
Default behavior remains incremental. Script-managed packaging, native-browser
preparation, package tests, installation and destructive cleanup share a worktree
operation lock. Raw Xcode/Swift commands are not covered; never run them concurrently
against the same caches (or use `python3 scripts/local_build.py run -- <command>`).
Cleanup never sweeps other worktrees.
Use `python3 scripts/clean-build.py deep` to preview deep cleanup; add `--yes`
only when builds and device installs in that worktree are stopped. See `RELEASE.md`.
Prefer `python3 scripts/clean-build.py idle` for an inactive worktree: it preserves
signed apps, packages and downloaded dependencies. Both modes stay worktree-local.
Packaging and `idle` also retain only the two latest **completed** managed browser
verification copies and local install backups per kind. For disposable
`.build-local/upstream-browser-proof.*` / `mac-install-backup.*` directories, run
their full test or authorized install/verify workflow through
`python3 scripts/clean-build.py use-artifact --path <directory> -- <command>`.
It locks the directory during use, invalidates prior success on retry, and records
completion only after a successful command. The command must stop all consumers
before returning; never use it for detached apps or ongoing simulator state.
The browser preparation script prints the wrapped command. Preview with
`python3 scripts/clean-build.py retained`; unmarked legacy copies and failed runs
are kept, never bulk-adopted. See `RELEASE.md` for supported names and retention.

For same-source performance comparisons, `--configuration Debug` produces
`Debug-iphoneos/CtrlX.app` and a separate `CtrlX-<version>-Debug.ipa`. Install the
configuration printed by the script; do not reuse the other configuration's app.

This is a local-development IPA. TestFlight/App Store upload remains deliberately
blocked by `scripts/testflight.sh` pending the review documented in `RELEASE.md`.

Both provisioning profiles must belong to the same team. The app bundle ID must
also match the Relay's APNs configuration for background notifications to work.
Do not try to install an intermediate app produced with
`CODE_SIGNING_ALLOWED=NO`; install the script's final, verified `CtrlX.app`.

Use the unified local installer for build/sign/install/launch and cleanup.
It supports any worktree and does not publish or deploy the Relay:

```bash
python3 scripts/install-local.py macos
xcrun devicectl list devices
python3 scripts/install-local.py ios --device '<CoreDevice UUID>'
```

By default it calls the existing platform packaging script with `--app-only`;
`--skip-build` installs the recorded, signed App after checking its bundle ID,
version, revision and build stamp against the App build record, without requiring
a DMG/IPA. Older builds without a record need one fresh build. iOS accepts
`--configuration Debug` (default Release).
Both platforms accept `--save-space`, applied only after installation and launch
succeed. Mac uses an exact installed-process check, graceful quit, temporary staging
and a managed rollback backup; it never force-kills CtrlX or touches tmux sessions.
Temporary staging is removed on exit; completed backups retain the latest two,
failed backups remain. iOS installs in place without uninstalling the App or data.
The nested build defers retention until install/launch succeeds, so cleanup runs
once. Conflicting script-managed worktree operations are rejected; installation
also locks the destination App/device across worktrees. See `RELEASE.md`.

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
  Build native components with `bash scripts/build-agent-browser.sh` before
  direct Mac workspace builds; local packaging does this automatically.
  Run native engine suites sequentially in an isolated signed app.
- [Agent iOS](docs/agent-simulator-design.md) and
  [agent operations](plugin/ctrlx/skills/agent-ios/references/operations.md):
  Codex-owned native iOS Simulator tabs, private devices, optional simslim profile,
  recording and input limits. `ctrlx ios run -- codex` supplies `--no-daemon`.
  Build native components with `bash scripts/build-agent-simulator.sh` before a
  direct Mac workspace build. Validate in an isolated signed app; preserve caches
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
