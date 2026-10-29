import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentModelReadRequestsTests {
    private let identity = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
    private let snapshot = AgentModelSnapshot(runtimeID: "pid:start", models: [.init(id: "model", name: "Model", efforts: ["high"], defaultEffort: "high")], selection: .init(model: "model", effort: "high"), unavailableReason: nil)

    @Test("Host and Viewer reads share work; cancelling one reader preserves the others")
    func sharedRead() async throws {
        let requests = AgentModelReadRequests()
        let gate = ModelReadGate()
        var calls = 0
        let first = Task {
            try await requests.read(paneID: "%1", identity: identity, refresh: false) {
                calls += 1
                await gate.wait()
                return snapshot
            }
        }
        await gate.waitUntilStarted()
        let linkedIdentity = WorkspacePaneIdentity(serverID: identity.serverID, sessionID: UUID(), windowID: UUID(), paneID: identity.paneID)
        let second = await startedTask {
            try await requests.read(paneID: "%1", identity: linkedIdentity, refresh: false) {
                calls += 1
                return snapshot
            }
        }
        first.cancel()
        gate.finish()
        #expect(try await second.value == snapshot)
        do { _ = try await first.value
            Issue.record("Cancelled caller should not publish its result")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(calls == 1)
    }

    @Test("Explicit refresh runs after an ordinary in-flight read, even when that read fails")
    func forcedRead() async throws {
        let requests = AgentModelReadRequests()
        let gate = ModelReadGate()
        let first = Task {
            try await requests.read(paneID: "%1", identity: identity, refresh: false) {
                await gate.wait()
                throw CocoaError(.fileReadUnknown)
            }
        }
        await gate.waitUntilStarted()
        var refreshed = false
        let second = await startedTask {
            try await requests.read(paneID: "%1", identity: identity, refresh: true) {
                refreshed = true
                return snapshot
            }
        }
        #expect(!refreshed)
        gate.finish()
        #expect(try await second.value == snapshot)
        #expect(refreshed)
        _ = await first.result
    }

    @Test("A replacement pane cannot borrow an in-flight snapshot")
    func identityScope() async throws {
        let requests = AgentModelReadRequests()
        let gate = ModelReadGate()
        let first = Task {
            try await requests.read(paneID: "%1", identity: identity, refresh: false) {
                await gate.wait()
                return snapshot
            }
        }
        await gate.waitUntilStarted()
        var replacement = identity
        replacement.paneID = UUID()
        await #expect(throws: (any Error).self) {
            try await requests.read(paneID: "%1", identity: replacement, refresh: false) {
                Issue.record("A different identity must be rejected")
                return snapshot
            }
        }
        gate.finish()
        _ = try await first.value
    }

    @Test("Display cache isolates Hosts, panes and plugins, and prunes closed panes")
    func displayCache() {
        let cache = AgentModelDisplayCache()
        let local = AgentModelDisplayCache.Key(hostID: "local", pane: identity, pluginID: "codex")
        let remote = AgentModelDisplayCache.Key(hostID: "remote", pane: identity, pluginID: "codex")
        cache.snapshots[local] = snapshot
        #expect(cache.snapshots[remote] == nil)
        #expect(cache.snapshots[.init(hostID: "local", pane: identity, pluginID: "claude-code")] == nil)
        cache.snapshots[remote] = snapshot
        cache.prune(hostID: "local", identities: [])
        #expect(cache.snapshots[local] == nil)
        #expect(cache.snapshots[remote] == snapshot)
    }

    private func startedTask(_ operation: @escaping @MainActor () async throws -> AgentModelSnapshot) async -> Task<AgentModelSnapshot, Error> {
        var task: Task<AgentModelSnapshot, Error>?
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            task = Task {
                started.resume()
                return try await operation()
            }
        }
        // Assigned synchronously before the task can resume the continuation.
        return task!
    }
}

@MainActor
final private class ModelReadGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation {
            waiter = $0
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if waiter != nil {
            return
        }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        waiter?.resume()
        waiter = nil
    }
}
