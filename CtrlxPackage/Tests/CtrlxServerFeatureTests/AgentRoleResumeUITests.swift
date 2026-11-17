import AppKit
import ConcurrencyExtras
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite(.serialized)
struct AgentRoleResumeUITests {
    @Test(arguments: [false, true], [false, true])
    func stoppedAgentHasVisibleRecovery(tabClosed: Bool, compact: Bool) async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let f = try await AgentInteractionTestSupport()
            let original = await f.orbie()
            try await original.create(pluginID: "codex", providerID: nil)
            let binding = try #require(original.instance)
            if tabClosed {
                var message = AgentMessage(instance: binding, text: "Unconfirmed old message")
                message.status = .uncertain
                try await f.interaction.store.insert(message)
                let store = OrbieStore(paths: f.paths, hostID: f.hostID)
                var record = try await store.load()
                record.messageIDs.append(message.id)
                try await store.save(record)
            }
            f.observations = []
            let ready = LockIsolated(!tabClosed)
            let recovery = AgentRoleRecovery(file: f.root.appendingPathComponent("resume.json"), paneExists: { _ in !tabClosed }, launch: { token, descriptor in
                try await MainActor.run {
                    let pane = try f.create(token, pluginID: descriptor.pluginID, title: "Restored", directory: descriptor.projectPath)
                    f.observations[0].conversationID = descriptor.sessionID
                    return pane
                }
            }, locate: { await f.launches[$0] }, inspect: { pane, _ in
                guard ready.value else { return nil }
                return try await f.catalog.snapshot(refresh: true).first { $0.workspacePane.isSamePane(as: pane) }
            })
            try await recovery.capture(binding.agentID, descriptor: .init(pluginID: binding.pluginID, sessionID: binding.conversationID, projectPath: f.root.path, configurationRoot: f.root.path, usesDefaultConfiguration: true), invalidated: false)
            let orbie = OrbieService(store: .init(paths: f.paths, hostID: f.hostID), interaction: f.interaction, recovery: recovery, launch: { _ in throw CancellationError() }, locateCreation: { _ in nil })
            await orbie.refresh()
            orbie.draft = "Keep this draft"
            #expect(orbie.canRestore && orbie.tabClosed == tabClosed)
            let coordinator = AppCoordinator()
            coordinator.orbie = orbie
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 640, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = compact ? AnyView(MacOrbiePanelView()) : AnyView(MacOrbieView())
            let hosting = NSHostingView(rootView: content.environment(coordinator))
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(250))
            hosting.layoutSubtreeIfNeeded()
            let label = tabClosed ? "Restore Original Conversation" : "Resume Original Conversation"
            let button = try #require(find(label, in: hosting))
            let selector = NSSelectorFromString("accessibilityFrame")
            let implementation = try #require(button.method(for: selector))
            let frame = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> CGRect).self)(button, selector)
            #expect(frame.width > 0 && frame.height > 0 && window.frame.contains(frame))
            #expect(f.launches.count == 1 && f.writes.isEmpty)
            if tabClosed {
                let press = NSSelectorFromString("accessibilityPerformPress")
                let perform = try #require(button.method(for: press))
                #expect(unsafeBitCast(perform, to: (@convention(c) (AnyObject, Selector) -> Bool).self)(button, press))
                for _ in 0..<100 where !orbie.isRestoring {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(orbie.isRestoring && orbie.issue == nil)
                #expect(orbie.hasPendingMessage)
                try await Task.sleep(for: .milliseconds(100))
                hosting.layoutSubtreeIfNeeded()
                #expect(find("Restoring the original conversation…", in: hosting) != nil)
                #expect(find(label, in: hosting) == nil)
                ready.setValue(true)
                if compact {
                    await orbie.refresh()
                } else {
                    // The full conversation's own timer must keep inspecting,
                    // even with an unconfirmed message for the old AgentID.
                    for _ in 0..<80 where orbie.instance == nil {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                #expect(orbie.instance?.conversationID == binding.conversationID)
                #expect(orbie.record?.target?.agentID != binding.agentID)
                #expect(!orbie.canRestore && f.launches.count == 2)
            }
            #expect(orbie.draft == "Keep this draft" && f.writes.isEmpty)
            window.contentView = nil
            coordinator.orbie = nil
            try await f.cleanup()
        }
    }

    private func find(_ label: String, in node: NSObject) -> NSObject? {
        for attribute in ["accessibilityLabel", "accessibilityValue"] {
            let name = NSSelectorFromString(attribute)
            if node.responds(to: name), node.perform(name)?.takeUnretainedValue() as? String == label {
                return node
            }
        }
        let children = NSSelectorFromString("accessibilityChildren")
        if node.responds(to: children) {
            for child in node.perform(children)?.takeUnretainedValue() as? [NSObject] ?? [] {
                if let match = find(label, in: child) {
                    return match
                }
            }
        }
        return nil
    }
}
