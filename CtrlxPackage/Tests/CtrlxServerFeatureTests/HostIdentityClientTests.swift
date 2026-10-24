import Foundation
import Testing
@testable import CtrlxServerFeature

struct HostIdentityClientTests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-host-id-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test
    func firstLaunchWithoutRecoveryHasOneDurableIdentity() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = HostIdentityClient.diskBacked(stateRoot: root)
        let ids = try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<20 {
                group.addTask { try await client.load() }
            }
            var ids: Set<UUID> = []
            for try await id in group {
                ids.insert(id)
            }
            return ids
        }
        #expect(ids.count == 1)
        #expect(try ids.contains(await HostIdentityClient.diskBacked(stateRoot: root).load()))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Recovery").path))
    }

    @Test
    func migratesWorkspaceIdentityAndKeepsItAfterRecoveryIsRemoved() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = root.appendingPathComponent("Recovery")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let id = UUID()
        let bytes = try JSONSerialization.data(withJSONObject: ["hostID": id.uuidString, "sessions": []])
        try bytes.write(to: recovery.appendingPathComponent("workspace.json"))
        #expect(try await HostIdentityClient.diskBacked(stateRoot: root).load() == id)
        #expect(try Data(contentsOf: recovery.appendingPathComponent("workspace.json")) == bytes)
        try FileManager.default.removeItem(at: recovery)
        #expect(try await HostIdentityClient.diskBacked(stateRoot: root).load() == id)
    }

    @Test(arguments: ["host-identity.json", "Recovery/workspace.json"])
    func damagedIdentityIsNotReplaced(path: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("broken identity".utf8)
        try bytes.write(to: file)
        await #expect(throws: DecodingError.self) {
            try await HostIdentityClient.diskBacked(stateRoot: root).load()
        }
        #expect(try Data(contentsOf: file) == bytes)
        if path.hasPrefix("Recovery") {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("host-identity.json").path))
        }
    }

    @Test
    func unsupportedRecordDoesNotFallBackToANewIdentity() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("host-identity.json")
        let bytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 99, "hostID": UUID().uuidString])
        try bytes.write(to: file)
        await #expect(throws: HostIdentityError.self) {
            try await HostIdentityClient.diskBacked(stateRoot: root).load()
        }
        #expect(try Data(contentsOf: file) == bytes)
    }
}
