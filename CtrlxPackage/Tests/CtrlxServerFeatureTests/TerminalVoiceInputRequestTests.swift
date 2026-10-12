import CtrlxCommon
import CtrlxNetworking
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite("Mac voice input destination")
struct TerminalVoiceInputRequestTests {
    @MainActor
    final private class Sink {
        var batches: [[TmuxKey]] = []
        var isVisible = true
        func endpoint(host: String? = nil) -> TerminalQuickActionEndpoint {
            let endpoint = TerminalQuickActionEndpoint(
                hostID: host, paneID: "%1", isVisible: { [self] in isVisible },
                enqueue: { [self] in batches.append($0) }
            )
            endpoint.isReady = true
            return endpoint
        }
    }

    private func context(
        _ endpoint: TerminalQuickActionEndpoint,
        connected: Bool = true,
        editor: Bool = false,
        form: Bool = false
    ) -> TerminalPhraseContext {
        TerminalPhraseContext(
            hostID: endpoint.hostID ?? "local", paneID: endpoint.paneID,
            inputRevision: endpoint.inputRevision, isConnected: connected,
            isInputAvailable: endpoint.isReady && endpoint.isAvailable,
            hasExternalEditor: editor, hasBlockingForm: form
        )
    }

    @Test("Local and remote voice inserts one literal batch without Return", arguments: [nil, "office"] as [String?])
    func insertsOnce(host: String?) throws {
        let sink = Sink(), router = TerminalQuickActionRouter()
        let endpoint = sink.endpoint(host: host)
        router.focus(endpoint)
        let request = try #require(TerminalVoiceInputRequest(router: router, context: context(endpoint)))
        #expect(request.insert("检查\n并构建", router: router, context: context(endpoint)))
        #expect(!request.insert("duplicate", router: router, context: context(endpoint)))
        #expect(sink.batches == [[.text("检查 并构建")]])
    }

    @Test("Focus away and back cannot revive a voice result, including identical remote pane IDs")
    func changedFocus() throws {
        let sink = Sink(), router = TerminalQuickActionRouter()
        let local = sink.endpoint(), remote = sink.endpoint(host: "office")
        router.focus(local)
        let request = try #require(TerminalVoiceInputRequest(router: router, context: context(local)))
        router.focus(remote)
        #expect(!request.insert("wrong host", router: router, context: context(remote)))
        router.focus(local)
        #expect(!request.insert("stale result", router: router, context: context(local)))
        #expect(sink.batches.isEmpty)
    }

    @Test("Typing, disconnect, remount, editor, questions and readiness changes block insertion", arguments: 0..<7)
    func invalidatedResult(change: Int) throws {
        let sink = Sink(), router = TerminalQuickActionRouter()
        let endpoint = sink.endpoint()
        router.focus(endpoint)
        let request = try #require(TerminalVoiceInputRequest(router: router, context: context(endpoint)))
        if change == 0 { endpoint.recordInput() }
        if change == 2 { endpoint.invalidate() }
        if change == 5 { endpoint.isReady = false }
        if change == 6 { sink.isVisible = false }
        let current = context(endpoint, connected: change != 1, editor: change == 3, form: change == 4)
        #expect(!request.insert("must not insert", router: router, context: current))
        #expect(sink.batches.isEmpty)
    }

    @Test("Unavailable panes cannot start and empty recognition never inserts input")
    func emptyOrUnavailable() throws {
        let sink = Sink(), router = TerminalQuickActionRouter()
        let endpoint = sink.endpoint()
        router.focus(endpoint)
        #expect(TerminalVoiceInputRequest(router: router, context: context(endpoint, connected: false)) == nil)
        let request = try #require(TerminalVoiceInputRequest(router: router, context: context(endpoint)))
        #expect(!request.insert(" \n ", router: router, context: context(endpoint)))
        #expect(sink.batches.isEmpty)
    }
}
