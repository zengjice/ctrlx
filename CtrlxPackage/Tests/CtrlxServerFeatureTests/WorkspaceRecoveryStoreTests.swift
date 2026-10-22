import CtrlxCommon
import Foundation
import Testing
@testable import CtrlxServerFeature

struct WorkspaceRecoveryStoreTests {
    static func snapshot() -> WorkspaceRecoverySnapshot {
        let pane = WorkspaceRecoveryPane(id: UUID(), runtimeID: "%1", directory: "/tmp")
        let window = WorkspaceRecoveryWindow(
            id: UUID(), runtimeID: "@1", index: 0, name: "terminal", selectedPaneID: pane.id,
            layout: .pane(pane.id, width: 120, height: 40), panes: [pane]
        )
        let session = WorkspaceRecoverySession(id: UUID(), runtimeID: "$1", name: "project", selectedWindowID: window.id, windows: [window])
        return WorkspaceRecoverySnapshot(hostID: UUID(), bootID: "boot-a", serverID: "server-a", sessions: [session])
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-recovery-store-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Snapshots survive restart and keep the preceding complete generation")
    func backupAndDeduplication() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkspaceRecoveryStore.diskBacked(directory: dir)
        let first = try await store.save(Self.snapshot())
        var unchanged = first
        unchanged.savedAt = .distantFuture
        unchanged.generation = 999
        #expect(try await store.save(unchanged) == first)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("workspace.previous.json").path))
        var changed = first
        changed.sessions[0].name = "renamed"
        let second = try await store.save(changed)
        #expect(second.generation == first.generation + 1)
        let backup = try JSONDecoder().decode(WorkspaceRecoverySnapshot.self, from: Data(contentsOf: dir.appendingPathComponent("workspace.previous.json")))
        #expect(backup == first)
        #expect(try await WorkspaceRecoveryStore.diskBacked(directory: dir).load() == second)
    }

    @Test("Corrupt and unsupported snapshots block replacement and preserve both files", arguments: [false, true])
    func invalidDiskState(unknownVersion: Bool) async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var snapshot = Self.snapshot()
        snapshot.schemaVersion = 999
        let invalid = try unknownVersion ? JSONEncoder().encode(snapshot) : Data("broken".utf8)
        let file = dir.appendingPathComponent("workspace.json")
        let backup = dir.appendingPathComponent("workspace.previous.json")
        try invalid.write(to: file)
        try Data("last complete snapshot".utf8).write(to: backup)
        let store = WorkspaceRecoveryStore.diskBacked(directory: dir)
        await #expect(throws: (any Error).self) { try await store.load() }
        await #expect(throws: (any Error).self) { try await store.save(Self.snapshot()) }
        #expect(try Data(contentsOf: file) == invalid)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "last complete snapshot")
    }

    @Test("A failed write leaves the previous in-memory and disk generation usable")
    func failedWrite() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkspaceRecoveryStore.diskBacked(directory: dir)
        let saved = try await store.save(Self.snapshot())
        let backup = dir.appendingPathComponent("workspace.previous.json")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        var next = saved
        next.sessions[0].name = "new name"
        await #expect(throws: (any Error).self) { try await store.save(next) }
        #expect(try await store.load() == saved)
        #expect(try await WorkspaceRecoveryStore.diskBacked(directory: dir).load() == saved)
    }

    @Test("Malformed identities and layouts cannot replace a valid snapshot")
    func invalidModel() async throws {
        let original = Self.snapshot()
        let store = WorkspaceRecoveryStore.inMemory(original)
        var duplicate = original
        duplicate.sessions.append(original.sessions[0])
        await #expect(throws: WorkspaceRecoveryError.self) { try await store.save(duplicate) }
        var mismatch = original
        mismatch.sessions[0].windows[0].layout = .pane(UUID(), width: 120, height: 40)
        await #expect(throws: WorkspaceRecoveryError.self) { try await store.save(mismatch) }
        #expect(try await store.load() == original)
    }

    @Test("Shared window links allow different indices but reject conflicting contents and pane ownership")
    func sharedWindowValidation() async throws {
        var snapshot = Self.snapshot()
        var linked = snapshot.sessions[0]
        linked.id = UUID()
        linked.runtimeID = "$2"
        linked.name = "linked"
        linked.windows[0].index = 7
        snapshot.sessions.append(linked)
        let store = WorkspaceRecoveryStore.inMemory()
        let saved = try await store.save(snapshot)
        #expect(try await store.load() == saved)
        var conflicting = snapshot
        conflicting.sessions[1].windows[0].panes[0].unavailableAgentReason = "Different Agent description"
        await #expect(throws: WorkspaceRecoveryError.self) { try await store.save(conflicting) }
        conflicting = snapshot
        conflicting.sessions[1].windows[0].runtimeID = "@99"
        await #expect(throws: WorkspaceRecoveryError.self) { try await store.save(conflicting) }
        conflicting = snapshot
        conflicting.sessions[1].windows[0].id = UUID()
        conflicting.sessions[1].selectedWindowID = conflicting.sessions[1].windows[0].id
        await #expect(throws: WorkspaceRecoveryError.self) { try await store.save(conflicting) }
        #expect(try await store.load() == saved)
    }

    @Test("Nested tmux layouts remap every leaf identity and preserve split geometry")
    func remapLayout() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let layout = WorkspaceRecoveryLayout.horizontal([
            .pane(a, width: 59, height: 40),
            .vertical([.pane(b, width: 60, height: 19), .pane(c, width: 60, height: 20)], width: 60, height: 40),
        ], width: 120, height: 40)
        #expect(layout.isValid)
        let removed = try #require(layout.removing([a, b]))
        #expect(removed == .pane(c, width: 120, height: 40))
        #expect(layout.removing([b])?.isValid == true)
        #expect(layout.removing([a, b, c]) == nil)
        let encoded = try layout.tmuxLayout(panes: [a: "%41", b: "%2", c: "%999"])
        let parsed = try #require(TmuxLayoutParser.parse(encoded))
        #expect(try WorkspaceRecoveryLayout(parsed, identities: ["%41": a, "%2": b, "%999": c]) == layout)
        #expect(throws: WorkspaceRecoveryError.self) { try layout.tmuxLayout(panes: [a: "%41"]) }
        #expect(throws: WorkspaceRecoveryError.self) { try WorkspaceRecoveryLayout(parsed, identities: ["%41": a]) }
    }
}
