import AppKit
import CtrlxCommon
import CtrlxNetworking
import SwiftUI

public extension View {
    /// The menu-bar label exists even when no workspace window is open.
    func orbiePanelIntegration(coordinator: AppCoordinator) -> some View {
        modifier(OrbiePanelSceneIntegration(coordinator: coordinator))
    }
}

private struct OrbiePanelSceneIntegration: ViewModifier {
    let coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.task { coordinator.configureOrbiePanel(openWindow: openWindow) }
    }
}

extension AppCoordinator {
    func configureOrbiePanel(openWindow: OpenWindowAction) {
        orbiePanel.start { openWindow(id: "orbie-panel") }
    }

    func presentOrbiePanel(openWindow: OpenWindowAction) {
        configureOrbiePanel(openWindow: openWindow)
        orbiePanel.show()
    }

    func openOrbiterTask(_ id: UUID, openWindow: OpenWindowAction) async throws {
        let pane = try await resolveOrbiterTaskPane(id)
        orbiePanel.dismiss(restoreFocus: false)
        NSApp.activate()
        detachedWindows.sourcePaneRequest = .init(hostID: nil, pane: pane)
        let owner = detachedWindows.owner(hostID: nil, windowID: pane.stableWindowId)
        if !detachedWindows.focusNativeWindow(workspaceID: owner) {
            if let owner {
                openWindow(id: "detached-terminal", value: owner)
            } else {
                openWindow(id: "panes")
            }
        }
    }

    func resolveOrbiterTaskPane(_ id: UUID) async throws -> PaneState {
        guard let orbiters else { throw AgentWorkflowError("Tasks are still starting on this Mac.") }
        windowManager.updatePaneStates(from: await tmuxService.refreshPanes())
        let task = try await orbiters.taskForNavigation(id)
        guard
            let identity = task.binding?.workspacePane ?? task.pane,
            let pane = windowManager.paneStates.values.first(where: { $0.workspaceIdentity?.isSamePane(as: identity) == true }) else {
            throw AgentWorkflowError("This task’s original terminal is unavailable. Open its saved details and use the existing Resume or Use Shell controls. No task was resent.")
        }
        return pane
    }
}

struct OrbiePanelWindowAttachment: NSViewRepresentable {
    let controller: OrbiePanelController
    func makeNSView(context: Context) -> Anchor {
        Anchor(controller: controller)
    }

    func updateNSView(_ view: Anchor, context: Context) { }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        NotificationCenter.default.removeObserver(view)
    }

    final class Anchor: NSView {
        let controller: OrbiePanelController
        init(controller: OrbiePanelController) {
            self.controller = controller
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            controller.attach(window)
            NotificationCenter.default.addObserver(self, selector: #selector(becameKey), name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(resigned), name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: window)
        }

        @objc
        private func becameKey() {
            controller.becameKey()
        }

        @objc
        private func resigned() {
            controller.resignedKey()
        }

        @objc
        private func closed() {
            controller.dismiss(restoreFocus: false)
        }
    }
}
