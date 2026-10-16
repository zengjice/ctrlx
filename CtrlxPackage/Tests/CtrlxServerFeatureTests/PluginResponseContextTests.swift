import ConcurrencyExtras
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

struct PluginResponseContextTests {
    private func pane() -> PaneState {
        var pane = PaneState(paneId: "%7", agentSession: .init(paneId: "%7", pluginID: "echo", state: .awaitingPermission(.init(title: "Test", description: "Test"), requestID: "request")), workspaceIdentity: .init(serverID: "100:1", sessionID: UUID(), windowID: UUID(), paneID: UUID()))
        pane.claudeSessionID = "conversation"
        return pane
    }

    @Test("A response rejects replacement processes and retracted forms, but follows a live pane move")
    func staleTargets() throws {
        let original = pane()
        let context = try PluginResponseContext(pluginID: "echo", pane: original, requestID: "request")
        var moved = original
        moved.workspaceIdentity?.sessionID = UUID()
        moved.workspaceIdentity?.windowID = UUID()
        try context.validate(pluginID: "echo", paneID: "%7", pane: moved)
        for mutation in 0..<5 {
            var retired = original
            switch mutation {
            case 0: retired.workspaceIdentity?.serverID = "200:2"
            case 1: retired.workspaceIdentity?.paneID = UUID()
            case 2: retired.claudeSessionID = "another-conversation"
            case 3: retired.agentSession?.state = .working
            default: retired.agentSession = nil
            }
            #expect(throws: (any Error).self) { try context.validate(pluginID: "echo", paneID: "%7", pane: retired) }
        }
        #expect(throws: (any Error).self) { try context.validate(pluginID: "another-plugin", paneID: "%7", pane: original) }
        #expect(throws: (any Error).self) { try context.validate(pluginID: "echo", paneID: "%8", pane: original) }
        #expect(throws: (any Error).self) { try context.validate(pluginID: "echo", paneID: "%7", pane: nil) }
        var expected = try #require(original.workspaceIdentity)
        expected.serverID = "1:1"
        #expect(throws: (any Error).self) { try PluginResponseContext(pluginID: "echo", pane: original, requestID: "request", expectedWorkspacePane: expected) }
    }

    @Test("An in-process core retains the captured response target through actor delivery")
    func nativeCore() async throws {
        let pane = pane()
        let context = try PluginResponseContext(pluginID: "echo", pane: pane, requestID: "request")
        let calls = LockIsolated(0)
        let logRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-response-\(UUID())")
        defer { try? FileManager.default.removeItem(at: logRoot) }
        let host = LivePluginHost(pluginID: "echo", dispatcher: PluginEventDispatcher(), logSink: PluginLogSink(logFileURL: logRoot.appendingPathComponent("test.log")), onSendText: { plugin, target, text in
            calls.withValue { $0 += 1 }
            let inherited = try? #require(PluginResponseContext.current)
            #expect(inherited?.workspaceIdentity == context.workspaceIdentity)
            #expect(inherited?.requestID == "request")
            #expect(text == "feedback")
            #expect(throws: Never.self) { try inherited?.validate(pluginID: plugin, paneID: target, pane: pane) }
        })
        let core = EchoPluginCore()
        try await core.initialize(.init(pluginRoot: logRoot, stateDir: logRoot, appVersion: "3.0.75", settings: Data(), marketplaceSource: logRoot), host: host)
        await PluginResponseContext.$current.withValue(context) {
            await core.deliverResponse(sessionID: "%7", requestID: "request", .permission(decision: .denyWithFeedback("feedback"), appliedSuggestionID: nil))
        }
        #expect(PluginResponseContext.current == nil)
        #expect(calls.value == 1)
        await core.shutdown()
    }
}
