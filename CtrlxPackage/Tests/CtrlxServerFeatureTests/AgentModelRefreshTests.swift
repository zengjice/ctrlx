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
struct AgentModelRefreshTests {
    @Test("Passing through a tab cancels discovery and a hidden strip starts no read")
    func briefVisit() async throws {
        try await withFixture { coordinator, host, reads, render in
            render("%1", true)
            try await Task.sleep(for: .milliseconds(100))
            render("%2", false)
            try await Task.sleep(for: .milliseconds(400))
            #expect(reads.value == 0)
            render("%2", true)
            try await waitForRead(reads)
            #expect(reads.value == 1)
            host.rootView = AnyView(EmptyView())
            #expect(try coordinator.agentModelDisplayCache.entry(for: cacheKey(coordinator, paneID: "%1")) == nil)
        }
    }

    @Test("Returning to cached buttons does not read before the existing freshness deadline")
    func recentVisit() async throws {
        try await withFixture { coordinator, _, reads, render in
            let snapshot = AgentModelSnapshot(runtimeID: "fixture", models: [.init(id: "model", name: "Model", efforts: ["high"], defaultEffort: "high")], selection: .init(model: "model", effort: "high"), unavailableReason: nil)
            try coordinator.agentModelDisplayCache.store(snapshot, for: cacheKey(coordinator, paneID: "%1"), now: .now.advanced(by: .seconds(-1)))
            render("%1", true)
            try await Task.sleep(for: .milliseconds(400))
            #expect(reads.value == 0)
            render("%2", false)
            render("%1", true)
            try await Task.sleep(for: .milliseconds(400))
            #expect(reads.value == 0)
            try await waitForRead(reads)
            #expect(reads.value == 1)
        }
    }

    @Test("Cached rejection does not swallow clicks; switching shows progress and prevents duplicates", arguments: ["model-second", "effort-low"])
    func staleRejection(control: String) async throws {
        let hold = LockIsolated(true)
        defer { hold.setValue(false) }
        try await withFixture(hold: hold) { coordinator, host, reads, render in
            try coordinator.agentModelDisplayCache.store(buttonSnapshot(reason: "Clear the terminal draft first."), for: cacheKey(coordinator, paneID: "%1"))
            render("%1", true)
            let button = try await element(in: host, identifier: "model-shortcut-\(control)")
            #expect(action("isAccessibilityEnabled", on: button))
            let current = try await element(in: host, identifier: "model-shortcut-model-current")
            #expect(!action("isAccessibilityEnabled", on: current))
            #expect(action("accessibilityPerformPress", on: button))
            _ = try await element(in: host, identifier: "model-shortcuts-switching")
            try await waitForRead(reads)
            #expect(!action("isAccessibilityEnabled", on: button))
            _ = action("accessibilityPerformPress", on: button)
            try await Task.sleep(for: .milliseconds(100))
            #expect(reads.value == 1)

            hold.setValue(false)
            try await dismissFailure(in: host)
            let retry = try await element(in: host, identifier: "model-shortcut-\(control)")
            #expect(action("isAccessibilityEnabled", on: retry))
            #expect(action("accessibilityPerformPress", on: retry))
            try await dismissFailure(in: host)
            #expect(reads.value == 2)
        }
    }

    @Test("A failed poll stays nonmodal and does not block a fresh switch request")
    func retryAfterReadFailure() async throws {
        try await withFixture { coordinator, host, reads, render in
            try coordinator.agentModelDisplayCache.store(buttonSnapshot(), for: cacheKey(coordinator, paneID: "%1"), now: .now.advanced(by: .seconds(-4)))
            render("%1", true)
            _ = try await element(in: host, identifier: "model-shortcuts-warning")
            #expect(reads.value == 1)
            #expect(host.window?.sheets.isEmpty == true)
            let button = try await element(in: host, identifier: "model-shortcut-model-second")
            #expect(action("isAccessibilityEnabled", on: button))
            #expect(action("accessibilityPerformPress", on: button))
            try await dismissFailure(in: host)
            #expect(reads.value == 2)
        }
    }

