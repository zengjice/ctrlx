import AppKit
import CtrlxCommon
import CtrlxNetworking
import SwiftUI

/// Native scenes share application services, but never the main window's input router.
public struct DetachedTerminalScene: Scene {
    private let coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some Scene {
        WindowGroup("Terminal", id: "detached-terminal", for: DetachedTerminalTarget.self) { target in
            if let target = target.wrappedValue {
                DetachedTerminalContent(target: target)
                    .environment(coordinator)
                    .environment(coordinator.settings)
                    .environment(coordinator.tmuxService)
                    .environment(coordinator.windowManager)
                    .environment(coordinator.paneStreamManager)
                    .environment(coordinator.editorSessionManager)
                    .environment(coordinator.remoteEditorContentStore)
                    .environment(coordinator.markdownOpenSuggestionStore)
            }
        }
        .defaultSize(width: 1_000, height: 700)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

@MainActor
private struct DetachedTerminalContent: View {
    let target: DetachedTerminalTarget
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @State private var router = TerminalQuickActionRouter()
    @State private var contentSize: CGSize = .zero
    @State private var resizeError: String?
    @State private var isResizing = false

    private var local: LocalTmuxWindow? {
        guard target.hostID == nil else { return nil }
        return coordinator.tmuxService.windows.first { $0.stableId == target.windowID }
    }

    private var remote: TmuxWindow? {
        guard let host = target.hostID else { return nil }
        return coordinator.remoteSessionStore?.windows(for: host).first { $0.stableId == target.windowID }
    }

    private var connection: ViewerConnection? {
        target.hostID.flatMap { coordinator.viewerConnectionManager?.connection(for: $0) }
    }

    private var panes: [PaneState] {
        remote?.panes ?? local?.panes.compactMap { coordinator.windowManager.paneStates[$0.paneId] } ?? []
    }

    private var focusedPaneID: String? {
        let focused = router.active.flatMap { $0.hostID == target.hostID ? $0.paneID : nil }
        return FileBrowserTab.sourcePaneID(
            in: panes.map(\.paneId),
            focusedPaneID: focused,
            activePaneID: remote?.activePane?.paneId ?? local?.activePane?.paneId
        )
    }

    private var forkUnavailableReason: String? {
        guard let host = target.hostID else { return nil }
        guard let store = coordinator.remoteSessionStore else { return "Host is unavailable." }
        return store.agentForkUnavailableReason(hostID: host, isConnected: connection?.isHostConnected == true)
    }

    var body: some View {
        VStack(spacing: 0) {
            terminal
        }
        .frame(minWidth: 400, minHeight: 250)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { contentSize = $0 }
        .background(settings.theme.workspaceBackgroundColor)
        .preferredColorScheme(settings.theme.workspaceColorScheme)
        .environment(\.terminalQuickActions, router)
        .environment(\.openTerminalFileLink) { showInMain(.fileLink($0)) }
        .navigationTitle(remote?.windowName ?? local?.windowName ?? "Terminal")
        .background(DetachedTerminalRegistration(target: target, windows: coordinator.detachedWindows))
        .toolbar {
            ToolbarItemGroup {
                if !settings.showStatusBar {
                    TerminalQuickActionButtons(router: router)
                }
                Button("Fit Terminal", action: resizeToFit)
                    .disabled(panes.isEmpty || isResizing || (target.hostID != nil && connection?.isHostConnected != true))
                Menu("Window") {
                    Button("Open Files in Main Window") { showInMain(.files(paneID: focusedPaneID)) }
                        .disabled(panes.isEmpty)
                    AgentForkMenu(
                        sources: panes.compactMap(AgentForkSource.init(pane:)),
                        unavailableReason: forkUnavailableReason,
                        sourceUnavailableReason: AgentForkSource.unavailableReason(panes: panes),
                        choose: { showInMain(.fork(paneID: focusedPaneID, worktree: $0)) }
                    )
                    Divider()
                    Button("Return to Main Window") {
                        showInMain(.show)
                        coordinator.detachedWindows.close(target)
                    }
                }
            }
        }
        .focusedSceneValue(\.closeCurrentTabAction) { coordinator.detachedWindows.close(target) }
        .alert("Terminal Error", isPresented: Binding(get: { resizeError != nil }, set: { if !$0 { resizeError = nil } })) {
            Button("OK") { resizeError = nil }
        } message: { Text(resizeError ?? "") }
    }

    @ViewBuilder private var terminal: some View {
        if let local {
            WindowPaneLayoutView(window: local, onOpenURL: openURL)
        } else if let remote, let connection {
            RemoteWindowPaneLayoutView(
                window: remote,
                connection: connection,
                settings: settings,
                onOpenURL: openURL
            )
        } else {
            ContentUnavailableView {
                Label("Terminal Unavailable", symbol: .terminal)
            } description: {
                Text(target.hostID == nil ? "This tmux Window is no longer available." : "Waiting for the Host. You can return to the main window at any time.")
            }
        }
    }

    private func showInMain(_ action: DetachedTerminalWindows.Action) {
        coordinator.detachedWindows.request(action, from: target)
        openWindow(id: "panes")
    }

    private func openURL(_ url: URL) -> Bool {
        if target.hostID != nil, RemoteTerminalURLPolicy.shouldConsumeWithoutOpening(url) { return true }
        if url.isFileURL {
            guard settings.openClickedFileInNewTab else { return false }
        } else {
            guard
                BrowserURLDispatcher.canHandle(url),
                (settings.browserBehavior(for: url) ?? settings.browserLinkBehavior) != .alwaysInDefaultBrowser else { return false }
        }
        showInMain(.url(url.absoluteString))
        return true
    }

    private func resizeToFit() {
        guard !isResizing, !panes.isEmpty, contentSize.width > 100, contentSize.height > 100 else { return }
        let cell = FontMetrics.calculateCellSize(fontName: settings.fontName, fontSize: CGFloat(settings.fontSize))
        let columns = max(80, min(300, Int((contentSize.width - FontMetrics.horizontalBuffer) / cell.width)))
        let rows = max(24, min(100, Int((contentSize.height - (settings.showStatusBar ? 40 : 10)) / cell.height)))
        isResizing = true
        Task {
            defer { isResizing = false }
            do {
                if let host = target.hostID {
                    guard let connection = coordinator.viewerConnectionManager?.connection(for: host), connection.isHostConnected else {
                        throw AgentForkError("Host is offline.")
                    }
                    _ = try await connection.sendCommand(ResizeTmuxPane(width: columns, height: rows, userInitiated: true), paneId: target.windowID).get()
                } else {
                    try await coordinator.tmuxService.resizePane(target.windowID, width: columns, height: rows)
                }
            } catch { resizeError = "Failed to resize: \(error.localizedDescription)" }
        }
    }
}

/// Observe the actual native close, not SwiftUI disappearance (fullscreen can reparent views).
struct DetachedTerminalRegistration: NSViewRepresentable {
    let target: DetachedTerminalTarget
    let windows: DetachedTerminalWindows

    func makeNSView(context: Context) -> RegistrationView {
        RegistrationView(target: target, windows: windows)
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) { }

    final class RegistrationView: NSView {
        let target: DetachedTerminalTarget
        let windows: DetachedTerminalWindows

        init(target: DetachedTerminalTarget, windows: DetachedTerminalWindows) {
            self.target = target
            self.windows = windows
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            windows.attach(window, to: target)
        }
    }
}

struct DetachedTerminalPlaceholder: View {
    let target: DetachedTerminalTarget
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            Text("This terminal is open in a separate window.")
            Button("Show Window") { openWindow(id: "detached-terminal", value: target) }
            Button("Return Here") { coordinator.detachedWindows.close(target) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DetachedTerminalPresentation: ViewModifier {
    let hostID: String?
    let windowID: String
    @Environment(AppCoordinator.self) private var coordinator

    func body(content: Content) -> some View {
        if
            let target = DetachedTerminalTarget(hostID: hostID, windowID: windowID),
            coordinator.detachedWindows.targets.contains(target) {
            DetachedTerminalPlaceholder(target: target)
        } else {
            content
        }
    }
}
