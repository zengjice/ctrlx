import CryptoKit
import Foundation
import Testing
@testable import CtrlxCLI

struct WorkflowArtifactUploadTests {
    final private class Receiver {
        var requests: [JSONRPCRequest] = []
        var bytes = Data()
        var name: JSONValue?
        var type: JSONValue?

        func receive(_ request: JSONRPCRequest) throws -> JSONRPCResponse {
            requests.append(request)
            let action = try #require(request.params["action"]?.stringValue)
            var result: [String: JSONValue] = try [
                "invocationId": #require(request.params["invocationId"]),
                "uploadId": #require(request.params["uploadId"]),
            ]
            switch action {
            case "begin":
                name = request.params["name"]
                type = request.params["mediaType"]
                result["offset"] = .int(0)
            case "append":
                #expect(request.params["offset"] == .int(bytes.count))
                let chunk = try #require(request.params["data"]?.stringValue.flatMap { Data(base64Encoded: $0) })
                #expect(chunk.count <= 64 * 1_024)
                bytes.append(chunk)
                result["offset"] = .int(bytes.count)
            case "finish":
                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                #expect(request.params["sha256"] == .string(hash))
                result["offset"] = .int(bytes.count)
                result["artifact"] = try .object([
                    "id": #require(request.params["uploadId"]), "name": #require(name),
                    "mediaType": #require(type), "size": .int(bytes.count), "sha256": .string(hash),
                ])
            case "cancel": result["offset"] = .int(0)
            default: Issue.record("Unexpected upload action")
            }
            return .init(id: request.id, result: result)
        }
    }

    private func file(_ contents: Data) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-artifact-cli-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("Review.md")
        try contents.write(to: path)
        return path
    }

    @Test
    func largeUnicodeFileUsesExactChunksAndOneFinalReceipt() throws {
        let bytes = Data(String(repeating: "完整答复\n", count: 15_000).utf8)
        let source = try file(bytes)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let receiver = Receiver()
        let response = try WorkflowArtifactUpload.send(file: source, invocationID: UUID(), request: receiver.receive)
        #expect(response.ok)
        #expect(receiver.bytes == bytes)
        #expect(receiver.requests.first?.params["action"] == .string("begin"))
        #expect(receiver.requests.last?.params["action"] == .string("finish"))
        #expect(receiver.requests.allSatisfy { $0.params["path"] == nil && $0.params["pane"] == nil })
        #expect(Set(receiver.requests.compactMap { $0.params["uploadId"]?.stringValue }).count == 1)
        #expect(Set(receiver.requests.map(\.id)).count == receiver.requests.count)
    }

    @Test(arguments: ["replace", "rewrite", "offset", "disconnect", "finishReply"])
    func failuresCancelWithoutRetryingTheTask(_ condition: String) throws {
        let bytes = Data(repeating: 0x61, count: 70_000)
        let source = try file(bytes)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let receiver = Receiver()
        #expect(throws: WorkflowArtifactUpload.Failure.self) {
            try WorkflowArtifactUpload.send(file: source, invocationID: UUID()) { command in
                let response = try receiver.receive(command)
                if command.params["action"] == .string("append"), receiver.bytes.count <= 64 * 1_024 {
                    switch condition {
                    case "replace": try Data(repeating: 0x62, count: bytes.count).write(to: source, options: .atomic)
                    case "rewrite":
                        let handle = try FileHandle(forWritingTo: source)
                        try handle.write(contentsOf: Data([0x62]))
                        try handle.close()
                    case "disconnect": throw CLIError.responseTimeout
                    case "offset":
                        var result = try #require(response.result)
                        result["offset"] = .int(0)
                        return .init(id: response.id, result: result)
                    default: break
                    }
                }
                if condition == "finishReply", command.params["action"] == .string("finish") {
                    throw CLIError.responseTimeout
                }
                return response
            }
        }
        #expect(receiver.requests.last?.params["action"] == .string("cancel"))
        #expect(receiver.requests.filter { $0.params["action"] == .string("begin") }.count == 1)
        #expect(receiver.requests.filter { $0.params["action"] == .string("finish") }.count == (condition == "finishReply" ? 1 : 0))
    }

    @Test(arguments: ["empty", "directory", "symlink", "unsupported"])
    func invalidSourceDoesNotContactTheHost(_ condition: String) throws {
        let source = try file(condition == "empty" ? Data() : Data("artifact".utf8))
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        var chosen = source
        if condition == "directory" {
            try FileManager.default.removeItem(at: source)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        }
        if condition == "symlink" {
            chosen = source.deletingLastPathComponent().appendingPathComponent("link.md")
            try FileManager.default.createSymbolicLink(at: chosen, withDestinationURL: source)
        }
        if condition == "unsupported" {
            chosen = source.appendingPathExtension("exe")
        }
        #expect(throws: WorkflowArtifactUpload.Failure.self) {
            try WorkflowArtifactUpload.send(file: chosen, invocationID: UUID()) {
                Issue.record("Invalid file contacted the Host")
                return .ok(id: $0.id)
            }
        }
    }

    @Test
    func socketShortWritesContinueOnlyUnsentBytes() throws {
        let bytes = Data(String(repeating: "分块数据\n", count: 10_000).utf8)
        var output = Data()
        var interrupted = false
        try SocketClient.writeAll(bytes) { remaining in
            if !interrupted {
                interrupted = true
                errno = EINTR
                return -1
            }
            let count = min(remaining.count, 173)
            output.append(contentsOf: remaining.prefix(count))
            return count
        }
        #expect(output == bytes)
        for count in [0, -1] {
            #expect(throws: CLIError.self) {
                try SocketClient.writeAll(bytes) { _ in errno = EPIPE
                    return count
                }
            }
        }
    }
}
