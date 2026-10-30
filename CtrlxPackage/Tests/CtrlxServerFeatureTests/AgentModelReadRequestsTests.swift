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
        cache.store(snapshot, for: local)
        #expect(cache.entry(for: remote) == nil)
        #expect(cache.entry(for: .init(hostID: "local", pane: identity, pluginID: "claude-code")) == nil)
        cache.store(snapshot, for: remote)
        cache.prune(hostID: "local", identities: [])
        #expect(cache.entry(for: local) == nil)
        #expect(cache.entry(for: remote)?.snapshot == snapshot)
    }

    @Test("Revisiting a tab reuses only the remaining three-second freshness window")
    func recentDisplay() {
        let cache = AgentModelDisplayCache()
        let key = AgentModelDisplayCache.Key(hostID: "local", pane: identity, pluginID: "codex")
        let now = ContinuousClock.now
        #expect(cache.refreshDelay(for: key, now: now) == .milliseconds(300))
        cache.store(snapshot, for: key, now: now)
        #expect(cache.refreshDelay(for: key, now: now) == .seconds(3))
        #expect(cache.refreshDelay(for: key, now: now.advanced(by: .seconds(1))) == .seconds(2))
        #expect(cache.refreshDelay(for: key, now: now.advanced(by: .seconds(4))) == .milliseconds(300))
        // Reuse does not renew freshness; only a successful read does.
        #expect(cache.entry(for: key)?.updatedAt == now)
        let remote = AgentModelDisplayCache.Key(hostID: "remote", pane: identity, pluginID: "codex")
        #expect(cache.refreshDelay(for: remote, now: now) == .milliseconds(300))
        var replacement = identity
        replacement.paneID = UUID()
        #expect(cache.entry(for: .init(hostID: "local", pane: replacement, pluginID: "codex")) == nil)
    }

    @Test("Switching waits for a silent read, then performs its own validation", arguments: [false, true])
    func switchDuringRead(readFails: Bool) async throws {
        let requests = AgentModelReadRequests()
        let gate = ModelReadGate()
        let poll = Task {
            try await requests.read(paneID: "%1", identity: identity, refresh: false) {
                await gate.wait()
                if readFails {
                    throw CocoaError(.fileReadUnknown)
                }
                return snapshot
            }
        }
        await gate.waitUntilStarted()
        var validated = false
        let change = await startedTask {
            try await requests.waitForRead(paneID: "%1", identity: identity)
            validated = true
            return snapshot
        }
        #expect(!validated)
        gate.finish()
        #expect(try await change.value == snapshot)
        #expect(validated)
        _ = await poll.result
    }

    @Test("Cancelled or replaced targets cannot proceed to switch validation")
    func cancelledSwitchWait() async throws {
        let requests = AgentModelReadRequests()
        let gate = ModelReadGate()
        let poll = Task {
            try await requests.read(paneID: "%1", identity: identity, refresh: false) {
                await gate.wait()
                return snapshot
            }
        }
        await gate.waitUntilStarted()
        var replacement = identity
        replacement.paneID = UUID()
        await #expect(throws: (any Error).self) {
            try await requests.waitForRead(paneID: "%1", identity: replacement)
        }
        let change = await startedTask {
            try await requests.waitForRead(paneID: "%1", identity: identity)
            Issue.record("Cancelled switch must not reach write validation")
            return snapshot
        }
        change.cancel()
        gate.finish()
        await #expect(throws: CancellationError.self) { try await change.value }
        #expect(try await poll.value == snapshot)
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
