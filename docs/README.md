# Technical documentation

Start with [repository rules](../AGENTS.md), [development workflow](../CONTRIBUTING.md),
then the [current architecture](architecture.md). Read only the topics relevant
to your task; the versioned plans are not an onboarding checklist.

## Current references

| Task | Read first | Implementation entry points under `CtrlxPackage/Sources/` |
|---|---|---|
| Understand roles, modules and data flow | [Architecture](architecture.md), [services](services-reference.md) | `CtrlxServerFeature/Coordinators/AppCoordinator.swift`, `CtrlxCommon/Services/ViewerConnectionManager.swift` |
| Terminal stream, reconnect, ordering | [Streaming](streaming-architecture.md) | `CtrlxServerFeature/Services/PaneStreamManager.swift`, `CtrlxServerFeature/Services/TerminalStreamService.swift`, `CtrlxCommon/Services/ViewerConnection.swift` |
| Terminal rendering, input, sizing and gestures | [Mac sizing](swiftterm-sizing.md), [iOS viewport/input](swiftterm-ios-scrolling.md), [rendering investigations](terminal-rendering-investigation.md) | `CtrlxServerFeature/Views/InteractiveTerminalView.swift`, `CtrlxFeature/Views/LiveTerminalView.swift`; SwiftTerm pin in [Package.swift](../CtrlxPackage/Package.swift) |
| Agent lifecycle, launch, resume, Fork and Questions | [Services](services-reference.md) | `CtrlxServerFeature/Plugins/`, `CtrlxPluginProtocol/`, `ClaudeCodePluginCore/`, `CodexPluginCore/`, `CtrlxCommon/Models/CodexQuestionPrompt.swift` |
| Add or change a sidecar agent | [Sidecar contract](plugins/sidecar-authoring.md), [pi](../plugins/pi/README.md), [omp](../plugins/omp/README.md), [opencode](../plugins/opencode/README.md) | `CtrlxServerFeature/Plugins/Sidecar/`; plugin implementations in repository `plugins/` |
| Worktree merge status on Mac Host/Viewer and iOS | [Services](services-reference.md#worktree-merge-status) | `CtrlxServerFeature/Services/WorktreeStatusClient.swift`, `CtrlxCommon/UI/WorktreeStatusView.swift` |
| Files, uploads, preview annotations, terminal path links | [Files](file-browser.md) | `CtrlxCommon/UI/WorkspaceFileBrowserView.swift`, `CtrlxCommon/Utilities/TerminalFileLink.swift`, `CtrlxServerFeature/Services/FileBrowserClient.swift` |
| Browser tabs, Viewer control, annotations | [Browser](agent-browser.md), [engines](agent-browser-engines.md), [remaining work](agent-browser-todo.md) | `CtrlxServerFeature/Services/AgentBrowserService.swift`, `CtrlxCommon/UI/RemoteBrowserView.swift`; native runtime in repository `CtrlxPackage/AgentBrowser/` |
| Browser extensions, ZIP/CRX installation, native extension windows | [Usage and limits](agent-browser.md#browser-extensions), [design and acceptance](browser-extensions-design.md) | `CtrlxServerFeature/Services/BrowserExtensions/`, `CtrlxCommon/UI/RemoteBrowserExtensionsView.swift`; native `BrowserExtensions.inc` and `ExtensionSurface.inc` |
| iOS Simulator control, pane reuse, Viewer viewing, screenshot annotation, recording and storage | [Agent iOS design](agent-simulator-design.md), [agent operations](../plugin/ctrlx/skills/agent-ios/references/operations.md) | `CtrlxServerFeature/Services/AgentSimulatorService.swift`, `CtrlxCommon/UI/RemoteSimulatorView.swift`, `CtrlxServerFeature/Services/SimulatorCoordinator.swift`, `CtrlxCLI/Commands/SimulatorCommands.swift` |
| Layout persistence | [Layout contract](folder-layout-persistence-plan.md) | `CtrlxServerFeature/Services/LayoutPersistence/`, `CtrlxFeature/Models/IOSFileBrowserWorkspace.swift` |
| Quick actions, phrases, voice input and custom buttons | [Quick actions](terminal-quick-actions.md) | `CtrlxCommon/` shared models/UI/voice core; `CtrlxFeature/` iOS and `CtrlxServerFeature/` Mac input UI |
| Wire compatibility, pairing and encryption | [Architecture](architecture.md), [E2EE design](e2ee-encryption-plan.md), [self-hosting](self-hosting.md) | `CtrlxNetworking/Models/`, `CtrlxEncryption/`, `CtrlxExternalServerLib/` |
| Notifications and background monitoring | [Push design and actionable replies](push-notifications-plan.md), [iOS monitoring implementation record](v3.1.0/ios-agent-background-monitoring/IMPLEMENTATION_PLAN.md) | `CtrlxCommon/Services/`, `CtrlxFeature/Services/`, `CtrlxExternalServerLib/Services/APNsService.swift` |
| Build, test, install or publish | [Contributing](../CONTRIBUTING.md), [E2E](e2e-testing.md), [release](../RELEASE.md) | Repository `scripts/`, `Config/`, `Ctrlx.xcworkspace` |
| Relay operations | [Self-hosting](self-hosting.md), [monitoring](monitoring.md), [staging](staging-relay.md) | `CtrlxExternalServerLib/configure.swift`, repository `sbin/` |
| CLI or common Swift patterns | [CLI API](ctrlx-cli-api.md), [Swift patterns](swift-patterns.md), [emoji](emoji-search.md) | `CtrlxCLI/`, `CtrlxCommon/`, `CtrlxEmoji/` |

## Active product backlog

See [产品需求 TODO](product-todo.md) for detachable Mac terminal windows,
argument-aware Agent commands, Agent-side CtrlX plugin update/reinstall UX, and
file-browser playback cache cleanup. Implemented behavior and deferred acceptance
are tracked separately; release contents are recorded in [MODIFICATIONS.md](../MODIFICATIONS.md).

The [multi-agent collaboration design](multi-agent-design.md) includes preset-content
nodes that join upstream outputs and forward them without an Agent, alongside manual
single-Host workflows managed from Mac Host, Mac Viewer and iOS. Users choose
existing or new Agent tabs, configure per-role instructions and attachments,
connect multiple upstream/downstream nodes, and optionally repeat bounded rounds.
The Host owns global instance identity, authorization, durable handoffs and
execution; cross-Host Relay/P2P and Agent-driven orchestration remain later stages.

Content nodes have separate incremental validation in the same report. The UI and
real-Agent evidence below describes the initial Agent-only version.

The single-Host first version is implemented and its scoped acceptance is complete;
iOS automatic speech transcription on a physical device is explicitly deferred to
the user. The
[implementation status](multi-agent-design.md#10-实现进度) separates current evidence
from historical checks. Full isolated Host tests use real Codex/Claude TUI agents
with a deterministic model provider; they cover fan-out/join, six-Agent
many-to-many execution, native completion, authorization, process replacement,
human input, Questions, restart recovery and uncertain writes without replay.
Command-boundary fault injection does not claim coverage inside a PTY syscall.

Actual Mac Host, Mac Viewer and iOS UI evidence covers configuration, new Agent
creation, previews and run controls. Mac/iOS Viewers also operate the same run:
Mac starts, iOS pauses, both retain the upstream result, and Mac continues exactly
one downstream handoff before both automatically show completion. Mac Host End
keeps the Agent alive and archives its late result; native Questions require an
answer before Continue. The restored Mac workflow window's stale readiness label
is fixed, with a signed rebuild and startup UI verification.

Media checks cover snapshot transport and explicit handoff, iOS reviewed audio
text/video frames, and Mac video sampling plus automatic Chinese speech import.
Independent real-model Codex and Claude checks read the same sampled images and
reviewed transcript; they are separate from the deterministic-provider workflow
runs. The iOS simulator provides no compatible speech-recognition format, so
its automatic transcription remains unverified; the user deferred this physical
device check on October 24. Manual transcription and the explicit
unsupported-format error have been exercised.

A real Mac Viewer Pause run exposed a lost completion during a temporary Host
process-scan timeout. The bounded verification retry passes 57 focused tests and
has a signed Mac build; actual two-Viewer, End and Questions flows pass on that
build. No new process-scan fault was injected into those UI runs. The final
current-source filtered regression reports 593 tests across 68 suites, with the
opt-in system-speech test skipped in that invocation and separately exercised on
Mac. All 23 CLI/hook/skill script tests pass. Mac signing/build and iOS Simulator
build evidence are recorded with source-impact checks. This is not an unfiltered
test-suite result or a release; Apple Intelligence device evaluations were not
run, and the installed production app was not replaced.

## Active validation plans

[Android automation research and validation](android-artemis-validation-plan.md)
consolidates the October 14–17 AVD / ARTEMIS, camera, network, Google Play and
Podman/redroid experiments, with an October 18 summary. Start with its
[result matrix](android-artemis-validation-plan.md#当前结论总览),
[next-step recommendations](android-artemis-validation-plan.md#后续建议与验收边界)
and [evidence index](android-artemis-validation-plan.md#关键证据索引).
Basic controls pass; full Meituan login and both autonomous cart runs remain
unverified. The Google APIs AVD and redroid returned raw error `121118`; the
exact rejection rule is unknown. The redroid and Google Play environments were
removed, reclaiming about 9.6 GiB; the original Google APIs AVD, its data and
diagnostic evidence remain. Cloud-phone comparisons and a CtrlX Android backend
are proposals, not completed work. Earlier framework research is in
[the simulator research](ios-simulator-research.md#补充调研google-artemis).

Workspace recovery in 3.0.76 follows [工作现场恢复设计](workspace-recovery-design.md):
session/window/pane reconstruction, detached-window layouts, Agent resume, drafts,
Host/Viewer responsibilities and acceptance criteria. [Implementation progress](v3.0.76/IMPLEMENTATION_PLAN.md)
records completed software integration and deferred hardware acceptance.
Real reboot/login and physical display-removal acceptance are deferred by the
user's 2026-10-16 decision.
The existing folder-template persistence contract remains in the layout document above.

The [Dashboard design](dashboard-design.md) defines the Mac/iOS overview of shared
Agent account quotas, Host resources and collected usage. The first implementation
has passed focused tests, Mac/iOS Simulator builds and isolated UI acceptance.
The document records source conditions and remaining Claude subscription,
cross-physical-Host and iPhone acceptance.

## How to read status and history

- **Current references** above describe the intended present contract. Some also
  retain dated investigations or acceptance records; those apply only to their
  recorded revision and scope. A recent Git modification date does not validate
  every section of a document.
- **Historical designs:** [distributed architecture plan](distributed-architecture-plan.md),
  [original Codex integration](codex-cli-integration-plan.md), and
  `superpowers/specs/` / `superpowers/plans/` explain decisions and migrations.
  They are not current API, deployment or file-location references. Use the
  current topic and source before implementing their old checklists.
- **Versioned work:** `v*/` holds plans, TODOs and review records, not a release
  support matrix. A directory's version does not prove that all its work shipped
  in that version. Open items remain scoped follow-ups, not implicit authorization
  to implement, deploy, install or operate a user's running sessions.
- **Active browser follow-ups:** use [the browser TODO](agent-browser-todo.md) and
  [Viewer acceptance checklist](v3.0.52/STAGE1_TODO.md). Partial implementation,
  fixture tests, real-device acceptance and published artifacts are distinct.
- **Release history:** [MODIFICATIONS.md](../MODIFICATIONS.md), Git commits/tags
  and artifact manifests identify shipped source. Private publishing credentials
  and the maintainer runbook intentionally stay outside this repository; see
  [RELEASE.md](../RELEASE.md), and stop if that environment is unavailable.

## Keeping documentation useful

Update the owning topic with behavior changes; keep this index and `AGENTS.md`
short instead of duplicating contracts. When replacing an architecture, mark the
old design as historical and link its replacement. Check referenced source paths
and commands, not just Markdown links.

For important validation, record the source commit or exact build identity,
command, platform, result and limitations in the existing topic/TODO. `/tmp` and
`.build-local` paths are optional local evidence, not durable or cross-machine
proof. Preserve a small reproducible fixture/test and a result summary; do not
commit credentials, private transcripts or bulk build logs. Historical evidence
must not be relabeled as a fresh test run.
