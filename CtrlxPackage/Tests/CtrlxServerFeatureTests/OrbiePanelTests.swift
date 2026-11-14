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
    private actor ScanGate {
        var started = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !released else { return }
            started = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    @Test
    func openAgentTabRemainsEnabledDuringSlowInspection() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-orbie-refresh-ui-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let hostID = UUID()
            let store = OrbieStore(paths: .init(stateRootOverride: root.appendingPathComponent("state")), hostID: hostID)
            var record = OrbieRecord(hostID: hostID)
            record.enabled = true
            record.creation = .init(id: UUID(), pluginID: "codex", providerID: nil, directory: root.path, pane: .init(serverID: "private", sessionID: UUID(), windowID: UUID(), paneID: UUID()))
            try await store.save(record)
            let gate = ScanGate()
            let workflows = AgentWorkflowService(store: .init(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID), scan: { _ in
                await gate.wait()
                return []
            }, schedule: { _ in Issue.record("Inspection must not submit work") })
            let orbie = OrbieService(store: store, workflows: workflows, launch: { _ in throw CancellationError() }, locateCreation: { _ in nil })
            await orbie.refresh(inspect: false)
            let refreshing = Task { await orbie.refresh() }
            defer { Task { await gate.release()
                await refreshing.value
            } }
            for _ in 0..<100 {
                if await gate.started {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await gate.started)
            let coordinator = AppCoordinator()
            coordinator.orbie = orbie
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 640, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: MacOrbieView().environment(coordinator))
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            hosting.layoutSubtreeIfNeeded()
            #expect(orbie.isBusy)
            let button = try #require(find("orbie-open-agent", in: hosting))
            let selector = NSSelectorFromString("isAccessibilityEnabled")
            let implementation = try #require(button.method(for: selector))
            #expect(unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)(button, selector))
            await gate.release()
            await refreshing.value
            #expect(try await workflows.snapshot().runs.isEmpty)
        }
    }

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

    @Test
    func taskDraftControlsFitSmallestWindowWithoutCreatingAnAgent() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-orbiter-ui-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let hostID = UUID()
            let workflows = AgentWorkflowService(store: AgentWorkflowStore(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID), scan: { _ in [] }, schedule: { _ in Issue.record("Opening tasks must not send") })
            let service = OrbiterService(store: OrbiterStore(paths: .init(stateRootOverride: root.appendingPathComponent("state")), hostID: hostID), workflows: workflows, enabled: { true }, forkSource: { throw CancellationError() }, launch: { _ in throw CancellationError() }, locateCreation: { _ in nil })
            await service.refresh()
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 740, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: MacOrbiterTasksView(service: service).environment(AppCoordinator()))
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            hosting.layoutSubtreeIfNeeded()
            for identifier in ["orbiter-title", "orbiter-goal", "orbiter-create-new", "orbiter-create-fork", "orbiter-search"] {
                let control = try #require(find(identifier, in: hosting))
                let selector = NSSelectorFromString("accessibilityFrame")
                let implementation = try #require(control.method(for: selector))
                let frame = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> CGRect).self)(control, selector)
                #expect(frame.width > 0 && frame.height > 0 && window.frame.contains(frame))
            }
            #expect(service.tasks.isEmpty)
        }
    }

    @Test(arguments: [560.0, 640.0])
    func quickPanelKeepsSearchAndDraftWithinItsWindow(width: Double) async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-orbie-quick-ui-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let hostID = UUID()
            let workflows = AgentWorkflowService(store: AgentWorkflowStore(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID), scan: { _ in [] }, schedule: { _ in Issue.record("Showing a quick panel must not submit work") })
            let orbie = OrbieService(store: .init(paths: .init(stateRootOverride: root.appendingPathComponent("state")), hostID: hostID), workflows: workflows, launch: { _ in throw CancellationError() }, locateCreation: { _ in nil })
            await orbie.refresh()
            orbie.draft = "Keep this unsent message"
            let coordinator = AppCoordinator()
            coordinator.orbie = orbie
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: width, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: MacOrbiePanelView().environment(coordinator))
            window.contentView = hosting
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            hosting.layoutSubtreeIfNeeded()
            for identifier in ["orbie-panel-search", "orbie-panel-draft", "orbie-panel-send", "orbie-panel-close"] {
                let control = try #require(find(identifier, in: hosting))
                let selector = NSSelectorFromString("accessibilityFrame")
                let implementation = try #require(control.method(for: selector))
                let frame = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> CGRect).self)(control, selector)
                #expect(frame.width > 0 && frame.height > 0 && window.frame.contains(frame))
            }
            coordinator.orbiePanel.dismiss(restoreFocus: false)
            await orbie.saveDraft()
            #expect(orbie.draft == "Keep this unsent message")
            #expect(try await workflows.snapshot().runs.isEmpty)
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
