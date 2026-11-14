import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentEventIdentityTests {
    @Test("A resident bridge can resume A after B without replacing its process", arguments: ["pi", "omp", "opencode"])
    func residentBridgeResumesRetiredConversation(plugin: String) {
        let source = PluginIngressPeer.Process(processID: 20, parentProcessID: 10, userID: 501, startSeconds: 20, startMicroseconds: 0)
        var evidence = AgentConversationEvidence(runtimeID: "runtime", conversationID: "A", latestSource: source, latestSequence: 1)
        let startB = PluginEvent(pluginID: plugin, sessionID: "B", state: .idle, conversationStarted: true, sourceSequence: 2)
        let resumeA = PluginEvent(pluginID: plugin, sessionID: "A", state: .idle, conversationStarted: true, sourceSequence: 3)
        let accepted1 = evidence.accept(startB, nativeConversationID: nil, source: source)
        #expect(accepted1)
        let accepted2 = evidence.accept(resumeA, nativeConversationID: nil, source: source)
        #expect(accepted2)
        #expect(evidence.conversationID == "A")
        let accepted3 = evidence.accept(.init(pluginID: plugin, sessionID: "A", state: .working, sourceSequence: 4), nativeConversationID: nil, source: source)
        #expect(accepted3)
        let accepted4 = evidence.accept(.init(pluginID: plugin, sessionID: "A", state: .doneWorking(summary: "Done"), sourceSequence: 5), nativeConversationID: nil, source: source)
        #expect(accepted4)
        // Neither a replay nor a stripped counter may rewind state, even for A.
        let accepted5 = evidence.accept(startB, nativeConversationID: nil, source: source)
        #expect(!accepted5)
        let accepted6 = evidence.accept(resumeA, nativeConversationID: nil, source: source)
        #expect(!accepted6)
        var missing = resumeA
        missing.sourceSequence = nil
        let accepted7 = evidence.accept(missing, nativeConversationID: nil, source: source)
        #expect(!accepted7)
        // A newer ordinary event still cannot switch to a retired conversation.
        let accepted8 = evidence.accept(.init(pluginID: plugin, sessionID: "B", state: .working, sourceSequence: 6), nativeConversationID: nil, source: source)
        #expect(!accepted8)
        #expect(evidence.conversationID == "A" && evidence.latestSequence == 5)
    }

    @Test("A claimed sequence is scoped to the authenticated sender")
    func sequenceRequiresMatchingKernelSource() {
        let source = PluginIngressPeer.Process(processID: 20, parentProcessID: 10, userID: 501, startSeconds: 20, startMicroseconds: 0)
        var evidence = AgentConversationEvidence(runtimeID: "runtime", conversationID: "B", retired: ["A"], latestSource: source, latestSequence: 2)
        let event = PluginEvent(pluginID: "pi", sessionID: "A", state: .idle, conversationStarted: true, sourceSequence: 100)
        let accepted9 = evidence.accept(event, nativeConversationID: nil)
        #expect(!accepted9)
        let other = PluginIngressPeer.Process(processID: 21, parentProcessID: 10, userID: 501, startSeconds: 20, startMicroseconds: 0)
        let accepted10 = evidence.accept(event, nativeConversationID: nil, source: other)
        #expect(!accepted10)
        let accepted11 = evidence.accept(event, nativeConversationID: "B", source: source)
        #expect(!accepted11)
        #expect(evidence.conversationID == "B")
    }

    @Test("Sequence is optional on the wire for existing native hooks")
    func eventSequenceWireCompatibility() throws {
        let legacy = Data(#"{"pluginID":"pi","sessionID":"A","appActions":[],"conversationStarted":true}"#.utf8)
        var event = try JSONDecoder().decode(PluginEvent.self, from: legacy)
        #expect(event.sourceSequence == nil)
        event.sourceSequence = 42
        #expect(try JSONDecoder().decode(PluginEvent.self, from: JSONEncoder().encode(event)) == event)
    }

    @Test("A fresh SessionStart cannot contradict the verified current writer")
    func nativeWriterOverridesHookClaims() {
        let source = PluginIngressPeer.Process(processID: 20, parentProcessID: 10, userID: 501, startSeconds: 20, startMicroseconds: 0)
        var evidence = AgentConversationEvidence(runtimeID: "runtime", conversationID: "current")
        let event = PluginEvent(pluginID: "codex", sessionID: "old", state: .working, conversationStarted: true)
        let accepted = evidence.accept(event, nativeConversationID: "current", source: source)
        #expect(!accepted)
        #expect(evidence.conversationID == "current" && evidence.retired.isEmpty)
    }

    @Test
    func conversationChangesRequireNativeEvidenceAndRetiredEventsCannotRewind() {
        var evidence = AgentConversationEvidence(runtimeID: "process", conversationID: "ses_old")
        let ordinary = PluginEvent(pluginID: "opencode", sessionID: "ses_new", state: .working)
        let ordinaryAccepted = evidence.accept(ordinary, nativeConversationID: nil)
        #expect(!ordinaryAccepted)
        var started = ordinary
        started.conversationStarted = true
        let startAccepted = evidence.accept(started, nativeConversationID: nil)
        #expect(startAccepted)
        #expect(evidence.conversationID == "ses_new")
        let late = PluginEvent(pluginID: "opencode", sessionID: "ses_old", state: .working, conversationStarted: true)
        let lateAccepted = evidence.accept(late, nativeConversationID: nil)
        #expect(!lateAccepted)
        #expect(evidence.conversationID == "ses_new")
        // Independent native ownership proof allows an explicit resume of an old conversation.
        let resumeAccepted = evidence.accept(late, nativeConversationID: late.sessionID)
        #expect(resumeAccepted)
        #expect(evidence.conversationID == "ses_old")
    }

    @Test
    func delayedHookCannotIntroduceAnUnknownOlderConversation() {
        func process(_ seconds: UInt64) -> PluginIngressPeer.Process {
            .init(processID: 20, parentProcessID: 10, userID: 501, startSeconds: seconds, startMicroseconds: 0)
        }
        var evidence = AgentConversationEvidence(runtimeID: "runtime", conversationID: "current", latestSource: process(20))
        let old = PluginEvent(pluginID: "claude-code", sessionID: "older", state: .working, conversationStarted: true)
        let accepted = evidence.accept(old, nativeConversationID: nil, source: process(10))
        #expect(!accepted && evidence.conversationID == "current")
    }

    @Test
    func nativeResumeNeedsANewerAuthenticatedHook() {
        func process(_ seconds: UInt64) -> PluginIngressPeer.Process {
            .init(processID: Int32(seconds), parentProcessID: 1, userID: 501, startSeconds: seconds, startMicroseconds: 0)
        }
        var evidence = AgentConversationEvidence(runtimeID: "live", conversationID: "new", retired: ["old"], latestSource: process(20))
        let resumed = PluginEvent(pluginID: "claude-code", sessionID: "old", state: .idle, conversationStarted: true)
        let stale = evidence.accept(resumed, nativeConversationID: nil, source: process(10))
        #expect(!stale)
        let fresh = evidence.accept(resumed, nativeConversationID: nil, source: process(30))
        #expect(fresh && evidence.conversationID == "old")
        let late = PluginEvent(pluginID: "claude-code", sessionID: "new", state: .working, conversationStarted: true)
        let rewound = evidence.accept(late, nativeConversationID: nil, source: process(20))
        #expect(!rewound)
    }

    @Test(arguments: ["plugin", "runtime", "conversation", "server", "pane", "exit"])
    func sinkRechecksTheExactRunningConversation(change: String) throws {
        let workspace = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        var pane = PaneState(paneId: "%1", sessionName: "work", agentSession: .init(paneId: "%1", pluginID: "codex"), claudeSessionID: "conversation")
        pane.workspaceIdentity = workspace
        pane.agentSession?.processRuntimeID = "runtime"
        let binding = try #require(AgentProcessBinding(paneID: "%1", workspacePane: workspace, detected: .init(path: "/tmp", pluginID: "codex", processIDs: ["123"]), runtimeID: { _ in "runtime" }))
        let context = AgentEventContext(binding: binding, conversationID: "conversation")
        #expect(context.matches(pane, runtimeID: { _ in "runtime" }))
        switch change {
        case "plugin": pane.agentSession?.pluginID = "claude-code"
        case "runtime": pane.agentSession?.processRuntimeID = "successor"
        case "conversation": pane.claudeSessionID = "new"
        case "server": pane.workspaceIdentity?.serverID = "new-server"
        case "pane": pane.workspaceIdentity?.paneID = UUID()
        default: break
        }
        #expect(!context.matches(pane, runtimeID: { _ in change == "exit" ? nil : "runtime" }))
    }
}
