import CtrlxNetworking
import Testing
@testable import CtrlxFeature

@Suite("iOS new session sizing")
struct NewSessionSizingTests {
    private let phoneFit = ResizeTmuxPane(width: 65, height: 51, userInitiated: true)

    @Test("New installs and the legacy default enable automatic fit")
    func defaultMode() {
        #expect(NewSessionSizing.automaticFit(savedPreference: nil, width: 120, height: 40))
    }

    @Test("Legacy customized dimensions stay manual", arguments: [(80, 40), (120, 60), (160, 50)])
    func legacyCustomSize(size: (Int, Int)) {
        #expect(!NewSessionSizing.automaticFit(savedPreference: nil, width: size.0, height: size.1))
    }

    @Test("Saved mode wins over manual dimensions")
    func savedMode() {
        #expect(!NewSessionSizing.automaticFit(savedPreference: false, width: 120, height: 40))
        #expect(NewSessionSizing.automaticFit(savedPreference: true, width: 160, height: 50))
    }

    @Test("Automatic creation uses a safe fallback; manual creation uses exact settings")
    func creationGrid() {
        #expect(NewSessionSizing.creationGrid(automaticFit: true, width: 160, height: 50)
            == NewSessionSizing.fallbackGrid)
        #expect(NewSessionSizing.creationGrid(automaticFit: false, width: 160, height: 50)
            == .init(columns: 160, rows: 50))
    }

    @Test("Fit waits for window data and actual viewport measurement without a timer")
    func waitsForMeasurement() {
        var fit = initialFit()
        #expect(fit.takeRequest(isAvailable: true, paneIDs: nil, measuredRequest: phoneFit) == nil)
        #expect(fit.paneID == "%5")
        #expect(fit.takeRequest(isAvailable: true, paneIDs: ["%5"], measuredRequest: nil) == nil)
        #expect(fit.paneID == "%5")
        #expect(fit.takeRequest(isAvailable: true, paneIDs: ["%5"], measuredRequest: phoneFit) == phoneFit)
    }

    @Test("Only the newly created session on its Host can consume the fit")
    func scopedToCreation() {
        let fit = initialFit()
        #expect(fit.matches(hostID: "office", sessionName: "session-2"))
        #expect(!fit.matches(hostID: "home", sessionName: "session-2"))
        #expect(!fit.matches(hostID: "office", sessionName: "session"))
    }

    @Test("Dispatch consumes fit even if it fails; new viewports and re-entry cannot repeat it")
    func oneShot() {
        var fit = initialFit()
        #expect(fit.takeRequest(isAvailable: true, paneIDs: ["%5"], measuredRequest: phoneFit) == phoneFit)
        #expect(!fit.matches(hostID: "office", sessionName: "session-2"))
        let rotatedFit = ResizeTmuxPane(width: 130, height: 22, userInitiated: true)
        #expect(fit.takeRequest(isAvailable: true, paneIDs: ["%5"], measuredRequest: rotatedFit) == nil)
    }

    @Test("Unsupported or disconnected Hosts never get an automatic resize after reconnect")
    func unavailableHost() {
        var fit = initialFit()
        #expect(fit.takeRequest(isAvailable: false, paneIDs: ["%5"], measuredRequest: phoneFit) == nil)
        #expect(fit.paneID == nil)
        #expect(fit.takeRequest(isAvailable: true, paneIDs: ["%5"], measuredRequest: phoneFit) == nil)
    }

    @Test("A window switch, replacement pane or split cancels fit", arguments: [["%6"], ["%5", "%6"], []])
    func changedLayout(paneIDs: [String]) {
        var fit = initialFit()
        #expect(fit.takeRequest(isAvailable: true, paneIDs: paneIDs, measuredRequest: phoneFit) == nil)
        #expect(fit.paneID == nil)
        #expect(fit.takeRequest(isAvailable: true, paneIDs: ["%5"], measuredRequest: phoneFit) == nil)
    }

    @Test("Leaving or manually fitting consumes pending permission without sending")
    func cancellation() {
        var fit = initialFit()
        fit.cancel(hostID: "office", sessionName: "session-2")
        #expect(fit.takeRequest(isAvailable: true, paneIDs: ["%5"], measuredRequest: phoneFit) == nil)
    }

    @Test("Another destination cannot cancel this session's pending fit")
    func unrelatedDestination() {
        var fit = initialFit()
        fit.cancel(hostID: "home", sessionName: "session-2")
        fit.cancel(hostID: "office", sessionName: "session")
        #expect(fit.paneID == "%5")
        #expect(fit.takeRequest(isAvailable: true, paneIDs: ["%5"], measuredRequest: phoneFit) == phoneFit)
    }

    private func initialFit() -> NewSessionSizing.InitialFit {
        .init(hostID: "office", sessionName: "session-2", paneID: "%5")
    }
}
