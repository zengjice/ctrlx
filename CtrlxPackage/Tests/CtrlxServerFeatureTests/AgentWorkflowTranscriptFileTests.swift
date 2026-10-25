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
