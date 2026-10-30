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

    private func withFixture(_ operation: @MainActor (AppCoordinator, NSHostingView<AnyView>, LockIsolated<Int>, @MainActor (String, Bool) -> Void) async throws -> Void) async throws {
        let reads = LockIsolated(0)
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            $0[ProcessRunner.self].run = { executable, arguments, _, _ in
                #expect(arguments.contains("list-panes"))
                #expect(executable != "/bin/ps")
                reads.withValue { $0 += 1 }
                // No Agent found: this read must fail without starting a real CLI.
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        } operation: {
            _ = NSApplication.shared
            let coordinator = AppCoordinator()
            coordinator.pluginRegistry = PluginRegistry()
            coordinator.windowManager.setPaneStatesForPreview(["%1", "%2"].map { paneID in
                PaneState(paneId: paneID, agentSession: .init(paneId: paneID, pluginID: "codex"), workspaceIdentity: .init(serverID: "fixture", sessionID: UUID(), windowID: UUID(), paneID: UUID()))
            })
            let host = NSHostingView(rootView: AnyView(EmptyView()))
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 50), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
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
