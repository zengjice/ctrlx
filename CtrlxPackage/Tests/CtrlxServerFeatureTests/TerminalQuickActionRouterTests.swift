import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite("Mac terminal quick-action routing")
struct TerminalQuickActionRouterTests {
    @MainActor
    private final class Sink {
        var batches: [[TmuxKey]] = []
        var visible = true

        func endpoint(host: String? = nil, pane: String = "%1") -> TerminalQuickActionEndpoint {
            let endpoint = TerminalQuickActionEndpoint(
                hostID: host, paneID: pane, isVisible: { [self] in visible },
                enqueue: { [self] in batches.append($0) }
            )
            endpoint.isReady = true
            return endpoint
        }
    }

    @Test("The last focused pane wins, independent of tab order or host pane-ID collisions")
    func focusRouting() throws {
        let router = TerminalQuickActionRouter()
        let left = Sink(), right = Sink(), remote = Sink()
        let leftPane = left.endpoint()
        let rightPane = right.endpoint(pane: "%2")
        let remotePane = remote.endpoint(host: "host-b")
        router.focus(leftPane)
        let old = try #require(router.token)
        router.focus(rightPane)
        #expect(!router.send(AgentQuickCommand.status.keys, to: old))
        #expect(router.send(AgentQuickCommand.model.keys, to: try #require(router.token)))
        router.focus(remotePane)
        #expect(router.send(AgentQuickCommand.usage.keys, to: try #require(router.token)))
        #expect(left.batches.isEmpty)
        #expect(right.batches == [AgentQuickCommand.model.keys])
        #expect(remote.batches == [AgentQuickCommand.usage.keys])
    }

    @Test("Switching away and back or remounting the same pane never revives an old action")
    func staleFocus() throws {
        let router = TerminalQuickActionRouter()
        let sink = Sink()
        let first = sink.endpoint()
        router.focus(first)
        let old = try #require(router.token)
        router.focus(sink.endpoint(pane: "%2"))
        router.focus(first)
        #expect(!router.matches(old))
        router.focus(sink.endpoint())
        #expect(!router.send(AgentQuickCommand.status.keys, to: old))
        #expect(sink.batches.isEmpty)
    }

    @Test("Popover focus does not clear the target, but terminal typing invalidates its token")
    func draftChanged() throws {
        let router = TerminalQuickActionRouter()
        let sink = Sink()
        let endpoint = sink.endpoint()
        router.focus(endpoint)
        let captured = try #require(router.token)
        // Native popovers do not register as a new terminal endpoint.
        router.focus(endpoint)
        #expect(router.matches(captured))
        endpoint.recordInput()
        #expect(!router.send(AgentQuickCommand.status.keys, to: captured))
        #expect(sink.batches.isEmpty)
    }

    @Test("Closing a pane blocks sends synchronously, before deferred router cleanup")
    func dismantle() throws {
        let router = TerminalQuickActionRouter()
        let sink = Sink()
        let endpoint = sink.endpoint()
        router.focus(endpoint)
        let captured = try #require(router.token)
        endpoint.invalidate()
        #expect(!router.send(AgentQuickCommand.status.keys, to: captured))
        let next = sink.endpoint(pane: "%2")
        router.focus(next)
        router.retire(endpoint) // Late cleanup must not clear the new focus.
        #expect(router.active === next)
        router.focus(endpoint) // Dead views cannot steal the toolbar target.
        #expect(router.active === next)
    }

    @Test("Readiness changes do not prevent browsing; hidden or unavailable panes cannot send")
    func unavailable() throws {
        let router = TerminalQuickActionRouter()
        let sink = Sink()
        let endpoint = sink.endpoint()
        router.focus(endpoint)
        let captured = try #require(router.token)
        endpoint.isReady = false
        #expect(router.token == captured)
        #expect(!router.send(AgentQuickCommand.status.keys, to: captured))
        endpoint.isReady = true
        sink.visible = false
        #expect(!router.send(AgentQuickCommand.status.keys, to: captured))
        sink.visible = true
        #expect(router.send(AgentQuickCommand.status.keys, to: captured))
    }

    @Test("A phrase is one ordered batch, with one Return and no draft-clearing keys or duplicate submission")
    func atomicSubmission() throws {
        let router = TerminalQuickActionRouter()
        let sink = Sink()
        router.focus(sink.endpoint())
        let captured = try #require(router.token)
        let phrase = QuickPhrase(text: "继续检查 👩‍💻")
        #expect(router.send(phrase.keys, to: captured))
        #expect(!router.send(phrase.keys, to: captured))
        #expect(sink.batches == [[.text(phrase.text), .delay(200), .enter]])
    }

    @Test("Separate panes scenes cannot send through each other's endpoint token")
    func sceneIsolation() throws {
        let first = TerminalQuickActionRouter(), second = TerminalQuickActionRouter()
        let sink = Sink()
        first.focus(sink.endpoint())
        second.focus(sink.endpoint())
        #expect(!second.send(AgentQuickCommand.status.keys, to: try #require(first.token)))
        #expect(sink.batches.isEmpty)
    }

    @Test("Toolbar input joins the keyboard coalescer without merging either neighboring batch")
    func coalescerOrdering() {
        let sink = Sink()
        let coalescer = KeystrokeCoalescer { sink.batches.append($0.keys) }
        let router = TerminalQuickActionRouter()
        let endpoint = TerminalQuickActionEndpoint(
            hostID: nil, paneID: "%1", isVisible: { true },
            enqueue: { coalescer.enqueueImmediately($0) }
        )
        endpoint.isReady = true
        router.focus(endpoint)
        coalescer.enqueue([.escape])
        coalescer.enqueue([.backspace])
        let keys = AgentQuickCommand.status.keys
        if let captured = router.token {
            #expect(router.send(keys, to: captured))
        } else {
            Issue.record("Focused terminal must provide an input token")
        }
        coalescer.enqueue([.text("after")])
        coalescer.flushPending()
        #expect(sink.batches == [[.escape, .backspace], keys, [.text("after")]])
        #expect(!coalescer.hasPendingKeys)
    }
}
