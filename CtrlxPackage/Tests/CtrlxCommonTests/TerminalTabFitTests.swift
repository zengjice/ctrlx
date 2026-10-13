import CtrlxCommon
import CtrlxNetworking
import Testing

@Suite("Terminal tab automatic fit")
struct TerminalTabFitTests {
    private let first = TerminalTabFit.Target(hostID: "host-a", sessionName: "dev", windowID: "@1")
    private let second = TerminalTabFit.Target(hostID: "host-a", sessionName: "dev", windowID: "@2")
    private let grid = ResizeTmuxPane(width: 100, height: 35, userInitiated: true)

    @Test("Waits for the requested remote window, presentation and measurement")
    func waitsForReadyViewport() {
        var fit = TerminalTabFit()
        fit.request(second)
        #expect(take(&fit, current: first) == nil)
        #expect(fit.takeRequest(for: second, isAvailable: true, isPresentationReady: true, measuredRequest: nil) == nil)
        #expect(fit.takeRequest(for: second, isAvailable: true, isPresentationReady: false, measuredRequest: grid) == nil)
        #expect(take(&fit, current: second) == grid)
    }

    @Test("Snapshots and geometry changes cannot fit again, even after a failed send")
    func consumesBeforeDispatch() {
        var fit = TerminalTabFit()
        fit.request(first)
        #expect(take(&fit, current: first) == grid)
        let changedGrid = ResizeTmuxPane(width: 80, height: 24, userInitiated: true)
        #expect(fit.takeRequest(for: first, isAvailable: true, isPresentationReady: true, measuredRequest: changedGrid) == nil)
        #expect(take(&fit, current: second) == nil)
    }

    @Test("Explicitly returning to the same tab uses its current viewport")
    func fitsOnEachEntry() {
        var fit = TerminalTabFit()
        fit.request(first)
        #expect(take(&fit, current: first) == grid)
        fit.request(second)
        #expect(take(&fit, current: second) == grid)
        fit.request(first)
        let changedGrid = ResizeTmuxPane(width: 90, height: 30, userInitiated: true)
        #expect(fit.takeRequest(for: first, isAvailable: true, isPresentationReady: true, measuredRequest: changedGrid) == changedGrid)
    }

    @Test("Session entry waits for its window to arrive")
    func resolvesInitialWindow() {
        var fit = TerminalTabFit()
        let unresolved = TerminalTabFit.Target(hostID: "host-a", sessionName: "dev")
        fit.request(unresolved)
        #expect(take(&fit, current: unresolved) == nil)
        #expect(take(&fit, current: first) == grid)
        #expect(take(&fit, current: second) == nil)
    }

    @Test("Local and remote Hosts with identical tmux IDs stay isolated", arguments: [nil, "host-b"] as [String?])
    func rejectsDifferentHost(hostID: String?) {
        var fit = TerminalTabFit()
        fit.request(first)
        #expect(take(&fit, current: .init(hostID: hostID, sessionName: "dev", windowID: "@1")) == nil)
        #expect(take(&fit, current: first) == nil)
    }

    @Test("Leaving the session cancels a pending fit")
    func rejectsDifferentSession() {
        var fit = TerminalTabFit()
        fit.request(first)
        #expect(take(&fit, current: .init(hostID: "host-a", sessionName: "other", windowID: "@1")) == nil)
        #expect(take(&fit, current: first) == nil)
    }

    @Test("Offline or unsupported Hosts consume the request without a reconnect retry")
    func unavailableHostDoesNotRetry() {
        var fit = TerminalTabFit()
        fit.request(first)
        #expect(fit.takeRequest(for: first, isAvailable: false, isPresentationReady: true, measuredRequest: grid) == nil)
        #expect(take(&fit, current: first) == nil)
        fit.request(first)
        #expect(take(&fit, current: first) == grid)
    }

    @Test("Manual fit, hiding the terminal or leaving the page cancels pending work")
    func cancellation() {
        var fit = TerminalTabFit()
        fit.request(first)
        fit.cancel()
        #expect(take(&fit, current: first) == nil)
    }

    @Test("Rapid tab selection replaces the pending target")
    func latestSelectionWins() {
        var fit = TerminalTabFit()
        fit.request(first)
        fit.request(second)
        #expect(take(&fit, current: first) == nil)
        #expect(take(&fit, current: second) == grid)
    }

    private func take(_ fit: inout TerminalTabFit, current: TerminalTabFit.Target) -> ResizeTmuxPane? {
        fit.takeRequest(for: current, isAvailable: true, isPresentationReady: true, measuredRequest: grid)
    }
}