    @Test("A late switch failure does not open an alert in a different tab")
    func leaveDuringSwitch() async throws {
        let hold = LockIsolated(true)
        defer { hold.setValue(false) }
        try await withFixture(hold: hold) { coordinator, host, reads, render in
            for paneID in ["%1", "%2"] {
                try coordinator.agentModelDisplayCache.store(buttonSnapshot(), for: cacheKey(coordinator, paneID: paneID))
            }
            render("%1", true)
            let button = try await element(in: host, identifier: "model-shortcut-model-second")
            #expect(action("accessibilityPerformPress", on: button))
            try await waitForRead(reads)
            render("%2", true)
            _ = try await element(in: host, identifier: "model-shortcut-effort-low")
            hold.setValue(false)
            for _ in 0..<50 where coordinator.agentModelRequests.contains("%1") {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(!coordinator.agentModelRequests.contains("%1"))
            try await Task.sleep(for: .milliseconds(100))
            #expect(host.window?.sheets.isEmpty == true)
            let otherButton = try await element(in: host, identifier: "model-shortcut-model-second")
            #expect(action("isAccessibilityEnabled", on: otherButton))
        }
    }

    private func buttonSnapshot(reason: String? = nil) -> AgentModelSnapshot {
        .init(runtimeID: "fixture", models: [
            .init(id: "current", name: "Current Model", efforts: ["low", "high"], defaultEffort: "high"),
            .init(id: "second", name: "Second Model", efforts: ["low", "high"], defaultEffort: "high"),
        ], selection: .init(model: "current", effort: "high"), unavailableReason: reason)
    }

    private func dismissFailure(in host: NSView) async throws {
        let window = try #require(host.window)
        for _ in 0..<50 where window.sheets.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        let sheet = try #require(window.sheets.first)
        _ = try await element(in: sheet, label: "No supported Agent is running in the selected pane.")
        let okay = try await element(in: sheet, label: "OK")
        let button = try #require((okay as? NSButtonCell)?.controlView as? NSButton)
        button.performClick(nil)
        for _ in 0..<50 where !window.sheets.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(window.sheets.isEmpty)
    }

    private func element(in root: NSObject, identifier: String? = nil, label: String? = nil) async throws -> NSObject {
        for _ in 0..<50 {
            var queue: [Any] = [root]
            while !queue.isEmpty {
                guard let next = queue.removeFirst() as? NSObject else { continue }
                if let identifier, attribute("accessibilityIdentifier", from: next) as? String == identifier {
                    return next
                }
                if let label, ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains(where: { attribute($0, from: next) as? String == label }) {
                    return next
                }
                queue += attribute("accessibilityChildren", from: next) as? [Any] ?? []
                if let view = next as? NSView {
                    queue += view.subviews
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ModelControlTestError.missingControl(identifier ?? label ?? "unknown")
    }

    private func attribute(_ name: String, from node: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue()
    }

    /// SwiftUI accessibility nodes do not declare the full NSAccessibility protocol.
    private func action(_ name: String, on node: NSObject) -> Bool {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector), let implementation = node.method(for: selector) else { return false }
        let call = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        return call(node, selector)
    }

    private func cacheKey(_ coordinator: AppCoordinator, paneID: String) throws -> AgentModelDisplayCache.Key {
        let identity = try #require(coordinator.windowManager.paneStates[paneID]?.workspaceIdentity)
        return .init(hostID: "local", pane: identity, pluginID: "codex")
    }

    private func waitForRead(_ reads: LockIsolated<Int>) async throws {
        for _ in 0..<150 {
            if reads.value > 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Visible model strip never started its read")
    }

    private func withFixture(hold: LockIsolated<Bool> = LockIsolated(false), _ operation: @MainActor (AppCoordinator, NSHostingView<AnyView>, LockIsolated<Int>, @MainActor (String, Bool) -> Void) async throws -> Void) async throws {
        let reads = LockIsolated(0)
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            $0[ProcessRunner.self].run = { executable, arguments, _, _ in
                #expect(arguments.contains("list-panes"))
                #expect(executable != "/bin/ps")
                reads.withValue { $0 += 1 }
                while hold.value {
                    try await Task.sleep(for: .milliseconds(20))
                }
                // No Agent found: this read must fail without starting a real CLI.
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        } operation: {
            _ = NSApplication.shared
            NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let coordinator = AppCoordinator()
            coordinator.pluginRegistry = PluginRegistry()
            coordinator.windowManager.setPaneStatesForPreview(["%1", "%2"].map { paneID in
                PaneState(paneId: paneID, agentSession: .init(paneId: paneID, pluginID: "codex"), workspaceIdentity: .init(serverID: "fixture", sessionID: UUID(), windowID: UUID(), paneID: UUID()))
            })
            let host = NSHostingView(rootView: AnyView(EmptyView()))
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            NSApplication.shared.setActivationPolicy(.accessory)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            defer {
                host.rootView = AnyView(EmptyView())
                window.close()
            }
            let render: @MainActor (String, Bool) -> Void = { paneID, visible in
                host.rootView = AnyView(AgentModelStatusBar(hostID: nil, paneID: paneID, isVisible: visible)
                    .id(paneID)
                    .environment(coordinator)
                    .environment(coordinator.windowManager)
                    .environment(coordinator.settings))
                host.layoutSubtreeIfNeeded()
            }
            try await operation(coordinator, host, reads, render)
        }
    }
}

private enum ModelControlTestError: Error {
    case missingControl(String)
}
