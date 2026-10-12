# Contributing to CtrlX

Thanks for your interest! Issues and pull requests are welcome.

## Before you start

- **Bugs / features** — open a [GitHub issue](https://github.com/zengjice/ctrlx/issues)
  first for anything non-trivial so we can agree on the approach.
- **Security issues** — never open a public issue; see [SECURITY.md](SECURITY.md).
- Read [AGENTS.md](AGENTS.md), then use the [documentation index](docs/README.md)
  to find the current contract for your task. Historical plans are not current
  implementation instructions.

## Working with other developers and AI agents

These rules apply regardless of which AI tool is used; `.claude` hooks are only
optional automation for the same workflow.

1. Inspect `git status --short --branch`, recent commits and `git worktree list`
   before editing. Preserve unrelated changes; ask before touching overlapping
   work. Do not switch, stash, reset or clean another contributor's workspace.
2. Use an assigned worktree. When a separate worktree is needed and authorized,
   create it with `git worktree add` under the primary checkout's
   `.worktrees/<task-name>/` (find the primary via `git worktree list`). Ensure
   `/.worktrees/` is ignored first. Never nest a worktree inside another one or
   make the primary checkout clean by moving someone else's edits.
3. Keep signing files, caches and artifacts local to that worktree. Serialize
   operations that share a package cache, DerivedData or `.build-local/SourcePackages`;
   Mac and iOS packaging in one worktree share dependency storage. Do not clean
   while builds or device installs are active. Cleanup scope and preview commands
   are in [RELEASE.md](RELEASE.md).
4. Implement only the requested scope. A review/diagnosis does not authorize a
   fix. Commit, push, merge, install, publish and deploy only when requested;
   permission for one is not permission for all. Mac publication does not imply
   Relay deployment or replacement of the local running app.
5. Hand off the branch/commit, changed behavior, tests actually run and remaining
   blockers. Distinguish compilation, signing, installation and runtime acceptance.
   Never claim another agent's or an old build's test as a fresh result.

## Project layout

Almost all code lives in the Swift package, not the Xcode project:

| Area | Where |
|---|---|
| macOS app | `CtrlxPackage/Sources/CtrlxServerFeature/` |
| iOS app | `CtrlxPackage/Sources/CtrlxFeature/` |
| Shared Apple-client UI/services | `CtrlxPackage/Sources/CtrlxCommon/` |
| Shared networking | `CtrlxPackage/Sources/CtrlxNetworking/` |
| Encryption | `CtrlxPackage/Sources/CtrlxEncryption/` |
| Agent contracts and built-in cores | `CtrlxPackage/Sources/CtrlxPluginProtocol/`, `ClaudeCodePluginCore/`, `CodexPluginCore/` |
| Relay implementation / executable | `CtrlxPackage/Sources/CtrlxExternalServerLib/` / `CtrlxExternalServer/` |
| Sidecar plugins | `plugins/` (Python; see [docs/plugins/sidecar-authoring.md](docs/plugins/sidecar-authoring.md)) |

Internal Swift modules use the `Ctrlx` prefix; user-facing branding is `CtrlX`.

## Building and testing

- Requires a recent Xcode (Swift 6.3+ toolchain), macOS 15+, and tmux.
- Mac app: open `Ctrlx.xcworkspace`, scheme `CtrlxServer`.
  iOS app: scheme `Ctrlx`.
- Unit tests: `./scripts/unit-tests.sh` (or `./scripts/unit-tests.sh -- --filter SuiteName`).
- End-to-end suite: `./scripts/e2e-test.sh` (see [docs/e2e-testing.md](docs/e2e-testing.md)).
  E2E screenshot baselines are CI-generated — don't commit locally regenerated
  baselines.
- Tip: `git clone --filter=blob:none` makes the first clone much faster.

Choose checks proportional to the change:

| Change | Validation |
|---|---|
| Documentation/template only | `git diff --check`; check local links, source paths and documented commands against the repository. No app build needed. |
| Pure/shared Swift behavior | Focused `./scripts/unit-tests.sh -- --filter SuiteName`; add a regression for a bug. Compile affected platform targets when conditional code/UI changed. |
| Native UI/input/lifecycle | Focused tests plus an affected-platform build and targeted UI acceptance. A device-SDK compile is not execution of UIKit tests. Follow a user's real-device-only constraint. |
| Wire models/commands | Compatibility/old-peer tests, capability gates and relevant Host/Viewer tests; determine separately whether Relay behavior changed. |
| Browser native runtime | Follow isolated signed-app acceptance in [Browser](docs/agent-browser.md); do not operate personal profiles or running tasks as fixtures. |
| Scripts/packaging | Relevant `scripts/tests` tests and shell syntax checks; run packaging only when needed/requested. |

For code changes also run `bash scripts/check-ctrlx-brand-boundary.sh` and
`bash scripts/check-ctrlx-technical-boundary.sh`. For Swift files, use
`swiftformat --lint <changed-file.swift>` (or format the affected files with the
repository config); do not reformat the entire repository incidentally.

The normal suite includes real Apple Intelligence evaluations with device/model
prerequisites; see [stop-finality evaluation](docs/stop-finality-eval.md). If those
are unavailable, report that explicitly. A bounded regression run can use
`./scripts/unit-tests.sh -- --no-parallel --skip StopFinalityEvaluationSuite`,
but it is not a fully passing unfiltered suite. Do not hide unrelated failures
by expanding exclusions.

Build/install commands are in [AGENTS.md](AGENTS.md); signing, artifact retention
and publication are in [RELEASE.md](RELEASE.md). Use the repository scripts,
not a second handwritten signing/deployment procedure.

## Code conventions

The short version (full details in [AGENTS.md](AGENTS.md) and
[docs/swift-patterns.md](docs/swift-patterns.md)):

- SwiftUI with native data flow (`@State`, `@Observable`, `@Environment`) — no
  ViewModels.
- Swift Concurrency only (`@MainActor` UI, actors for I/O) — no GCD.
- [Point-Free Dependencies](https://github.com/pointfreeco/swift-dependencies)
  for services that wrap system APIs or perform I/O.
- Match the existing style. Claude Code's hook can run SwiftFormat automatically;
  other tools must perform the same applicable check explicitly.
- Fail fast with descriptive errors; no empty catch blocks.

## Pull requests

- Keep PRs focused — unrelated changes belong in separate PRs.
- Run the applicable checks above; add tests for new behavior and report any
  failures or unavailable validation explicitly.
- Follow the [PR checklist](.github/PULL_REQUEST_TEMPLATE.md) even when no tool
  hook runs. Update the owning topic for behavior changes and link it from the
  [index](docs/README.md) if it adds a new area; avoid duplicate contracts.
- By contributing you agree your work is licensed under the project's
  [AGPL-3.0 license](LICENSE).
