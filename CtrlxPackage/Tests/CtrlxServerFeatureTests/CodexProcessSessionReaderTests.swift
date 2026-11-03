import Darwin
import Foundation
import Testing
@testable import CtrlxServerFeature

/// FD probes inspect every rollout writer in this test process.
@Suite(.serialized)
struct CodexProcessSessionReaderTests {
    private let childID = "01a12863-79a4-7ef0-a50a-2493f7262468"
    private let parentID = "01a10b9d-5efd-72e1-850f-6b6374f064bd"

    private func header(_ id: String, source: String = "cli", type: String = "session_meta") -> Data {
        Data("{\"type\":\"\(type)\",\"payload\":{\"id\":\"\(id)\",\"forked_from_id\":\"\(parentID)\",\"source\":\"\(source)\"}}".utf8)
    }

    @Test(
        "Only matching CLI session metadata identifies a rollout; forked_from_id is never the active ID",
        arguments: ["child", "parent-mismatch", "subagent", "event", "incomplete", "oversized", "wrong-name"]
    )
    func metadata(scenario: String) {
        var data = header(childID)
        var path = "/custom-codex/sessions/rollout-2026-10-11T08-36-10-\(childID).jsonl"
        switch scenario {
        case "parent-mismatch": data = header(parentID)
        case "subagent": data = header(childID, source: "exec")
        case "event": data = header(childID, type: "event_msg")
        case "incomplete": data = Data("{\"type\":\"session_meta\"".utf8)
        case "oversized": data.append(Data(repeating: 32, count: CodexProcessSessionReader.headerLimit))
        case "wrong-name": path = "/tmp/\(childID).jsonl"
        default: break
        }
        #expect(CodexProcessSessionReader.sessionID(header: data, path: path) == (scenario == "child" ? childID : nil))
    }

    @Test("The active writer changes independently of Codex process identity")
    func currentWriterChangesWithoutReplacingItsProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-writer-switch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldID = UUID().uuidString, newID = UUID().uuidString
        func rollout(_ id: String) throws -> URL {
            let file = root.appendingPathComponent("rollout-2026-11-03-\(id).jsonl")
            let header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id, "source": "cli"]])
            try (header + Data("\n".utf8)).write(to: file)
            return file
        }
        let oldFile = try rollout(oldID), newFile = try rollout(newID)
        var writer: FileHandle? = try FileHandle(forWritingTo: oldFile)
        defer { try? writer?.close() }
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let runtime = try #require(AgentSessionIdentityClient.processRuntimeID(pid))
        let reader = CodexProcessSessionReader()
        #expect(await reader.sessionID(processID: pid, runtimeID: runtime) == oldID)
        try writer?.close()
        writer = nil
        #expect(await reader.sessionID(processID: pid, runtimeID: runtime) == nil)
        writer = try FileHandle(forWritingTo: newFile)
        #expect(await reader.sessionID(processID: pid, runtimeID: runtime) == newID)
        #expect(AgentSessionIdentityClient.processRuntimeID(pid) == runtime)
    }

    @Test("Native FD recovery ignores read-only parent history, rejects ambiguous writers and verifies process lifetime")
    func openWriter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-codex-writer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = directory.appendingPathComponent("rollout-2026-10-11T08-36-10-\(childID).jsonl")
        let parent = directory.appendingPathComponent("rollout-2026-10-10T08-36-10-\(parentID).jsonl")
        try (header(childID) + Data("\nignored transcript".utf8)).write(to: child)
        try (header(parentID) + Data("\n".utf8)).write(to: parent)
        let parentReader = try FileHandle(forReadingFrom: parent)
        defer { try? parentReader.close() }
        let writer = try FileHandle(forWritingTo: child)
        defer { try? writer.close() }
        let reader = CodexProcessSessionReader()
        let pid = String(getpid())
        let runtime = try #require(AgentSessionIdentityClient.processRuntimeID(pid))
        #expect(await reader.sessionID(processID: pid, runtimeID: runtime) == childID)
        #expect(await reader.ownsSession(processID: pid, runtimeID: runtime, conversationID: childID))
        #expect(await !reader.ownsSession(processID: pid, runtimeID: runtime, conversationID: parentID))
        #expect(await !reader.ownsSession(processID: pid, runtimeID: "reused-pid", conversationID: childID))
        #expect(await reader.sessionID(processID: pid, runtimeID: "reused-pid") == nil)
        #expect(await reader.sessionID(processID: "-1", runtimeID: runtime) == nil)

        let duplicate = try FileHandle(forWritingTo: child)
        #expect(await reader.sessionID(processID: pid, runtimeID: runtime) == childID)
        try duplicate.close()
        let otherWriter = try FileHandle(forWritingTo: parent)
        #expect(await reader.sessionID(processID: pid, runtimeID: runtime) == nil)
        #expect(await reader.ownsSession(processID: pid, runtimeID: runtime, conversationID: childID))
        #expect(await reader.ownsSession(processID: pid, runtimeID: runtime, conversationID: parentID))
        try otherWriter.close()
        #expect(await !reader.ownsSession(processID: pid, runtimeID: runtime, conversationID: parentID))

        // No newline means the writer has not finished its metadata record.
        try writer.truncate(atOffset: 0)
        try writer.seek(toOffset: 0)
        try writer.write(contentsOf: header(childID))
        #expect(await reader.sessionID(processID: pid, runtimeID: runtime) == nil)
        #expect(await !reader.ownsSession(processID: pid, runtimeID: runtime, conversationID: childID))
        try writer.write(contentsOf: Data("\n".utf8))
        #expect(await reader.sessionID(processID: pid, runtimeID: runtime) == childID)
        try writer.truncate(atOffset: 0)
        try writer.seek(toOffset: 0)
        try writer.write(contentsOf: header(childID, source: "exec") + Data("\n".utf8))
        #expect(await !reader.ownsSession(processID: pid, runtimeID: runtime, conversationID: childID))
        try writer.truncate(atOffset: 0)
        try writer.seek(toOffset: 0)
        try writer.write(contentsOf: Data(repeating: 32, count: CodexProcessSessionReader.headerLimit + 1) + Data("\n".utf8))
        #expect(await reader.sessionID(processID: pid, runtimeID: runtime) == nil)
    }
}
