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
| Files, uploads, previews, terminal path links | [Files](file-browser.md) | `CtrlxCommon/UI/WorkspaceFileBrowserView.swift`, `CtrlxCommon/Utilities/TerminalFileLink.swift`, `CtrlxServerFeature/Services/FileBrowserClient.swift` |
| Browser tabs, Viewer control, annotations | [Browser](agent-browser.md), [engines](agent-browser-engines.md), [remaining work](agent-browser-todo.md) | `CtrlxServerFeature/Services/AgentBrowserService.swift`, `CtrlxCommon/UI/RemoteBrowserView.swift`; native runtime in repository `CtrlxPackage/AgentBrowser/` |
| Layout persistence | [Layout contract](folder-layout-persistence-plan.md) | `CtrlxServerFeature/Services/LayoutPersistence/`, `CtrlxFeature/Models/IOSFileBrowserWorkspace.swift` |
| Quick actions, phrases and custom buttons | [Quick actions](terminal-quick-actions.md) | `CtrlxCommon/` shared models/UI; `CtrlxFeature/` iOS input UI |
| Wire compatibility, pairing and encryption | [Architecture](architecture.md), [E2EE design](e2ee-encryption-plan.md), [self-hosting](self-hosting.md) | `CtrlxNetworking/Models/`, `CtrlxEncryption/`, `CtrlxExternalServerLib/` |
| Notifications and background monitoring | [Push design and actionable replies](push-notifications-plan.md), [iOS monitoring implementation record](v3.1.0/ios-agent-background-monitoring/IMPLEMENTATION_PLAN.md) | `CtrlxCommon/Services/`, `CtrlxFeature/Services/`, `CtrlxExternalServerLib/Services/APNsService.swift` |
| Build, test, install or publish | [Contributing](../CONTRIBUTING.md), [E2E](e2e-testing.md), [release](../RELEASE.md) | Repository `scripts/`, `Config/`, `Ctrlx.xcworkspace` |
| Relay operations | [Self-hosting](self-hosting.md), [monitoring](monitoring.md), [staging](staging-relay.md) | `CtrlxExternalServerLib/configure.swift`, repository `sbin/` |
| CLI or common Swift patterns | [CLI API](ctrlx-cli-api.md), [Swift patterns](swift-patterns.md), [emoji](emoji-search.md) | `CtrlxCLI/`, `CtrlxCommon/`, `CtrlxEmoji/` |

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
