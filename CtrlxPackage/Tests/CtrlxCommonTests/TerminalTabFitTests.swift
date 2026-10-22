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
        #expect(fit.takeRequest(for: first, isAvailable: false, isPresentationReady: true, measuredRequest: grid) == nil)
        #expect(take(&fit, current: first) == nil)
        #expect(take(&fit, current: second) == nil)
    }

    @Test("Returning to a tab or foreground activation uses the current viewport")
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

    @Test("Pending entry waits for reconnect, Fit capability and a ready viewport")
    func unavailableHostWaits() {
        var fit = TerminalTabFit()
        fit.request(first)
        #expect(fit.takeRequest(for: first, isAvailable: false, isPresentationReady: true, measuredRequest: grid) == nil)
        let withoutSnapshot = TerminalTabFit.Target(hostID: first.hostID, sessionName: first.sessionName)
        #expect(fit.takeRequest(for: withoutSnapshot, isAvailable: false, isPresentationReady: true, measuredRequest: nil) == nil)
        #expect(fit.target == first)
        #expect(fit.takeRequest(for: first, isAvailable: true, isPresentationReady: false, measuredRequest: grid) == nil)
        #expect(take(&fit, current: first) == grid)
        #expect(take(&fit, current: first) == nil)
    }

    @Test("Manual fit, hiding the terminal or leaving the page cancels pending work")
    func cancellation() {
        var fit = TerminalTabFit()
        fit.request(first)
        fit.cancel()
        #expect(take(&fit, current: first) == nil)
    }

    @Test("Switching tabs while offline replaces the target before reconnect")
    func latestSelectionWins() {
        var fit = TerminalTabFit()
        fit.request(first)
        #expect(fit.takeRequest(for: first, isAvailable: false, isPresentationReady: true, measuredRequest: grid) == nil)
        fit.request(second)
        #expect(take(&fit, current: first) == nil)
        #expect(take(&fit, current: second) == grid)
    }

    private func take(_ fit: inout TerminalTabFit, current: TerminalTabFit.Target) -> ResizeTmuxPane? {
        fit.takeRequest(for: current, isAvailable: true, isPresentationReady: true, measuredRequest: grid)
    }

    @Test("A content click fits a changed viewport once; geometry alone never does", arguments: [nil, "host-a"] as [String?])
    func contentClickAfterResize(hostID: String?) {
        let target = TerminalTabFit.Target(hostID: hostID, sessionName: "dev", windowID: "@1")
        var fit = TerminalTabFit()
        fit.request(target)
        #expect(take(&fit, current: target) == grid)
        fit.recordFit(for: target, request: grid)
        fit.requestAfterViewportChange(target, measuredRequest: grid)
        #expect(take(&fit, current: target) == nil)

        let larger = ResizeTmuxPane(width: 160, height: 50, userInitiated: true)
        #expect(fit.takeRequest(for: target, isAvailable: true, isPresentationReady: true, measuredRequest: larger) == nil)
        fit.requestAfterViewportChange(target, measuredRequest: larger)
        #expect(fit.takeRequest(for: target, isAvailable: true, isPresentationReady: true, measuredRequest: larger) == larger)
        fit.recordFit(for: target, request: larger)
        fit.requestAfterViewportChange(target, measuredRequest: larger)
        #expect(take(&fit, current: target) == nil)

        fit.requestAfterViewportChange(target, measuredRequest: grid)
        #expect(take(&fit, current: target) == grid)
    }

    @Test("Manual fit updates the click baseline without suppressing later foreground Fit")
    func manualFitThenClick() {
        var fit = TerminalTabFit()
        fit.recordFit(for: first, request: grid)
        fit.requestAfterViewportChange(first, measuredRequest: grid)
        #expect(take(&fit, current: first) == nil)
        fit.request(first)
        #expect(take(&fit, current: first) == grid)
    }

    @Test("The same terminal fits on focus after moving right and back left", arguments: [nil, "host-a"] as [String?])
    func splitFocusRoundTrip(hostID: String?) {
        let target = TerminalTabFit.Target(hostID: hostID, sessionName: "dev", windowID: "@1")
        var fit = TerminalTabFit()
        let full = ResizeTmuxPane(width: 180, height: 40, userInitiated: true)
        let right = ResizeTmuxPane(width: 85, height: 40, userInitiated: true)
        fit.recordFit(for: target, request: full)

        for viewport in [right, full] {
            // Moving the tab/receiving shared layout alone does not own a resize.
            #expect(fit.takeRequest(for: target, isAvailable: true, isPresentationReady: true, measuredRequest: viewport) == nil)
            // Native focus can move to a new view without changing the tmux window ID.
            fit.requestAfterViewportChange(target, measuredRequest: viewport)
            #expect(fit.takeRequest(for: target, isAvailable: true, isPresentationReady: true, measuredRequest: viewport) == viewport)
            fit.recordFit(for: target, request: viewport)
            fit.requestAfterViewportChange(target, measuredRequest: viewport)
            #expect(fit.target == nil)
        }
    }

    @Test("A failed automatic Fit stays consumed until a new click, which can retry", arguments: [nil, "host-a"] as [String?])
    func clickRetriesFailedFit(hostID: String?) {
        let target = TerminalTabFit.Target(hostID: hostID, sessionName: "dev", windowID: "@1")
        var fit = TerminalTabFit()
        fit.request(target)
        #expect(take(&fit, current: target) == grid)
        // Dispatch failed: no successful baseline, but geometry must not retry by itself.
        #expect(take(&fit, current: target) == nil)
        fit.requestAfterViewportChange(target, measuredRequest: grid)
        #expect(take(&fit, current: target) == grid)
        fit.recordFit(for: target, request: grid)
        fit.requestAfterViewportChange(target, measuredRequest: grid)
        #expect(take(&fit, current: target) == nil)
    }

    @Test("Click baselines stay separate across split tabs, Hosts and scenes")
    func independentClickBaselines() {
        var fit = TerminalTabFit()
        fit.recordFit(for: first, request: grid)
        let otherHost = TerminalTabFit.Target(hostID: "host-b", sessionName: "dev", windowID: "@1")
        for target in [second, otherHost] {
            fit.requestAfterViewportChange(target, measuredRequest: grid)
            #expect(take(&fit, current: target) == grid)
        }
        fit.requestAfterViewportChange(first, measuredRequest: grid)
        #expect(take(&fit, current: first) == nil)
        var detachedScene = TerminalTabFit()
        detachedScene.requestAfterViewportChange(first, measuredRequest: grid)
        #expect(take(&detachedScene, current: first) == grid)
    }
}
