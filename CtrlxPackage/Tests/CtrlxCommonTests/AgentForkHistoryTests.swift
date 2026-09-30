import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

struct AgentForkHistoryTests {
    @Test("History lookup selects the exact conversation's config root for both Agents")
    func exactHistory() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-fork-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let id = UUID().uuidString.lowercased()
        let codex = fixture.appendingPathComponent("custom codex")
        let claude = fixture.appendingPathComponent("custom claude")
        for file in [codex.appendingPathComponent("sessions/2026/09/rollout-date-\(id).jsonl"), claude.appendingPathComponent("projects/-repo/\(id).jsonl")] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let client = AgentForkHistoryClient.liveValue
        #expect(try await client.root(id, [fixture.path, codex.path], .codex) == codex.resolvingSymlinksInPath().path)
        #expect(try await client.root(id, [fixture.path, claude.path], .claude) == claude.resolvingSymlinksInPath().path)
        await #expect(throws: AgentForkError.self) { try await client.root(UUID().uuidString, [codex.path], .codex) }
        await #expect(throws: AgentForkError.self) { try await client.root("--last", [codex.path], .codex) }
        let duplicate = fixture.appendingPathComponent("other/projects/-repo/\(id).jsonl")
        try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: duplicate)
        await #expect(throws: AgentForkError.self) { try await client.root(id, [claude.path, fixture.appendingPathComponent("other").path], .claude) }
        // The same root listed twice is not a second conversation.
        #expect(try await client.root(id, [claude.path, claude.path], .claude) == claude.resolvingSymlinksInPath().path)
    }

    @MainActor
    @Test("Viewer Fork capability is explicit and cleared on downgrade/disconnect")
    func viewerCapability() {
        let store = SessionStore()
        store.handleStateUpdate(SessionStateMessage(pairId: "host", paneStates: [:], supportsAgentFork: true))
        #expect(store.hostsSupportingAgentFork.contains("host"))
        store.handleStateUpdate(SessionStateMessage(pairId: "host", paneStates: [:]))
        #expect(!store.hostsSupportingAgentFork.contains("host"))
        store.handleStateUpdate(SessionStateMessage(pairId: "host", paneStates: [:], supportsAgentFork: true))
        store.clearSessions(for: "host")
        #expect(!store.hostsSupportingAgentFork.contains("host"))
    }
}
