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
    func openOrbieTerminal(openWindow: OpenWindowAction) async throws {
        windowManager.updatePaneStates(from: await tmuxService.refreshPanes())
        guard
            let record = orbie?.record, let target = record.target,
            let pane = windowManager.paneStates.values.first(where: { $0.workspaceIdentity?.paneID == target.paneID }) else {
            throw AgentWorkflowError("Orbie’s terminal is unavailable. Restore the original conversation or explicitly set up Orbie again.")
        }
        orbiePanel.dismiss(restoreFocus: false)
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

    func configureOrbiePanel(openWindow: OpenWindowAction) {
        orbiePanel.start { openWindow(id: "orbie-panel") }
    }

    func presentOrbiePanel(openWindow: OpenWindowAction) {
        configureOrbiePanel(openWindow: openWindow)
        orbiePanel.show()
    }

    func openOrbiter(_ id: String, openWindow: OpenWindowAction) async throws {
        let pane = try await resolveOrbiterPane(id)
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

    func openOrbieWorkflow(_ id: UUID, openWindow: OpenWindowAction) async throws {
        guard let workflow = agentWorkflowService, let paths = ctrlxPaths, let hostID = agentRuntimeCatalog?.hostID else {
            throw AgentWorkflowError("Workflows are unavailable.")
        }
        let main = try await OrbieStore(paths: paths, hostID: hostID).load()
        let agents = try await OrbiterStore(paths: paths, hostID: hostID).load()
        let archive = try await workflow.snapshot(refreshInstances: true)
        let targets = Set(agents.agents.compactMap(\.agentID) + [main.target?.agentID].compactMap { $0 })
        guard archive.hostID == hostID, OrbieAgentCatalog.associatedWorkflows(archive, targets: targets, instances: archive.instances).contains(where: { $0.id == id }) else {
            throw AgentWorkflowError("This Workflow is no longer associated with Orbie or its Orbiters.")
        }
        orbiePanel.dismiss(restoreFocus: false)
        workflowNavigation.path = [.host("local"), .configuration(route: "local", hostID: hostID, id: id)]
        openWindow(id: "workflows")
    }

    func resolveOrbiterPane(_ id: String) async throws -> PaneState {
        guard let orbiters else { throw AgentWorkflowError("Orbiters are still starting on this Mac.") }
        windowManager.updatePaneStates(from: await tmuxService.refreshPanes())
        let task = try await orbiters.recordForNavigation(id)
        guard
            let identity = task.binding?.workspacePane ?? task.pane,
            let pane = windowManager.paneStates.values.first(where: { $0.workspaceIdentity?.isSamePane(as: identity) == true }) else {
            throw AgentWorkflowError("This Orbiter’s original terminal is unavailable. Open its saved details and use the Resume or Use Shell controls. No message was resent.")
        }
        return pane
    }
}

struct OrbiePanelWindowAttachment: NSViewRepresentable {
    let controller: OrbiePanelController
    var preferredHeight: CGFloat = 590
    func makeNSView(context: Context) -> Anchor {
        Anchor(controller: controller)
    }

    func updateNSView(_ view: Anchor, context: Context) {
        controller.resizeContent(height: preferredHeight)
    }

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
