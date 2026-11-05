import ClaudeCodePluginCore
import CodexPluginCore
import CoreGraphics
import CryptoKit
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import ImageIO
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowTranscriptFileTests {
    private func png() throws -> Data {
        var seed: UInt32 = 42
        let pixels = Data((0..<(900 * 900 * 4)).map { _ -> UInt8 in
            seed = 1_664_525 &* seed &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: seed >> 24)
        })
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(
            width: 900, height: 900, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 900 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func outcome(_ url: URL, parser: any AgentWorkflowTranscriptParser) async throws -> AgentWorkflowTranscriptOutcome? {
        let reader = try AgentWorkflowTranscriptFile(path: url.path, parser: parser)
        while true {
            let poll = try await reader.poll()
            if let result = poll.outcome {
                return result
            }
            if poll.reachedEnd {
                return nil
            }
        }
    }

    @Test(arguments: ["codex", "claude"])
    func legalPNGAndOldImageRecordsDoNotBlockCurrentResult(plugin: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-large-image-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try png()
        #expect(image.count > 1_600_000 && image.count < 20 * 1_024 * 1_024)
        let file = root.appendingPathComponent("image.png")
        try image.write(to: file)
        let metadata = AgentWorkflowAttachment(
            id: UUID(), name: "image.png", mediaType: "image/png", byteCount: Int64(image.count),
            sha256: SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        )
        try await AgentWorkflowAttachmentReader().validate([.init(attachment: metadata, url: file)])
        let encoded = image.base64EncodedString()
        var records: [[String: Any]] = []
        let parser: any AgentWorkflowTranscriptParser
        if plugin == "codex" {
            parser = CodexWorkflowTranscript(conversationID: "session", nativeTurnID: "current")
            records = [
                ["type": "session_meta", "payload": ["id": "session"]],
                ["type": "response_item", "payload": ["type": "function_call_output", "output": [["type": "input_image", "image_url": "data:image/png;base64," + encoded]]]],
                ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "old", "last_agent_message": "Old result"]],
                ["type": "event_msg", "payload": ["type": "user_message", "images": ["data:image/png;base64," + encoded]]],
                ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "current", "last_agent_message": "Final"]],
            ]
        } else {
            parser = ClaudeWorkflowTranscript(conversationID: "session", nativeTurnID: "current", prompt: "Review", candidate: "Final")
            let block: [String: Any] = ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": encoded]]
            records = [
                ["type": "user", "uuid": "old-user", "promptId": "old", "message": ["content": [block]]],
                ["type": "user", "uuid": "current-user", "promptId": "current", "message": ["content": [block, block]]],
                ["type": "assistant", "uuid": "assistant", "parentUuid": "current-user", "message": ["id": "answer", "stop_reason": "end_turn", "content": [["type": "text", "text": "Final"]]]],
                ["type": "system", "uuid": "summary", "parentUuid": "assistant", "subtype": "stop_hook_summary", "hookErrors": [], "hookAdditionalContext": [], "preventedContinuation": false, "stopReason": ""],
            ].map { $0.merging(["sessionId": "session", "isSidechain": false]) { value, _ in value } }
        }
        let transcript = root.appendingPathComponent("native.jsonl")
        var bytes = Data()
        for record in records {
            // Sorted keys place the image before Claude's prompt/session IDs.
            try bytes.append(JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            bytes.append(10)
        }
        try bytes.write(to: transcript)
        #expect(try await outcome(transcript, parser: parser) == .succeeded("Final"))
    }

    @Test(arguments: ["codex", "claude"])
    func skipsOldOversizedTextAndRetainsPartialCurrentRecord(plugin: String) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-turn-offset-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let turn = "current-native-turn"
        var bytes = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"session\"}}\n".utf8)
        // Historical tool output exceeds the parser's retained-record budget.
        bytes.append(Data("{\"old\":\"".utf8))
        bytes.append(Data(repeating: 120, count: 3 * 1_024 * 1_024))
        bytes.append(Data("\"}\n".utf8))
        let parser: any AgentWorkflowTranscriptParser
        let current: Data
        let completion: Data
        if plugin == "codex" {
            parser = CodexWorkflowTranscript(conversationID: "session", nativeTurnID: turn)
            current = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"\(turn)\"}}\n".utf8)
            completion = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"\(turn)\",\"last_agent_message\":\"Final\"}}\n".utf8)
        } else {
            parser = ClaudeWorkflowTranscript(conversationID: "session", nativeTurnID: turn, prompt: "Review", candidate: "")
            current = Data("{\"type\":\"user\",\"sessionId\":\"session\",\"isSidechain\":false,\"uuid\":\"u\",\"promptId\":\"\(turn)\"}\n".utf8)
            completion = Data((
                "{\"type\":\"assistant\",\"sessionId\":\"session\",\"isSidechain\":false,\"uuid\":\"a\",\"parentUuid\":\"u\",\"message\":{\"id\":\"m\",\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"Final\"}]}}\n" +
                    "{\"type\":\"system\",\"sessionId\":\"session\",\"isSidechain\":false,\"uuid\":\"s\",\"parentUuid\":\"a\",\"subtype\":\"stop_hook_summary\",\"hookErrors\":[],\"hookAdditionalContext\":[],\"preventedContinuation\":false,\"stopReason\":\"\"}\n"
            ).utf8)
        }
        // A native ID straddles the reader's 64 KiB boundary.
        let markerIndex = try #require(current.range(of: Data(turn.utf8))).lowerBound
        let padding = (64 * 1_024 - (bytes.count + markerIndex + 4) % (64 * 1_024)) % (64 * 1_024)
        if padding > 0 {
            bytes.append(Data(repeating: 32, count: padding - 1))
            bytes.append(10)
        }
        bytes.append(current.dropLast(3))
        try bytes.write(to: path)
        let reader = try AgentWorkflowTranscriptFile(path: path.path, parser: parser)
        while try await !reader.poll().reachedEnd { }
        let writer = try FileHandle(forWritingTo: path)
        try writer.seekToEnd()
        try writer.write(contentsOf: current.suffix(3) + completion)
        try writer.close()
        // Read completion before the Stop callback, then reuse its evidence.
        while try await !reader.poll().reachedEnd { }
        await reader.updateCandidate("Final")
        #expect(try await reader.poll().outcome == .succeeded("Final"))
        #expect(try await reader.poll().reachedEnd)
    }

    @Test(arguments: [false, true])
    func largeStartRecordSharesPollBudgetAndIsNotParsedTwice(markerAtEnd: Bool) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-start-budget-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        // A quoted ID must not select an unrelated record or discard the next
        // record's bytes when both occur in the same chunk.
        try Data(#"{"text":"quoted native-turn-identifier"}"#.utf8).write(to: path)
        let writer = try FileHandle(forWritingTo: path)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data([10]))
        let identity = #""type":"user","sessionId":"session","isSidechain":false,"uuid":"user","promptId":"native-turn-identifier""#
        let image = #""message":{"content":[{"type":"image","source":{"type":"base64","data":""#
        try writer.write(contentsOf: Data(("{" + (markerAtEnd ? "" : identity + ",") + image).utf8))
        var remaining = (20 * 1_024 * 1_024 + 2) / 3 * 4
        let chunk = Data(repeating: 65, count: 64 * 1_024)
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            try writer.write(contentsOf: chunk.prefix(count))
            remaining -= count
        }
        try writer.write(contentsOf: Data((#""}}]}"# + (markerAtEnd ? "," + identity : "") + "}\n").utf8))
        for record: [String: Any] in [
            ["type": "assistant", "uuid": "answer", "parentUuid": "user", "message": ["id": "message", "stop_reason": "end_turn", "content": [["type": "text", "text": "Final"]]]],
            ["type": "system", "uuid": "summary", "parentUuid": "answer", "subtype": "stop_hook_summary", "hookErrors": [], "hookAdditionalContext": [], "preventedContinuation": false, "stopReason": ""],
        ] {
            try writer.write(contentsOf: JSONSerialization.data(withJSONObject: record.merging(["sessionId": "session", "isSidechain": false]) { value, _ in value }))
            try writer.write(contentsOf: Data([10]))
        }
        let size = try writer.offset()
        try writer.close()
        let reader = try AgentWorkflowTranscriptFile(path: path.path, parser: ClaudeWorkflowTranscript(
            conversationID: "session", nativeTurnID: "native-turn-identifier", prompt: "Review", candidate: ""
        ))
        var result: AgentWorkflowTranscriptOutcome?
        for index in 0..<128 {
            let before = await reader.bytesRead
            let poll = try await reader.poll()
            #expect(await reader.bytesRead - before <= 1_024 * 1_024)
            if index == 2 {
                // Stop can update the candidate between bounded polls, while
                // the large user record is still incomplete.
                await reader.updateCandidate("Final")
            }
            if let outcome = poll.outcome {
                result = outcome
                break
            }
            if poll.reachedEnd {
                break
            }
        }
        #expect(result == .succeeded("Final"))
        // A late marker requires one byte scan then one streamed parse. An
        // early marker can reuse the buffered prefix and read the record once.
        #expect(await reader.bytesRead <= size * (markerAtEnd ? 2 : 1) + 64 * 1_024)
    }

    @Test
    func locatingTurnStillRequiresMatchingCodexSessionHeader() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-wrong-session-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        try Data((
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"other\"}}\n" +
                "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"current\",\"last_agent_message\":\"Wrong\"}}\n"
        ).utf8).write(to: path)
        #expect(try await outcome(path, parser: CodexWorkflowTranscript(conversationID: "session", nativeTurnID: "current")) == nil)
    }

    @Test
    func mediaPayloadIsStreamedWithoutRetainingIt() throws {
        var record = AgentWorkflowTranscriptRecord()
        try record.append(Data(#"{"message":{"content":["#.utf8)[...])
        for index in 0..<32 {
            if index != 0 {
                try record.append(Data(",".utf8)[...])
            }
            try record.append(Data(#"{"source":{"data":""#.utf8)[...])
            // One maximum-sized Base64 image and 31 smaller images. Feed in
            // chunks, including escaped slashes split across chunk boundaries.
            let count = index == 0 ? (20 * 1_024 * 1_024 + 2) / 3 * 4 : 4
            let chunk = Data(repeating: 65, count: 64 * 1_024)
            var left = count
            while left > 0 {
                let size = min(left, chunk.count)
                try record.append(chunk.prefix(size))
                left -= size
            }
            try record.append(Data([92])[...])
            try record.append(Data(#"/","type":"base64"}}"#.utf8)[...])
            #expect(record.retained.count < 8_192)
        }
        try record.append(Data(#"]},"promptId":"current","uuid":"after-images"}"#.utf8)[...])
        let value = try #require(JSONSerialization.jsonObject(with: record.finish()) as? [String: Any])
        #expect(value["uuid"] as? String == "after-images")
        #expect(value["promptId"] as? String == "current")
    }

    @Test
    func ordinaryURLsAndTextArePreservedAndMalformedMediaIsRejected() throws {
        let input = Data(#"{"image_url":"https://example.test/image.png","payload":{"text":"quote: \" and slash: \\"},"source":{"data":"AA\/AA=="}}"#.utf8)
        var record = AgentWorkflowTranscriptRecord()
        for byte in input {
            try record.append(Data([byte])[...])
        }
        let value = try #require(JSONSerialization.jsonObject(with: record.finish()) as? [String: Any])
        #expect(value["image_url"] as? String == "https://example.test/image.png")
        #expect((value["payload"] as? [String: String])?["text"] == "quote: \" and slash: \\")
        for invalid in [#"{"source":{"data":"bad\x"}}"#, #"{"source":{"data":"bad\uZZZZ"}}"#, #"{"source":{"data":"unterminated"#] {
            #expect(throws: AgentWorkflowError.self) {
                var record = AgentWorkflowTranscriptRecord()
                try record.append(Data(invalid.utf8)[...])
                _ = try record.finish()
            }
        }
        #expect(throws: AgentWorkflowError.self) {
            var record = AgentWorkflowTranscriptRecord()
            try record.append(Data(#"{"text":""#.utf8)[...])
            try record.append(Data(repeating: 65, count: 2 * 1_024 * 1_024)[...])
        }
    }
}
