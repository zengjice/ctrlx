import ClaudeCodePluginCore
import CodexPluginCore
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowSubmissionReadingTests {
    private struct Fixture {
        let directory: URL
        let file: URL
        let original: String
        let current: String
        let originalStart: UInt64
        let originalEnd: UInt64
        let currentStart: UInt64
        let currentEnd: UInt64

        var turn: PluginWorkflowTurn {
            .init(nativeTurnID: current, transcriptPath: file.path)
        }

        func reader(anchorOffset: UInt64? = nil, anchorHookStartedAt: Date = .distantPast) throws -> AgentWorkflowTranscriptFile {
            let parser = CodexWorkflowTranscript(conversationID: "session", nativeTurnID: current)
            let identity = try AgentWorkflowTranscriptFile(path: file.path, parser: parser).fileIdentity
            return try AgentWorkflowTranscriptFile(path: file.path, parser: parser, submissionAnchor: .init(
                turnID: original, boundary: .init(identity: identity, offset: anchorOffset ?? originalStart, end: originalEnd, timestamp: Date(timeIntervalSince1970: 1)), hookStartedAt: anchorHookStartedAt
            ))
        }

        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }
    }

    private func fixture(historyBytes: Int = 8 * 1_024 * 1_024) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-submission-reading-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("native.jsonl")
        let original = "original-\(UUID())", current = "current-\(UUID())"
        var data = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"session\"}}\n{\"old\":\"".utf8)
        data.append(Data(repeating: 120, count: historyBytes))
        data.append(Data("\"}\n".utf8))
        let originalStart = UInt64(data.count)
        data.append(Data(start(original).utf8))
        let originalEnd = UInt64(data.count)
        data.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"\(original)\",\"last_agent_message\":\"Done\"}}\n".utf8))
        let currentStart = UInt64(data.count)
        data.append(Data(start(current).utf8))
        let currentEnd = UInt64(data.count)
        try data.write(to: file)
        return .init(directory: directory, file: file, original: original, current: current, originalStart: originalStart, originalEnd: originalEnd, currentStart: currentStart, currentEnd: currentEnd)
    }

    private func start(_ id: String, timestamp: String? = "1970-01-01T00:00:01Z") -> String {
        let time = timestamp.map { ",\"timestamp\":\"\($0)\"" } ?? ""
        return "{\"type\":\"event_msg\"\(time),\"payload\":{\"type\":\"task_started\",\"turn_id\":\"\(id)\"}}\n"
    }

    private func input(_ text: String) throws -> String {
        let row: [String: Any] = ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]]
        return try String(decoding: JSONSerialization.data(withJSONObject: row), as: UTF8.self) + "\n"
    }

    @Test(arguments: [false, true])
    func deliveryPositionWaitsForTheActualInput(contextOnly: Bool) async throws {
        let f = try fixture(historyBytes: 512)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let turn = PluginWorkflowTurn(nativeTurnID: f.original, transcriptPath: f.file.path)
        let reader = try AgentWorkflowTranscriptFile(path: f.file.path, parser: CodexWorkflowTranscript(conversationID: "session", nativeTurnID: f.original))
        let prompt = "Task\n[CtrlX workflow invocation: unique-delivery]"
        #expect(try await reader.verifyDelivery(turn, input: prompt) == nil)
        let parsed = await reader.submissionBytesRead
        #expect(try await reader.verifyDelivery(turn, input: prompt) == nil)
        #expect(await reader.submissionBytesRead == parsed)
        let offset = try UInt64(Data(contentsOf: f.file).count)
        if contextOnly {
            try f.append("{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"\(f.original)\"}}\n")
        } else {
            try f.append(start(f.original))
        }
        let row = try input(prompt)
        try f.append(String(row.dropLast(8)))
        #expect(try await reader.verifyDelivery(turn, input: prompt) == nil)
        try f.append(String(row.suffix(8)))
        let proof = try #require(await reader.verifyDelivery(turn, input: prompt))
        #expect(proof.nativeStart?.offset == offset)
        #expect(proof.nativeStart?.inputOffset != nil && proof.matchedInput == prompt)
    }

    @Test
    func aCorrelatedReusedIDKeepsColdAndIncrementalReadsBounded() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let turn = PluginWorkflowTurn(nativeTurnID: f.original, transcriptPath: f.file.path)
        let offset = try UInt64(Data(contentsOf: f.file).count)
        try f.append(start(f.original))
        let prompt = "Task\n[CtrlX workflow invocation: verified-delivery]"
        try f.append(input(prompt))
        let full = try AgentWorkflowTranscriptFile(path: f.file.path, parser: CodexWorkflowTranscript(conversationID: "session", nativeTurnID: f.original))
        let proof = try #require(await full.verifyDelivery(turn, input: prompt))
        let boundary = try #require(proof.nativeStart)
        #expect(boundary.offset == offset)
        let cold = try AgentWorkflowTranscriptFile(path: f.file.path, parser: CodexWorkflowTranscript(conversationID: "session", nativeTurnID: f.original), submissionAnchor: .init(turnID: f.original, boundary: boundary))
        #expect(try await cold.verifyDelivery(turn, input: prompt)?.nativeStart?.offset == offset)
        #expect(await cold.bytesRead < 256 * 1_024)
        let parsed = await cold.submissionBytesRead
        let read = await cold.bytesRead
        let progress = "{\"progress\":0}\n"
        try f.append(progress)
        #expect(try await cold.verifyDelivery(turn, input: prompt)?.nativeStart?.offset == offset)
        #expect(await cold.submissionBytesRead == parsed)
        #expect(await cold.bytesRead - read < 256 * 1_024)
    }

    @Test(arguments: [false, true], [1, 2, 3])
    func aFutureClaudeSuffixMatchRequiresFullFileUniqueness(earlierMatch: Bool, futureRecords: Int) async throws {
        let f = try fixture(historyBytes: 0)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        func user(_ id: String, at time: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "user", "promptId": id, "uuid": UUID().uuidString, "sessionId": "session", "isSidechain": false, "timestamp": Date(timeIntervalSince1970: Double(time)).formatted(.iso8601), "message": ["content": "Input"]]) + Data([10])
        }
        var data = Data("{\"ignored\":true}\n".utf8)
        if earlierMatch {
            try data.append(user("B", at: 1_000))
        }
        let offset = UInt64(data.count)
        try data.append(user("A", at: 2_000))
        let end = UInt64(data.count)
        let rejected: [String: Any] = [
            "type": "system", "sessionId": "session", "isSidechain": false, "subtype": "informational",
            "timestamp": "1970-01-01T00:41:40Z", "preventContinuation": true,
            "content": "UserPromptSubmit operation blocked by hook:\n[fixture]: Rejected.\n\nOriginal prompt: Input",
            "promptSubmitEnding": ["ending": ["kind": "blocked_by_hook", "reason": "Rejected."], "promptKept": false],
        ]
        try data.append(JSONSerialization.data(withJSONObject: rejected) + Data([10]))
        for index in 0..<futureRecords {
            if futureRecords == 3 {
                var row = try #require(JSONSerialization.jsonObject(with: user("B", at: 3_000)) as? [String: Any])
                row.removeValue(forKey: "timestamp")
                try data.append(JSONSerialization.data(withJSONObject: row) + Data([10]))
            } else {
                try data.append(user("B", at: 3_000 + index))
            }
        }
        try data.write(to: f.file)
        let parser = ClaudeWorkflowTranscript(conversationID: "session", nativeTurnID: "B", prompt: "Input", candidate: "")
        let full = try AgentWorkflowTranscriptFile(path: f.file.path, parser: parser)
        let scoped = try AgentWorkflowTranscriptFile(path: f.file.path, parser: parser, submissionAnchor: .init(turnID: "A", boundary: .init(identity: full.fileIdentity, offset: offset, end: end, timestamp: Date(timeIntervalSince1970: 2_000)), hookStartedAt: Date(timeIntervalSince1970: 2_000)))
        let turn = PluginWorkflowTurn(nativeTurnID: "B", transcriptPath: f.file.path)
        let hook = Date(timeIntervalSince1970: 2_500)
        for reader in [full, scoped] {
            let unique = !earlierMatch && futureRecords == 1
            #expect(try (await reader.verifyCurrentSubmission(turn, hookStartedAt: hook) != nil) == unique)
            #expect(try (await reader.verifyCurrentSubmission(turn, hookStartedAt: hook) != nil) == unique)
            if earlierMatch {
                let historical = try #require(await reader.verifySubmittedTurn(turn, hookStartedAt: hook))
                #expect(historical.submittedAt == Date(timeIntervalSince1970: 1_000))
                #expect(historical.nativeStart?.offset == UInt64(Data("{\"ignored\":true}\n".utf8).count))
            }
        }
    }

    @Test
    func aVerifiedSameIDAnchorWithoutHookTimeSkipsEarlierHistory() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = try f.reader()
        let original = PluginWorkflowTurn(nativeTurnID: f.original, transcriptPath: f.file.path)
        #expect(try await reader.hasNewerSubmission(than: original) == true)
        let initial = await reader.bytesRead
        #expect(initial < 256 * 1_024)
        try f.append("{\"progress\":0}\n")
        #expect(try await reader.hasNewerSubmission(than: original) == true)
        #expect(await reader.bytesRead - initial < 256 * 1_024)
    }

    @Test(arguments: [false, true])
    func aLargeSessionHeaderIsReadBeforeSeekingTheDelivery(scoped: Bool) async throws {
        let f = try fixture(historyBytes: 0)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": "session", "instructions": String(repeating: "x", count: 1_100_000)]]) + Data([10])
        let prompt = "Large header task"
        var data = header
        data.append(Data(start(f.current).utf8))
        try data.append(Data(input(prompt).utf8))
        data.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"\(f.current)\",\"last_agent_message\":\"Done\"}}\n".utf8))
        try data.write(to: f.file)
        let locating = try AgentWorkflowTranscriptFile(path: f.file.path, parser: CodexWorkflowTranscript(conversationID: "session", nativeTurnID: f.current))
        let proof = try #require(await locating.verifyDelivery(f.turn, input: prompt))
        let reader = try AgentWorkflowTranscriptFile(path: f.file.path, parser: CodexWorkflowTranscript(conversationID: "session", nativeTurnID: f.current))
        if scoped {
            #expect(try await reader.verifiedOutcome(for: proof, hasStop: true)?.0 == .succeeded("Done"))
        } else {
            #expect(try await reader.start(at: proof))
            #expect(try await reader.verifiedOutcome(at: f.file.path)?.0 == .succeeded("Done"))
        }
    }

    @Test
    func aPositionedClaudeReaderKeepsItsVerifiedVersionBeforeTheFirstPoll() async throws {
        let f = try fixture(historyBytes: 0)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        func row(_ text: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "user", "promptId": "B", "uuid": "user", "sessionId": "session", "isSidechain": false, "message": ["content": text]]) + Data([10])
        }
        try row("Task A").write(to: f.file)
        let parser = ClaudeWorkflowTranscript(conversationID: "session", nativeTurnID: "B", prompt: "Task A", candidate: "")
        let locating = try AgentWorkflowTranscriptFile(path: f.file.path, parser: parser)
        let proof = try #require(await locating.verifyDelivery(.init(nativeTurnID: "B", transcriptPath: f.file.path), input: "Task A"))
        let reader = try AgentWorkflowTranscriptFile(path: f.file.path, parser: parser)
        #expect(try await reader.start(at: proof))
        let writer = try FileHandle(forWritingTo: f.file)
        try writer.write(contentsOf: row("Task B"))
        try writer.close()
        _ = try await reader.poll()
        #expect(try await reader.verifiedOutcome(at: f.file.path) == nil)
    }

    @Test
    func knownSubmissionSkipsOldHistoryAndRetriesOnlyParseAppendedRecords() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = try f.reader()
        #expect(try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture) != nil)
        let initial = await reader.bytesRead
        #expect(initial < 256 * 1_024)
        #expect(try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture) != nil)
        #expect(await reader.bytesRead == initial)
        let parsed = await reader.submissionBytesRead
        try f.append("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n")
        #expect(try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture) != nil)
        #expect(await reader.submissionBytesRead - parsed < 64 * 1_024)
        #expect(await reader.bytesRead - initial < 256 * 1_024)
    }

    @Test
    func laterSubmissionInvalidatesThePreviousCurrentTurn() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = try f.reader()
        #expect(try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture) != nil)
        try f.append(start("later"))
        #expect(try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture) == nil)
        #expect(try await reader.verifySubmittedTurn(f.turn) != nil)
    }

    @Test(arguments: [false, true])
    func inPlaceRewriteInvalidatesCachedMetadataEvenWhenAlsoAppending(append: Bool) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = try f.reader()
        #expect(try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture) != nil)
        let replacement = String(repeating: "z", count: f.current.utf8.count)
        let handle = try FileHandle(forWritingTo: f.file)
        try handle.seek(toOffset: f.currentStart)
        try handle.write(contentsOf: Data(start(replacement).utf8))
        try handle.close()
        if append {
            try f.append("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n")
        }
        #expect(try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture) == nil)
        #expect(try await reader.verifyCurrentSubmission(.init(nativeTurnID: replacement, transcriptPath: f.file.path), hookStartedAt: .distantFuture) != nil)
    }

    @Test
    func truncatedFileDoesNotReuseCachedCurrentTurn() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = try f.reader()
        #expect(try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture) != nil)
        let handle = try FileHandle(forWritingTo: f.file)
        try handle.truncate(atOffset: f.currentStart)
        try handle.close()
        #expect(try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture) == nil)
    }

    @Test
    func concurrentChecksShareOneScan() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = try AgentWorkflowTranscriptFile(path: f.file.path, parser: CodexWorkflowTranscript(conversationID: "session", nativeTurnID: f.current))
        async let first = reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture)
        async let second = reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture)
        let results = try await (first, second)
        #expect(results.0 != nil && results.1 != nil)
        #expect(await reader.submissionBytesRead < 9 * 1_024 * 1_024)
    }

    @Test
    func ordinaryAppendDuringVerificationKeepsTheParsedPrefix() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = try AgentWorkflowTranscriptFile(path: f.file.path, parser: AppendingSubmissionParser(
            parser: .init(conversationID: "session", nativeTurnID: f.current), target: f.current,
            append: { try f.append("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n") }
        ))
        #expect(try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture) != nil)
        #expect(await reader.submissionBytesRead < 9 * 1_024 * 1_024)
    }

    @Test
    func incompleteAppendedSubmissionWaitsForItsRemainingBytes() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = try f.reader()
        #expect(try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture) != nil)
        let next = start("later")
        try f.append(String(next.dropLast(8)))
        #expect(try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture) == nil)
        let parsed = await reader.submissionBytesRead
        try f.append(String(next.suffix(8)))
        #expect(try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture) == nil)
        #expect(await reader.submissionBytesRead - parsed == 8)
    }

    @Test
    func invalidSavedPositionFallsBackToLocatingTheOriginalSubmission() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = try f.reader(anchorOffset: f.originalStart + 5)
        #expect(try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture) != nil)
        #expect(await reader.submissionBytesRead > 8 * 1_024 * 1_024)
    }

    @Test
    func rewrittenPartialRecordRetainsItsUnverifiedAnchorUntilComplete() async throws {
        let f = try fixture(historyBytes: 512)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = try f.reader()
        #expect(try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture) != nil)
        var rewritten = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"session\"}}\n".utf8)
        rewritten.append(Data(start(f.current).utf8))
        let padding = Int(f.originalStart) - rewritten.count - Data("{\"padding\":\"\"}\n".utf8).count
        rewritten.append(Data("{\"padding\":\"\(String(repeating: "x", count: padding))\"}\n".utf8))
        rewritten.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"value\":\"\(String(repeating: "x", count: 300))".utf8))
        let handle = try FileHandle(forWritingTo: f.file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: rewritten)
        try handle.close()
        #expect(try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture) == nil)
        try f.append("\"}}\n")
        let first = try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture)
        let second = try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture)
        let fresh = try await f.reader().verifyCurrentSubmission(f.turn, hookStartedAt: .distantFuture)
        #expect(first != nil && second != nil && fresh != nil)
        #expect(first?.nativeStart == fresh?.nativeStart)
        #expect(second?.nativeStart == fresh?.nativeStart)
    }

    @Test(arguments: [false, true])
    func orderChecksUseReceiptTimeAndKeepEarlierReceiptsOnTheFullScan(earlier: Bool) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = try f.reader(anchorHookStartedAt: Date(timeIntervalSince1970: 10))
        let hook = earlier ? Date.distantPast : .distantFuture
        #expect(try await reader.hasNewerSubmission(than: f.turn, requiringReceipt: true, hookStartedAt: hook) == false)
        let initial = await reader.bytesRead
        #expect(earlier ? initial > 8 * 1_024 * 1_024 : initial < 256 * 1_024)
        let parsed = await reader.submissionBytesRead
        let progress = "{\"progress\":0}\n"
        try f.append(progress)
        #expect(try await reader.hasNewerSubmission(than: f.turn, requiringReceipt: true, hookStartedAt: hook) == false)
        let additional = await reader.bytesRead - initial
        #expect(earlier ? additional > 8 * 1_024 * 1_024 : additional < 256 * 1_024)
        #expect(await reader.submissionBytesRead - parsed == progress.utf8.count)
        try f.append(start("later"))
        #expect(try await reader.hasNewerSubmission(than: f.turn, requiringReceipt: true, hookStartedAt: hook) == true)
    }

    @Test
    func anOlderSameIDReceiptCannotBorrowASubmissionAfterTheSavedPosition() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        var data = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"session\"}}\n".utf8)
        let oldOffset = UInt64(data.count)
        data.append(Data(start(f.current, timestamp: "1970-01-01T00:00:00Z").utf8))
        let anchorOffset = UInt64(data.count)
        data.append(Data(start(f.original, timestamp: "1970-01-01T00:00:01Z").utf8))
        let anchorEnd = UInt64(data.count)
        data.append(Data(start(f.current, timestamp: "1970-01-01T00:00:02Z").utf8))
        try data.write(to: f.file)
        let parser = CodexWorkflowTranscript(conversationID: "session", nativeTurnID: f.current)
        let identity = try AgentWorkflowTranscriptFile(path: f.file.path, parser: parser).fileIdentity
        let reader = try AgentWorkflowTranscriptFile(path: f.file.path, parser: parser, submissionAnchor: .init(
            turnID: f.original,
            boundary: .init(identity: identity, offset: anchorOffset, end: anchorEnd, timestamp: Date(timeIntervalSince1970: 1)),
            hookStartedAt: Date(timeIntervalSince1970: 1.5)
        ))
        let oldHook = Date(timeIntervalSince1970: 0.5)
        let proof = try await reader.verifySubmittedTurn(f.turn, hookStartedAt: oldHook)
        #expect(proof?.nativeStart?.offset == oldOffset)
        #expect(try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: oldHook) == nil)
        #expect(try await reader.verifyCurrentSubmission(f.turn, hookStartedAt: Date(timeIntervalSince1970: 2.5)) != nil)
    }

    @Test
    func cachedReadersAreReplacedWhenThePathNamesAnotherFile() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let instance = AgentWorkflowInstance(
            hostID: UUID(), pluginID: "codex", processID: 1, processRuntimeID: "runtime",
            workspacePane: .init(serverID: "tmux", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: "%1", conversationID: "session", displayName: "Test", workingDirectory: f.directory.path,
            capabilities: nil, readiness: .ready
        )
        let readers = AgentWorkflowTranscriptReaders()
        let first = try await readers.reader(turn: f.turn, instance: instance, prompt: "Task", provider: CodexPluginCore())
        #expect(try await readers.reader(turn: f.turn, instance: instance, prompt: "Task", provider: CodexPluginCore()) === first)
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"session\"}}\n".utf8).write(to: f.file, options: .atomic)
        let replacement = try await readers.reader(turn: f.turn, instance: instance, prompt: "Task", provider: CodexPluginCore())
        #expect(replacement !== first)
        #expect(try await replacement.verifyCurrentSubmission(f.turn) == nil)
    }

    @Test
    func aContextPositionSurvivesALaterStartWithTheSameID() async throws {
        let f = try fixture(historyBytes: 0)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let prefix = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"session\"}}\n"
        let context = "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"\(f.original)\"}}\n"
        let prompt = "Task [CtrlX workflow invocation: context]"
        try Data((prefix + context + input(prompt)).utf8).write(to: f.file)
        let turn = PluginWorkflowTurn(nativeTurnID: f.original, transcriptPath: f.file.path)
        let deliveryReader = try AgentWorkflowTranscriptFile(path: f.file.path, parser: CodexWorkflowTranscript(conversationID: "session", nativeTurnID: f.original))
        let delivery = try #require(await deliveryReader.verifyDelivery(turn, input: prompt))
        try f.append(start(f.original))
        let metadata = try AgentWorkflowTranscriptFile(path: f.file.path, parser: CodexWorkflowTranscript(conversationID: "session", nativeTurnID: f.original))
        let proof = try #require(await metadata.verifySubmittedTurn(turn, nativeStart: delivery.nativeStart))
        #expect(proof.nativeStart?.offset == UInt64(prefix.utf8.count))
        #expect(proof.nativeStart?.nextOffset != nil)
    }

    @Test
    func deliveryAndOrderQueriesKeepIndependentScanState() async throws {
        let f = try fixture(historyBytes: 0)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let instance = AgentWorkflowInstance(hostID: UUID(), pluginID: "codex", processID: 1, processRuntimeID: "runtime", workspacePane: .init(serverID: "tmux", sessionID: UUID(), windowID: UUID(), paneID: UUID()), paneID: "%1", conversationID: "session", displayName: "Test", workingDirectory: f.directory.path, capabilities: nil, readiness: .ready)
        let turn = PluginWorkflowTurn(nativeTurnID: f.original, transcriptPath: f.file.path)
        let prompt = "Task [CtrlX workflow invocation: cache]"
        let prefix = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"session\"}}\n"
        try Data((prefix + start(f.original) + input(prompt)).utf8).write(to: f.file)
        for _ in 0..<16 {
            try f.append("{\"progress\":0,\"padding\":\"" + String(repeating: "x", count: 256 * 1_024) + "\"}\n")
        }
        let readers = AgentWorkflowTranscriptReaders()
        let delivery = try await readers.reader(turn: turn, instance: instance, prompt: prompt, provider: CodexPluginCore(), forDelivery: true)
        let order = try await readers.reader(turn: turn, instance: instance, prompt: prompt, provider: CodexPluginCore())
        #expect(delivery !== order)
        #expect(try await delivery.verifyDelivery(turn, input: prompt) != nil)
        #expect(try await order.verifyCurrentSubmission(turn) != nil)
        let parsed = await order.submissionBytesRead
        for _ in 0..<2 {
            #expect(try await delivery.verifyDelivery(turn, input: prompt) != nil)
            #expect(try await order.verifyCurrentSubmission(turn) != nil)
            #expect(await order.submissionBytesRead == parsed)
        }
    }
}

private struct AppendingSubmissionParser: AgentWorkflowTranscriptParser {
    var parser: CodexWorkflowTranscript
    let target: String
    let append: @Sendable () throws -> Void
    var appended = false
    var startMarkers: [String] {
        parser.startMarkers
    }

    var readsSessionHeader: Bool {
        parser.readsSessionHeader
    }

    func isTurnStart(_ line: Data) throws -> Bool {
        try parser.isTurnStart(line)
    }

    mutating func submittedTurnID(in line: Data) throws -> String? {
        try parser.submittedTurnID(in: line)
    }

    mutating func resumedTurnID(in line: Data) throws -> String? {
        let id = try parser.resumedTurnID(in: line)
        if id == target, !appended {
            appended = true
            try append()
        }
        return id
    }

    mutating func consume(_ line: Data) throws -> AgentWorkflowTranscriptOutcome? {
        try parser.consume(line)
    }

    mutating func updateCandidate(_ text: String) -> AgentWorkflowTranscriptOutcome? {
        parser.updateCandidate(text)
    }
}
