import CtrlxCommon
import CtrlxNetworking
import Testing
@testable import CtrlxFeature

@MainActor
@Suite("iOS new session creation reconciliation")
struct NewSessionCreationTests {
    @Test("Snapshot before or after the reply reaches the same one-shot destination", arguments: [true, false])
    func arrivalOrder(snapshotFirst: Bool) throws {
        let store = SessionStore()
        var creation = NewSessionCreation()
        let revision = creation.begin(hostID: "office", automaticFit: true)
        if snapshotFirst { pushSnapshot(to: store) }
        #expect(creation.takeDestination(paneStates: store.paneStates, isConnected: true) == nil)
        let acceptedReply = creation.receivePaneID("%5", revision: revision)
        #expect(acceptedReply)

        if !snapshotFirst {
            #expect(creation.takeDestination(paneStates: store.paneStates, isConnected: true) == nil)
            #expect(creation.paneID == "%5")
            pushSnapshot(to: store)
        }

        let resolved = creation.takeDestination(paneStates: store.paneStates, isConnected: true)
        let destination = try #require(resolved)
        #expect(destination.hostID == "office")
        // Use the actual unique Host name, not the requested base name.
        #expect(destination.sessionName == "codex-2")
        var fit = try #require(destination.initialFit)
        let request = ResizeTmuxPane(width: 65, height: 51, userInitiated: true)
        #expect(fit.takeRequest(isAvailable: true, paneIDs: ["%5"], measuredRequest: nil) == nil)
        #expect(fit.takeRequest(isAvailable: true, paneIDs: ["%5"], measuredRequest: request) == request)
        #expect(fit.takeRequest(isAvailable: true, paneIDs: ["%5"], measuredRequest: request) == nil)
        #expect(creation.takeDestination(paneStates: store.paneStates, isConnected: true) == nil)
    }

    @Test("Manual sizing still navigates after a late snapshot but never grants a fit")
    func manualSize() throws {
        let store = SessionStore()
        var creation = NewSessionCreation()
        let revision = creation.begin(hostID: "office", automaticFit: false)
        creation.receivePaneID("%5", revision: revision)
        #expect(creation.takeDestination(paneStates: store.paneStates, isConnected: true) == nil)
        pushSnapshot(to: store)
        let resolved = creation.takeDestination(paneStates: store.paneStates, isConnected: true)
        let destination = try #require(resolved)
        #expect(destination.sessionName == "codex-2")
        #expect(destination.initialFit == nil)
    }

    @Test("Another Host's identical pane ID and unrelated panes cannot resolve creation")
    func exactIdentity() throws {
        let store = SessionStore()
        var creation = NewSessionCreation()
        let revision = creation.begin(hostID: "office", automaticFit: true)
        creation.receivePaneID("%5", revision: revision)
        pushSnapshot(to: store, hostID: "home")
        pushSnapshot(to: store, paneID: "%6")
        #expect(creation.takeDestination(paneStates: store.paneStates, isConnected: true) == nil)
        #expect(creation.paneID == "%5")
        pushSnapshot(to: store)
        let resolved = creation.takeDestination(paneStates: store.paneStates, isConnected: true)
        let destination = try #require(resolved)
        #expect(destination.hostID == "office")
        #expect(destination.initialFit?.paneID == "%5")
    }

    @Test("Leaving, another session or picker dismissal cancels before or after the reply", arguments: [true, false])
    func cancellation(replyFirst: Bool) {
        let store = SessionStore()
        var creation = NewSessionCreation()
        let revision = creation.begin(hostID: "office", automaticFit: true)
        if replyFirst { creation.receivePaneID("%5", revision: revision) }
        creation.cancel()
        let acceptedReply = creation.receivePaneID("%5", revision: revision)
        #expect(!acceptedReply)
        pushSnapshot(to: store)
        #expect(creation.takeDestination(paneStates: store.paneStates, isConnected: true) == nil)
    }

    @Test("Disconnect while waiting cancels routing even if a snapshot arrives after reconnect", arguments: [true, false])
    func disconnect(replyFirst: Bool) {
        let store = SessionStore()
        var creation = NewSessionCreation()
        let revision = creation.begin(hostID: "office", automaticFit: true)
        if replyFirst { creation.receivePaneID("%5", revision: revision) }
        #expect(creation.takeDestination(paneStates: store.paneStates, isConnected: false) == nil)
        let acceptedReply = creation.receivePaneID("%5", revision: revision)
        #expect(!acceptedReply)
        pushSnapshot(to: store)
        #expect(creation.takeDestination(paneStates: store.paneStates, isConnected: true) == nil)
    }

    @Test("An old reply cannot replace a newer Host's creation and captured sizing preference")
    func staleReply() throws {
        let store = SessionStore()
        var creation = NewSessionCreation()
        let oldRevision = creation.begin(hostID: "office", automaticFit: true)
        let revision = creation.begin(hostID: "home", automaticFit: false)
        let acceptedOldReply = creation.receivePaneID("%5", revision: oldRevision)
        let acceptedReply = creation.receivePaneID("%6", revision: revision)
        #expect(!acceptedOldReply)
        #expect(acceptedReply)
        pushSnapshot(to: store)
        #expect(creation.takeDestination(paneStates: store.paneStates, isConnected: true) == nil)
        pushSnapshot(to: store, hostID: "home", paneID: "%6")
        let resolved = creation.takeDestination(paneStates: store.paneStates, isConnected: true)
        let destination = try #require(resolved)
        #expect(destination.hostID == "home")
        #expect(destination.initialFit == nil)
    }

    private func pushSnapshot(to store: SessionStore, hostID: String = "office", paneID: String = "%5") {
        let pane = PaneState(paneId: paneID, sessionName: "codex-2", width: 120, height: 40)
        store.handleStateUpdate(SessionStateMessage(pairId: hostID, paneStates: [paneID: pane]))
    }
}
