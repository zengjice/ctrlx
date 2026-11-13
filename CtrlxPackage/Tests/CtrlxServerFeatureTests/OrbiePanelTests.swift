import AppKit
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite(.serialized)
struct OrbiePanelTests {
    @Test
    func creationFormChecksHostIdentityWithoutRequiringAnExistingTmuxServer() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-orbie-empty-host-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let hostID = UUID()
            let ledger = AgentWorkflowStore(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID)
            let workflows = AgentWorkflowService(store: ledger, scan: { _ in
                Issue.record("Preparing creation must not require an existing tmux server")
                throw AgentWorkflowError("No tmux server")
            }, schedule: { _ in })
            let coordinator = AppCoordinator()
            coordinator.agentWorkflowService = workflows
            let creation = try await coordinator.workflowAgentCreation(hostID: hostID)
            #expect(creation.hostID == hostID)
            await #expect(throws: AgentWorkflowError.self) { try await coordinator.workflowAgentCreation(hostID: UUID()) }
            coordinator.agentWorkflowService = nil
            await #expect(throws: AgentWorkflowError.self) { try await coordinator.workflowAgentCreation(hostID: hostID) }
        }
    }

    @Test(arguments: [520.0, 640.0])
    func emptyPanelKeepsCreationAndDraftVisible(width: Double) async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-orbie-ui-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let hostID = UUID()
            let store = OrbieStore(paths: CtrlxPaths(stateRootOverride: root.appendingPathComponent("state")), hostID: hostID)
            let ledger = AgentWorkflowStore(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID)
            let workflows = AgentWorkflowService(store: ledger, scan: { _ in [] }, schedule: { _ in Issue.record("Opening the panel must not send") })
            let orbie = OrbieService(store: store, workflows: workflows, launch: { _ in throw CancellationError() }, locateCreation: { _ in nil })
            await orbie.refresh()
            orbie.draft = "Unsent panel draft"
            let coordinator = AppCoordinator()
            coordinator.orbie = orbie
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: width, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: MacOrbieView().environment(coordinator))
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            hosting.layoutSubtreeIfNeeded()
            if let evidence = ProcessInfo.processInfo.environment["CTRLX_ORBIE_UI_EVIDENCE"], let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let file = URL(fileURLWithPath: evidence).appendingPathComponent("orbie-panel-\(Int(width)).png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: file)
            }
            for identifier in ["orbie-create", "orbie-draft", "orbie-send"] {
                let control = try #require(find(identifier, in: hosting))
                let frameSelector = NSSelectorFromString("accessibilityFrame")
                let implementation = try #require(control.method(for: frameSelector))
                let frame = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> CGRect).self)(control, frameSelector)
                #expect(frame.width > 0 && frame.height > 0)
                #expect(window.frame.contains(frame))
            }
            #expect(orbie.draft == "Unsent panel draft")
            #expect(try await store.load().creation == nil)
        }
    }

    private func find(_ identifier: String, in node: NSObject) -> NSObject? {
        for name in ["accessibilityIdentifier", "accessibilityLabel", "accessibilityValue"] {
            let selector = NSSelectorFromString(name)
            if node.responds(to: selector), node.perform(selector)?.takeUnretainedValue() as? String == identifier {
                return node
            }
        }
        let children = NSSelectorFromString("accessibilityChildren")
        if node.responds(to: children) {
            for child in node.perform(children)?.takeUnretainedValue() as? [NSObject] ?? [] {
                if let match = find(identifier, in: child) {
                    return match
                }
            }
        }
        return nil
    }
}
