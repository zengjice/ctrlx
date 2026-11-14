import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentIdentityArchiveTests {
    private func identity(_ workspace: WorkspacePaneIdentity) throws -> AgentSessionIdentity {
        let pane = PaneState(paneId: "%7", sessionName: "work", currentPath: "/tmp", agentSession: .init(paneId: "%7", pluginID: "codex"), claudeSessionID: UUID().uuidString, workspaceIdentity: workspace)
        return try .init(source: #require(AgentForkSource(pane: pane)), processID: "123", runtimeID: "runtime")
    }

    @Test
    func legacyMigrationInvalidationAndFreshEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-identity-migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("agent-session-identities.json")
        let pane = WorkspacePaneIdentity(serverID: "old", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let original = try identity(pane)
        let oldData = try JSONEncoder().encode(["%7": original])
        try oldData.write(to: file)
        let client = AgentSessionIdentityClient.diskBacked(stateRoot: root)
        // A move changes both placement UUIDs; neither is the recovery identity.
        #expect(try await client.recoverySource([UUID()], UUID(), pane.paneID) == original.source)
        #expect(try Data(contentsOf: file.appendingPathExtension("schema-1.backup")) == oldData)
        await client.invalidate(pane.paneID)
        let restarted = AgentSessionIdentityClient.diskBacked(stateRoot: root)
        #expect(await restarted.isInvalidated(pane.paneID))
        #expect(try await restarted.recoverySource([pane.sessionID], pane.windowID, pane.paneID) == nil)
        let verified = try identity(pane)
        #expect(await restarted.save(verified))
        #expect(await !restarted.isInvalidated(pane.paneID))
        #expect(try await restarted.recoverySource([], UUID(), pane.paneID) == verified.source)
    }

    @Test(arguments: ["corrupt", "future"])
    func invalidArchiveIsPreserved(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-identity-invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("agent-session-identities.json")
        let data = Data((mode == "future" ? #"{"schemaVersion":900,"records":{},"invalidated":[]}"# : "broken").utf8)
        try data.write(to: file)
        let pane = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let client = AgentSessionIdentityClient.diskBacked(stateRoot: root)
        #expect(await client.load("%7") == nil)
        await #expect(throws: (any Error).self) { try await client.recoverySource([], pane.windowID, pane.paneID) }
        #expect(await client.isInvalidated(pane.paneID))
        let record = try identity(pane)
        #expect(await !client.save(record))
        await client.invalidate(pane.paneID)
        #expect(try Data(contentsOf: file) == data)
    }
}
