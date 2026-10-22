import AppKit
import CtrlxCommon
import SwiftUI

/// Independent scenes use the same workbench as the main window, with private tab selection.
public struct DetachedTerminalScene: Scene {
    private let coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some Scene {
        WindowGroup("Workspace", id: "detached-terminal", for: UUID.self) { id in
            if let id = id.wrappedValue, let workspace = coordinator.detachedWindows.workspaces[id] {
                MainView(detachedWorkspace: workspace)
                    .frame(minWidth: 400, minHeight: 250)
                    .environment(coordinator)
                    .environment(coordinator.settings)
                    .environment(coordinator.tmuxService)
                    .environment(coordinator.windowManager)
                    .environment(coordinator.paneStreamManager)
                    .environment(coordinator.editorSessionManager)
                    .environment(coordinator.remoteEditorContentStore)
                    .environment(coordinator.markdownOpenSuggestionStore)
                    .environment(coordinator.getOrCreatePairingManager())
                    .environment(coordinator.licenseManager)
                    .environment(\.e2eeService, coordinator.e2eeService)
            }
        }
        .defaultSize(width: 1_000, height: 700)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

extension EnvironmentValues {
    @Entry var workbenchWindowID: UUID?
}

/// Native close is authoritative: fullscreen can temporarily detach/reparent SwiftUI content.
struct WorkbenchWindowRegistration: NSViewRepresentable {
    let workspaceID: UUID?
    let windows: DetachedTerminalWindows
    var diagnosticContext: AppKitWindowDiagnosticContext?

    func makeNSView(context: Context) -> RegistrationView {
        let view = RegistrationView(workspaceID: workspaceID, windows: windows)
        view.diagnosticContext = diagnosticContext
        return view
    }

    func updateNSView(_ view: RegistrationView, context: Context) {
        view.diagnosticContext = diagnosticContext
    }

    final class RegistrationView: NSView {
        let workspaceID: UUID?
        let windows: DetachedTerminalWindows
        private weak var diagnosticWindow: NSWindow?
        var diagnosticContext: AppKitWindowDiagnosticContext? {
            didSet {
                if let window {
                    AppKitDiagnostics.shared.setContext(diagnosticContext, for: window)
                }
            }
        }

        init(workspaceID: UUID?, windows: DetachedTerminalWindows) {
            self.workspaceID = workspaceID
            self.windows = windows
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let diagnosticWindow, diagnosticWindow !== window {
                AppKitDiagnostics.shared.setContext(nil, for: diagnosticWindow)
            }
            diagnosticWindow = window
            if let window {
                windows.attach(window, toWorkspace: workspaceID)
                AppKitDiagnostics.shared.setContext(diagnosticContext, for: window)
            }
        }
    }
}

struct DetachedTerminalPlaceholder: View {
    let target: DetachedTerminalTarget
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        VStack(spacing: 12) {
            Text("This terminal is open in another window.")
            Button("Show Window") {
                if !coordinator.detachedWindows.focus(hostID: target.hostID, windowID: target.windowID) {
                    coordinator.detachedWindows.request(.show, from: target)
                }
            }
            if coordinator.detachedWindows.contains(hostID: target.hostID, windowID: target.windowID) {
                Button("Return Here") { coordinator.detachedWindows.close(target) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DetachedTerminalPresentation: ViewModifier {
    let hostID: String?
    let windowID: String
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.workbenchWindowID) private var workspaceID

    func body(content: Content) -> some View {
        if
            let target = DetachedTerminalTarget(hostID: hostID, windowID: windowID),
            coordinator.detachedWindows.owner(hostID: hostID, windowID: windowID) != workspaceID {
            DetachedTerminalPlaceholder(target: target)
        } else {
            content
        }
    }
}
