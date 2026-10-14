import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CodexPluginCore

@Suite("Codex question notifications")
struct CodexQuestionNotificationTests {
    @Test("Synchronous and asynchronous questions notify without changing state", arguments: [
        "request_user_input", "request_user_input_async", "functions.request_user_input", "functions.request_user_input_async",
    ])
    func questions(tool: String) async throws {
        let core = makeCore()
        let event = try #require(try await core.handleIngress(frame(tool: tool)))
        #expect(event.notification?.isQuestion == true)
        #expect(event.notification?.questionID == "session:call")
        #expect(event.notification?.title == "Codex wants answers")
        #expect(event.notification?.body == "Which directory should I use?")
        #expect(event.state == nil)
        #expect(event.appActions.isEmpty)
        #expect(event.tmuxPane == "%7")
        #expect(event.projectPath == "/host/repo")
    }

    @Test("Tool-call IDs deduplicate per session, including non-adjacent duplicates")
    func deduplication() async throws {
        let core = makeCore()
        let first = try frame(callID: "call-a")
        #expect(await core.handleIngress(first)?.notification != nil)
        #expect(try await core.handleIngress(frame(callID: "call-b"))?.notification != nil)
        #expect(await core.handleIngress(first) == nil)
        #expect(try await core.handleIngress(frame(sessionID: "other", callID: "call-a"))?.notification != nil)
        #expect(try await core.handleIngress(frame(callID: "call-a", event: "PostToolUse"))?.notification == nil)
    }

    @Test("Subagent questions and unrelated tools do not emit a question notification")
    func unrelatedEvents() async throws {
        let core = makeCore()
        #expect(try await core.handleIngress(frame(subagent: true)) == nil)
        for tool in ["exec_command", "mcp__example__request_user_input"] {
            #expect(try await core.handleIngress(frame(tool: tool))?.notification == nil)
        }
    }

    @Test("Missing IDs, empty questions and malformed input do not fabricate alerts")
    func invalidQuestions() async throws {
        let core = makeCore()
        for (callID, questions) in [("", ["Valid question"]), ("a", []), ("b", ["  "])] {
            #expect(try await core.handleIngress(frame(callID: callID, questions: questions))?.notification == nil)
        }
        #expect(CodexQuestionNotification(payload: Data("{}".utf8)) == nil)
    }

    @Test("Session end and shutdown discard question deduplication state")
    func cleanup() async throws {
        let core = makeCore()
        let question = try frame()
        #expect(await core.handleIngress(question)?.notification != nil)
        _ = try await core.handleIngress(frame(event: "SessionEnd"))
        #expect(await core.handleIngress(question)?.notification != nil)
        await core.shutdown()
        #expect(await core.handleIngress(question)?.notification != nil)
    }

    @Test("Multiple questions retain their count and bounded preview text")
    func boundedPreview() throws {
        let input = try frame(questions: [String(repeating: "问", count: 300), "Second question"])
        let notification = try #require(CodexQuestionNotification(payload: input.payload)?.notification)
        #expect(notification.body.hasPrefix("2 questions:"))
        #expect(notification.body.count == 256)
    }

    private func makeCore() -> CodexPluginCore {
        CodexPluginCore(correlation: .init(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }

    private func frame(
        tool: String = "request_user_input_async", sessionID: String = "session",
        callID: String = "call", event: String = "PreToolUse", subagent: Bool = false,
        questions: [String] = ["Which directory should I use?"]
    ) throws -> IngressFrame {
        let textKey = tool.hasSuffix("async") ? "title" : "question"
        var payload: [String: Any] = [
            "hook_event_name": event, "session_id": sessionID, "cwd": "/host/repo",
            "tool_name": tool, "tool_use_id": callID,
            "tool_input": ["questions": questions.map { [textKey: $0] }],
        ]
        if subagent {
            payload["agent_id"] = "child"
        }
        return try IngressFrame(pluginID: "codex", context: ["TMUX_PANE": "%7"], payload: JSONSerialization.data(withJSONObject: payload))
    }
}
