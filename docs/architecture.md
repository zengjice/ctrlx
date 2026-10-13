# CtrlX architecture

Current architecture overview, checked against source `fa9c977` (3.0.57) on
2026-10-11. Feature details and acceptance limits live in the
[topic index](README.md); this is not a claim of complete end-to-end validation.

## Roles and module boundaries

CtrlX mirrors existing tmux sessions. A Mac can be a **Host** for local sessions
and a **Viewer** of other Macs at the same time. iOS is a Viewer. Both connect
outbound to a Vapor Relay; application payloads are encrypted between paired
peers. The Relay routes them without owning terminal, filesystem or browser state.

| Module / directory | Responsibility |
|---|---|
| `CtrlxServerFeature` | Mac UI, Host tmux services, plugin runtime, local Files/browser ownership and Mac Viewer integration |
| `CtrlxFeature` | iOS UI, terminal gestures/input, session navigation and background monitoring |
| `CtrlxCommon` | Apple-client shared UI, Viewer connections/stores, input queues, path recognition and system-service clients |
| `CtrlxNetworking` | Platform-independent Codable/Sendable wire models and compatibility contracts; no AppKit/UIKit |
| `CtrlxEncryption` | Peer E2EE and key handling |
| `CtrlxPluginProtocol` | `PluginCore` / `PluginHost`, manifests, ingress and sidecar contracts |
| `ClaudeCodePluginCore`, `CodexPluginCore` | Built-in agent translation, launch/install/scanning and response delivery |
| Repository `plugins/` | External sidecar agents and their event bridges |
| `CtrlxExternalServerLib` | Relay routes, connection hub, pairing persistence, notifications and licensing |
| `CtrlxExternalServer` | Relay executable entry point |
| `CtrlxCLI` | Local CLI commands, including owned browser operations |
| `CtrlxBrowserBridge`, repository `CtrlxPackage/AgentBrowser/` | Swift/native CEF integration and bounded browser automation |

Swift packages contain the implementation. Xcode app/extension entry points
remain thin. See [Swift patterns](swift-patterns.md) for data flow and dependency
injection rather than introducing ViewModels or a second service framework.

## Mac composition root

`CtrlxServer/CtrlxServerApp.swift` starts at `CtrlxAppEntry.main()`, prepares
the browser application runtime, then enters `TmuxPaneMirrorApp`.
`AppCoordinator` is the main-actor composition root. Synchronous initialization
creates core services; guarded `setupAllServices()` wires asynchronous services,
plugins, local API, paired Viewers and remote Hosts.

Important owners:

- `TmuxService`: discovery, geometry, input and session/window operations.
- `TmuxControlClientManager`: per-session control connections.
- `PaneStreamManager`: ordered terminal output and scan-only OSC side effects.
- `MirrorWindowManager`: local pane/session state and attention.
- `TerminalStreamService`: per-Viewer terminal subscriptions and batching.
- `ConnectedViewerManager` / `ConnectedViewer`: Host-side paired connections.
- `ViewerConnectionManager` / `ViewerConnection` and `SessionStore` in
  `CtrlxCommon`: Viewer-side connection/state reused by Mac and iOS.
- `PluginRegistry`, `IngressSocketServer`, `PluginEventDispatcher`:
  agent integration, owned and wired by the coordinator.
- `AgentBrowserService`: native page ownership and authorized browser operations.

## Terminal data and input

```text
tmux → TmuxControlClient (%output + ordered capture boundary)
     → PaneStreamManager
       ├─ local SwiftTerm display
       └─ TerminalStreamService → ConnectedViewer → E2EE Relay
          → ViewerConnection → Mac/iOS SwiftTerm display

tmux pipe-pane → PipePaneReader → OSC side effects only
Viewer input → ordered client queue → encrypted command → Host → tmux
```

Snapshots and live output share one control-mode ordering boundary. The FIFO
reader never feeds ordinary terminal bytes; doing so would duplicate output.
Joining Viewers receive a private bootstrap and only subsequent bytes.
`TerminalStreamService` batches on a 16 ms cadence with an 8 KiB limit and
tracks Viewer ownership, not an unqualified subscriber count.

Geometry belongs to the Host. Entering a session or explicitly selecting a terminal
tab fits that window once to the current client's viewport on Mac (local and remote)
and iOS. Local and remote Fit preserve pane split proportions and affect all Viewers. Passive
Host selection/layout snapshots, rotation, keyboard and font changes do not arm
another fit; this prevents clients from competing over window dimensions. Remote
fitting requires `supportsTerminalFit`. Creation-scoped sizing retains its own
preference and one-shot request. Input, paste
and question expansion use ordered queues. Files/browser I/O uses bounded
separate work so it cannot block keyboard dispatch.

See [streaming](streaming-architecture.md), [Mac sizing](swiftterm-sizing.md),
[iOS viewport/input](swiftterm-ios-scrolling.md) and
[rendering investigations](terminal-rendering-investigation.md).

## Agent events and responses

```text
Agent hook/extension bridge
  → length-prefixed JSON on IngressSocketServer (Unix socket)
  → PluginRegistry → owning PluginCore.handleIngress
    ├─ built-in ClaudeCodePluginCore / CodexPluginCore
    └─ SidecarPluginCore → supervised process, stdio JSON-RPC
  → PluginEventDispatcher → pane state / notifications / app actions
  → encrypted agent_session_status + session snapshots → Viewers

Viewer response → Host request/identity guard → owning core.deliverResponse
                → plugin-specific terminal input
Agent OTLP export → loopback OTLPReceiver → per-session telemetry
```

