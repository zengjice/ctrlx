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
            let orbie = try OrbieService(store: store, interaction: await AgentInteractionTestSupport.readOnly(root: root, hostID: hostID, workflows: workflows), launch: { _ in throw CancellationError() }, locateCreation: { _ in nil })
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
            #expect(orbie.isRefreshing && !orbie.isBusy)
            let button = try #require(find("orbie-open-agent", in: hosting))
            #expect(find("Open Orbie Tab", in: hosting) != nil)
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
            coordinator.agentRuntimeCatalog = AgentRuntimeCatalog(hostID: hostID) { _ in throw AgentWorkflowError("No scan needed") }
            let creation = try await coordinator.workflowAgentCreation(hostID: hostID)
            #expect(creation.hostID == hostID)
            await #expect(throws: AgentWorkflowError.self) { try await coordinator.workflowAgentCreation(hostID: UUID()) }
            coordinator.agentWorkflowService = nil
            coordinator.agentRuntimeCatalog = nil
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
            let orbie = try OrbieService(store: store, interaction: await AgentInteractionTestSupport.readOnly(root: root, hostID: hostID, workflows: workflows), launch: { _ in throw CancellationError() }, locateCreation: { _ in nil })
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

    @Test(arguments: [MacOrbitersView.CreationSource.newConversation, .fork, .existingConversation])
    func orbiterFormShowsOneActionForItsSourceDuringInspection(source: MacOrbitersView.CreationSource) async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            _ = NSApplication.shared
            let f = try await AgentInteractionTestSupport()
            let pane = try f.create(UUID(), pluginID: "codex", title: "Existing conversation", directory: f.root.path)
            let service = await f.orbiters()
            let existing = try #require(service.instances.first { $0.workspacePane == pane })
            if source == .fork {
                _ = try await service.associate(existing)
            }
            service.draft = .init(title: "Review", goal: "Review this project", directory: f.root.path)
            let registry = PluginRegistry()
            await registry.enable("codex", host: MockPluginHost(), env: .init(
                pluginRoot: f.root, stateDir: f.root, appVersion: "test",
                settings: Data(#"{"export_telemetry":false}"#.utf8), marketplaceSource: f.root
            ))
            let coordinator = AppCoordinator()
            coordinator.pluginRegistry = registry
            let gate = ScanGate()
            f.beforeScan = { await gate.wait() }
            let refreshing = Task { await service.refresh() }
            defer { Task { await gate.release()
                await refreshing.value
            } }
            for _ in 0..<100 {
                if await gate.started {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(await gate.started)
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 740, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: MacOrbitersView(
                service: service, initialSource: source, requestedForkSource: source == .fork ? existing : nil
            ).environment(coordinator))
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            hosting.layoutSubtreeIfNeeded()
            let addingExisting = source == .existingConversation
            let actionID = addingExisting ? "orbiter-associate" : "orbiter-create"
            let draftFields = ["orbiter-title", "orbiter-goal", "orbiter-directory"]
            let sourceFields = addingExisting ? ["orbiter-conversation"] : draftFields
            for identifier in ["orbiter-source", "orbiter-search", actionID] + sourceFields {
                let control = try #require(find(identifier, in: hosting))
                let selector = NSSelectorFromString("accessibilityFrame")
                let implementation = try #require(control.method(for: selector))
                let frame = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> CGRect).self)(control, selector)
                #expect(frame.width > 0 && frame.height > 0 && window.frame.contains(frame), Comment(rawValue: "\(identifier): \(frame), window: \(window.frame)"))
            }
            #expect(find("orbiter-new-draft", in: hosting) == nil)
            #expect(find(addingExisting ? "orbiter-create" : "orbiter-associate", in: hosting) == nil)
            #expect(!service.isBusy)
            let button = try #require(find(actionID, in: hosting))
            let enabledSelector = NSSelectorFromString("isAccessibilityEnabled")
            let enabled = try #require(button.method(for: enabledSelector))
            #expect(unsafeBitCast(enabled, to: (@convention(c) (AnyObject, Selector) -> Bool).self)(button, enabledSelector) == !addingExisting)
            if addingExisting {
                for identifier in draftFields {
                    #expect(find(identifier, in: hosting) == nil)
                }
            } else {
                let pressSelector = NSSelectorFromString("accessibilityPerformPress")
                let press = try #require(button.method(for: pressSelector))
                #expect(unsafeBitCast(press, to: (@convention(c) (AnyObject, Selector) -> Bool).self)(button, pressSelector))
            }
            #expect(f.launches.count == 1 && f.writes.isEmpty)
            await gate.release()
            await refreshing.value
            if !addingExisting {
                for _ in 0..<100 {
                    if service.agents.contains(where: { $0.creation?.title == "Review" && $0.agentID != nil }) && !service.isBusy {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let created = try #require(service.agents.first { $0.creation?.title == "Review" })
                #expect(created.creation?.forkSource == (source == .fork ? existing : nil))
                #expect(created.creation?.directory == f.root.path)
                #expect(service.drafts[created.id] == "Review this project")
                #expect(f.launches.count == 2 && f.writes.isEmpty)
                try await Task.sleep(for: .milliseconds(100))
                hosting.layoutSubtreeIfNeeded()
                #expect(find("Open Orbiter Tab", in: hosting) != nil)
            } else {
                #expect(service.agents.isEmpty && service.draft.goal == "Review this project")
            }
            window.contentView = nil
            await registry.disable("codex")
            try await f.cleanup()
        }
    }

    @Test(arguments: [560.0, 640.0])
    func quickPanelKeepsDraftAndPrimaryActionsWithinItsWindow(width: Double) async throws {
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
            let orbie = try OrbieService(store: .init(paths: .init(stateRootOverride: root.appendingPathComponent("state")), hostID: hostID), interaction: await AgentInteractionTestSupport.readOnly(root: root, hostID: hostID, workflows: workflows), launch: { _ in throw CancellationError() }, locateCreation: { _ in nil })
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
            for identifier in ["orbie-panel-switcher", "orbie-panel-actions", "orbie-panel-draft", "orbie-panel-send", "orbie-panel-close"] {
                let control = try #require(find(identifier, in: hosting))
                let selector = NSSelectorFromString("accessibilityFrame")
                let implementation = try #require(control.method(for: selector))
                let frame = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> CGRect).self)(control, selector)
                #expect(frame.width > 0 && frame.height > 0 && window.frame.contains(frame), Comment(rawValue: "\(identifier): \(frame), window: \(window.frame)"))
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
