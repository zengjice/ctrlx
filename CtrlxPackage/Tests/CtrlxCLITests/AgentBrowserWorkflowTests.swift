import Foundation
import Testing
@testable import CtrlxCLI

struct AgentBrowserWorkflowTests {
    @Test func batchKeepsLegacyArraysAndRejectsInvalidPlans() throws {
        let steps = try AgentBrowserBatch.decode(Data(#"[["get","title"]]"#.utf8))
        #expect(steps == [AgentBrowserBatchStep(command: ["get", "title"], output: nil)])
        for json in [#"[]"#, #"[["screenshot"]]"#, #"[["close"]]"#,
                     #"[{"command":["get","title"],"output":"/tmp/no-output"}]"#] {
            #expect(throws: (any Error).self) { try AgentBrowserBatch.decode(Data(json.utf8)) }
        }
    }

    @Test func batchContinueReportsFailureWithoutReplayingIt() throws {
        let steps = (0..<3).map { AgentBrowserBatchStep(command: ["eval", String($0)], output: nil) }
        var calls: [String] = []
        let results = try AgentBrowserBatch.execute(steps, continueOnError: true) { words in
            calls.append(words[1])
            if words[1] == "1" { throw AgentBrowserTransport.Failure("secret URL/token") }
            return ["value": words[1]]
        }
        #expect(calls == ["0", "1", "2"])
        #expect(results.compactMap { $0["success"] as? Bool } == [true, false, true])
        #expect(!(results[1]["error"] as? String ?? "").contains("secret"))
        calls = []
        #expect(throws: AgentBrowserTransport.Failure.self) {
            try AgentBrowserBatch.execute(steps, continueOnError: false) { words in
                calls.append(words[1])
                if words[1] == "1" { throw AgentBrowserTransport.Failure("failure") }
                return [:] as [String: String]
            }
        }
        #expect(calls == ["0", "1"])
    }

    @Test func batchArtifactsAreDistinctBoundedAndNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.png")
        let step = AgentBrowserBatchStep(command: ["screenshot"], output: file.path)
        try AgentBrowserBatch.validate([step])
        #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserBatch.validate([step, step]) }
        if try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false {
            #expect(throws: AgentBrowserTransport.Failure.self) {
                try AgentBrowserBatch.validate([step, AgentBrowserBatchStep(command: ["screenshot"], output: root.appendingPathComponent("IMAGE.PNG").path)])
            }
        }
        let skipped = try AgentBrowserBatch.export(["artifactSkipped": true], to: file.path) as? [String: Bool]
        #expect(skipped?["artifactSkipped"] == true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        _ = try AgentBrowserBatch.export(["data": Data("bytes".utf8).base64EncodedString()], to: file.path)
        var executed = false
        #expect(throws: AgentBrowserTransport.Failure.self) {
            try AgentBrowserBatch.execute([step], continueOnError: false) { _ in executed = true; return [:] as [String: String] }
        }
        #expect(!executed)
        #expect(try String(contentsOf: file, encoding: .utf8) == "bytes")
    }

    @Test func initInputAndOpaqueHandleValidation() throws {
        #expect(try AgentBrowserPageCommand.withInput(["init", "add"], data: Data("window.proof=1".utf8)) == ["init", "add", "window.proof=1"])
        try AgentBrowserPageCommand.validate(["init", "list"])
        try AgentBrowserPageCommand.validate(["init", "remove", UUID().uuidString])
        for words in [["init"], ["init", "list", "extra"], ["init", "remove", "init-script-1"], ["init", "add"]] {
            #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserPageCommand.validate(words) }
        }
    }

    @Test func webMCPMetadataIsBoundedUntrustedAndOrderIndependent() throws {
        let tools: [[String: Any]] = [
            ["name": "second", "frameId": "f", "description": "description", "inputSchema": ["secret": "not in preview"]],
            ["name": "first", "frameId": "f", "description": String(repeating: "文", count: 500)],
        ]
        let (digest, summary) = try AgentBrowserPageMetadata.catalog(tools)
        #expect(try AgentBrowserPageMetadata.catalog(tools.reversed()).digest == digest)
        #expect(summary["untrusted"] as? Bool == true)
        #expect(summary["truncated"] as? Bool == true)
        let encoded = try JSONSerialization.data(withJSONObject: summary)
        #expect(encoded.count < 4096)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("inputSchema"))
        let many = try AgentBrowserPageMetadata.catalog(Array(repeating: tools[0], count: 100)).summary
        #expect((many["tools"] as? [[String: String]])?.count ?? 99 <= 16)
        #expect(try JSONSerialization.data(withJSONObject: many).count < 4096)
    }

    @Test func discoveryFailureDoesNotFailOrRepeatCompletedAction() {
        let result = AgentBrowserPageMetadata.discover(after: ["clicked": true], root: URL(fileURLWithPath: "/nonexistent-fixture")) as? [String: Any]
        #expect(result?["clicked"] as? Bool == true)
        #expect((result?["webmcp"] as? [String: Any])?["status"] as? String == "unavailable")
    }
}