`AgentSession.pluginID` and `AgentState` identify the agent and its current
state. `PluginPresentation` carries display metadata; project lists use
`AgentProject`. The old shared `CodingAgent` enum and HTTP
`HookServerService` are removed, not alternate integration paths.
The local CLI/API server and OTLP HTTP receiver are separate from hook ingress.

Plugin manifests and enabled cores drive available agents. Installation,
launch arguments, scanners and response translation belong to their core.
Third-party sidecars use the same app-facing contract, not new branches in
shared UI. Native Fork is an optional `AgentSessionForking` capability;
a process match alone does not prove a forkable conversation identity.

Questions have two distinct paths: structured plugin response forms and the
conservative Codex TUI footer auto-expander. Do not replace one with the other.
Details: [services](services-reference.md) and
[sidecar authoring](plugins/sidecar-authoring.md).

## Viewer state and compatibility

A Viewer can connect to multiple Hosts. Connection ownership uses `pairId`;
pane state uses `PaneKey(pairId, paneId)`, since tmux IDs collide across Hosts.
A Mac's local pane state and its remote `SessionStore` are distinct.

Peers negotiate version compatibility; optional capabilities in session state
gate newer commands before transmission. An old Host accepting the handshake
does not imply support for every newer command. Disconnect/reconnect invalidates
pending work and capabilities; stale replies must not mutate a new connection.

The Relay owns pairing/routing/presence and encrypted push delivery, not agent
translation or remote filesystem/CDP access. Platform-independent protocol
changes belong in `CtrlxNetworking`; server behavior belongs in
`CtrlxExternalServerLib`. Additive opaque client payloads often need only client
updates, but verify decoding, capability gating and envelope limits per change.

## Files, browser and workspace ownership

- **Files:** common UI on all clients; paths resolve on the selected Host.
  `FileBrowserClient` / `HostFileBrowser` provide bounded filesystem work,
  `HostFileUploads` manages writes, and per-connection file queues keep it
  outside terminal input. Terminal link recognition runs in shared client code;
  the Host validates the clicked destination. See [Files](file-browser.md).
- **Browser:** Host Chromium/CEF pages can be shared with Mac/iOS Viewers.
  Window-scoped Open Browser and in-app terminal links open/reuse the source
  pane's human page on the Host; default-browser links remain device-local.
  There is no global New Browser or new-page engine picker; existing WebKit tabs
  remain local. `supportsPaneBrowser` gates the new command on Viewers.
  `vercel` / `ctrlx` selects the automation backend, not the rendering
  engine. Agent authority follows a verified process instance, not the focused
  pane. Viewer control requires a lease; there is no raw remote CDP gateway.
  See [browser](agent-browser.md) and [engines](agent-browser-engines.md).
- **Layouts:** session/window/pane terminal geometry is distinct from private
  Files/browser tab selection and per-folder workspace persistence. Shared Host
  terminal layouts do not make every client tab/layout shared. See
  [layout persistence](folder-layout-persistence-plan.md).

## Sidebar Session Ordering

- Mac session rows have an explicit drag handle, independent of the row's click,
  double-click and context menu. Local and remote sections share
  `SessionReorderableRows`; a line marks the insertion point before/after a row.
  Releasing inside the same group saves the order; releasing outside cancels.
  Off-screen row frames are removed, and dismantled drag handles clear the feedback.
  `SessionReorderHandle` captures the mouse sequence with a small AppKit view:
  native `List.onMove` did not fire on macOS 27, and List selection could cancel
  SwiftUI's `DragGesture` before its end callback.
- Before the first drag, `sidebarSortMode` determines the order. A drag captures
  the displayed order as a device-local preference; state changes do not re-rank it.
- The default automatic order is attention → working → idle → plain terminal,
  with session-name ordering within each group. Saved sort-mode choices are
  preserved. Mac uses its own sort mode for local and remote sections; iOS uses
  the mode advertised by each Host, falling back to the same default for older
  Hosts. Mac Settings → Sidebar → Sort Order changes the strategy.
- `AppSettings.localSessionOrder` is separate from remote host ranks. Existing
  pane refreshes reconcile local renames by matching pane-ID sets, remove closed
  sessions and append new sessions. Unchanged ranks do not write preferences.
- The sidebar, menu bar and keyboard session cycling use the same local sorter.
- Right-click Local or a remote Host header → **Restore Automatic Order** to
  clear only that section's preference. On iOS, long-press the Host section
  header in the session list → **Restore Automatic Order**. Restoring clears
  that device's manual rank for the section and resumes its configured automatic
  strategy; it does not change the strategy. The action is disabled when no
  manual rank is saved.
  No manual ordering is sent to tmux or the Relay.

## Concurrency and platform services

UI and observable coordinators are main-actor isolated. Control connections,
process execution, filesystem operations and plugin cores use their declared
actor/worker boundaries; cross-boundary values are Sendable. Do not infer
isolation from a service's filename. For example, `DockIconManager.swift`
exports `DockIconService`, and `SleepPreventionManager.swift` exports
`SleepPreventionService`, both dependency clients.

CEF requires its native AppKit message-loop lifecycle; do not replace it with
a timer pump or run it inside a Swift main-actor job. Its capture workers and
shutdown ordering are documented in [Browser](agent-browser.md).

## Development and deployment

Use [CONTRIBUTING.md](../CONTRIBUTING.md) for isolated worktrees, focused tests
and cross-AI handoff. Use [RELEASE.md](../RELEASE.md) for local packaging versus
publication; a signed build is not proof of installation or runtime acceptance.
The maintained private Mac channel is Apple Development-signed, not notarized.
Formal CEF archives remain gated. Production tooling/credentials are external
and must not be reconstructed from the old distributed deployment plan.
