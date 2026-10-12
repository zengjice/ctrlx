import CtrlxCommon
import CtrlxNetworking
import Testing
@testable import CtrlxFeature

@MainActor
@Suite("iOS new window creation sizing")
struct NewWindowCreationTests {
    private let phoneFit = ResizeTmuxPane(width: 65, height: 51, userInitiated: true)

    @Test("Terminal and Agent windows follow and fit the returned pane in either arrival order",
          arguments: [true, false], [nil, "codex", "claude-code"] as [String?])
    func arrivalOrder(snapshotFirst: Bool, agent: String?) throws {
        let store = SessionStore()
        pushSnapshot(to: store, includeNewWindow: false, agent: agent)
        let source = try #require(store.windows(for: "office").first)
        var creation = NewSessionCreation()
        let revision = creation.begin(hostID: "office", automaticFit: true)
        if snapshotFirst { pushSnapshot(to: store, agent: agent) }
        #expect(creation.takeWindowDestination(
            selectedPaneID: "%1", paneStates: store.paneStates, isConnected: true
        ) == nil)
        creation.receivePaneID("%2", revision: revision)

        if !snapshotFirst {
            #expect(selection(creation, store: store, selectedWindowID: source.id) == .unchanged)
            #expect(creation.takeWindowDestination(
                selectedPaneID: "%1", paneStates: store.paneStates, isConnected: true
            ) == nil)
            #expect(creation.paneID == "%2")
            pushSnapshot(to: store, agent: agent)
        }

        let decision = selection(creation, store: store, selectedWindowID: source.id)
        guard case let .select(windowID, paneID) = decision else {
            Issue.record("The created window must be selected before fitting")
            return
        }
        let destination = creation.takeWindowDestination(
            selectedPaneID: paneID, paneStates: store.paneStates, isConnected: true
        )
        var fit = try #require(destination?.initialFit)
        let window = try #require(store.window(id: windowID, hostId: "office"))
        #expect(window.stableId == "@2")
        #expect(window.stableId != source.stableId)
        #expect(fit.matches(hostID: "office", sessionName: "work"))
        #expect(fit.takeRequest(isAvailable: true, paneIDs: window.panes.map(\.paneId), measuredRequest: nil) == nil)
        #expect(fit.takeRequest(isAvailable: true, paneIDs: window.panes.map(\.paneId), measuredRequest: phoneFit) == phoneFit)
        #expect(fit.takeRequest(isAvailable: true, paneIDs: window.panes.map(\.paneId), measuredRequest: phoneFit) == nil)
        #expect(creation.takeWindowDestination(
            selectedPaneID: paneID, paneStates: store.paneStates, isConnected: true
        ) == nil)
    }

    @Test("A cached new pane cannot grant a fit while the source window is displayed")
    func waitsForSelection() throws {
        let store = SessionStore()
        pushSnapshot(to: store)
        var creation = NewSessionCreation()
        let revision = creation.begin(hostID: "office", automaticFit: true)
        creation.receivePaneID("%2", revision: revision)
        for selectedPaneID in [nil, "%1", "%missing"] {
            #expect(creation.takeWindowDestination(
                selectedPaneID: selectedPaneID, paneStates: store.paneStates, isConnected: true
            ) == nil)
            #expect(creation.paneID == "%2")
        }
        let destination = creation.takeWindowDestination(
            selectedPaneID: "%2", paneStates: store.paneStates, isConnected: true
        )
        #expect(destination?.initialFit?.paneID == "%2")
    }

    @Test("Automatic sizing disabled still selects the new window without changing its Host dimensions")
    func manualSizing() throws {
        let store = SessionStore()
        var creation = NewSessionCreation()
        let revision = creation.begin(hostID: "office", automaticFit: false)
        creation.receivePaneID("%2", revision: revision)
        pushSnapshot(to: store)
        let resolved = creation.takeWindowDestination(
            selectedPaneID: "%2", paneStates: store.paneStates, isConnected: true
        )
        let destination = try #require(resolved)
        #expect(destination.initialFit == nil)
        #expect(store.paneState(for: "%2", hostId: "office")?.width == 200)
        #expect(store.paneState(for: "%2", hostId: "office")?.height == 60)
    }

    @Test("A measured new window waits through sheet dismissal without consuming fit")
    func waitsForSheetDismissal() throws {
        let store = SessionStore()
        pushSnapshot(to: store)
        var creation = NewSessionCreation()
        let revision = creation.begin(hostID: "office", automaticFit: true)
        creation.receivePaneID("%2", revision: revision)
        let destination = creation.takeWindowDestination(
            selectedPaneID: "%2", paneStates: store.paneStates, isConnected: true
        )
        var fit = try #require(destination?.initialFit)
        for _ in 0..<3 {
            #expect(fit.takeRequest(
                isAvailable: true, paneIDs: ["%2"], measuredRequest: phoneFit, isPresentationReady: false
            ) == nil)
            #expect(fit.paneID == "%2")
        }
        #expect(fit.takeRequest(
            isAvailable: true, paneIDs: ["%2"], measuredRequest: phoneFit, isPresentationReady: true
        ) == phoneFit)
        #expect(fit.takeRequest(isAvailable: true, paneIDs: ["%2"], measuredRequest: phoneFit) == nil)
    }

    @Test("Manual actions, leaving or disconnecting cancel follow-up before or after the reply", arguments: [true, false])
    func cancellation(replyFirst: Bool) {
        let store = SessionStore()
        var creation = NewSessionCreation()
        let revision = creation.begin(hostID: "office", automaticFit: true)
        if replyFirst { creation.receivePaneID("%2", revision: revision) }
        creation.cancel()
        let accepted = creation.receivePaneID("%2", revision: revision)
        #expect(!accepted)
        pushSnapshot(to: store)
        #expect(creation.takeWindowDestination(
            selectedPaneID: "%2", paneStates: store.paneStates, isConnected: true
        ) == nil)
    }

    @Test("Another Host's identical pane ID cannot resolve a window fit")
    func exactHost() {
        let store = SessionStore()
        var creation = NewSessionCreation()
        let revision = creation.begin(hostID: "office", automaticFit: true)
        creation.receivePaneID("%2", revision: revision)
        pushSnapshot(to: store, hostID: "home")
        #expect(creation.takeWindowDestination(
            selectedPaneID: "%2", paneStates: store.paneStates, isConnected: true
        ) == nil)
        #expect(creation.paneID == "%2")
    }

    private func selection(_ creation: NewSessionCreation, store: SessionStore, selectedWindowID: String) -> WindowSelectionReconciliation {
        WindowSelectionReconciliation.resolve(
            selectedWindowId: selectedWindowID,
            candidates: store.windows(for: "office").map {
                .init(windowId: $0.id, paneId: $0.activePane?.paneId, isActive: $0.isWindowActive, paneIDs: $0.panes.map(\.paneId))
            },
            createdPaneId: creation.paneID
        )
    }

    private func pushSnapshot(to store: SessionStore, includeNewWindow: Bool = true, hostID: String = "office", agent: String? = nil) {
        let source = PaneState(paneId: "%1", sessionName: "work", windowIndex: 0, tmuxWindowId: "@1", width: 200, height: 60, isWindowActive: true)
        let created = PaneState(
            paneId: "%2", sessionName: "work", windowIndex: 1, tmuxWindowId: "@2", width: 200, height: 60,
            agentSession: agent.map { .init(paneId: "%2", pluginID: $0) }
        )
        store.handleStateUpdate(SessionStateMessage(pairId: hostID, paneStates: includeNewWindow ? ["%1": source, "%2": created] : ["%1": source]))
    }
}
