import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

struct ViewerWorkspaceCatalogTests {
    private let host = UUID()
    private let session = UUID()
    private let window = UUID()
    private let pane = UUID()

    private func message(server: String = "old", runtime: String = "%1", name: String = "project", windowRuntime: String = "@1", pair: String = "pair") -> SessionStateMessage {
        .init(pairId: pair, paneStates: [runtime: .init(
            paneId: runtime, sessionName: name, tmuxWindowId: windowRuntime,
            workspaceIdentity: .init(serverID: server, sessionID: session, windowID: window, paneID: pane)
        )], workspaceIdentity: .init(hostID: host, serverID: server))
    }

    @Test("Durable routes survive changed runtime IDs and names but never a different pairing or state root")
    func remapping() throws {
        let old = try #require(ViewerWorkspaceCatalog(state: message()))
        let reference = try #require(old.reference(paneID: "%1"))
        let newer = try #require(ViewerWorkspaceCatalog(state: message(server: "new", runtime: "%55", name: "renamed", windowRuntime: "@20")))
        #expect(newer.resolve(reference)?.paneID == "%55")
        #expect(newer.resolve(reference)?.sessionName == "renamed")
        #expect(newer.resolve(reference)?.windowID == "@20")
        #expect(newer.reference(paneID: "%1") == nil)
        var anotherHost = reference
        anotherHost.hostID = UUID()
        #expect(newer.resolve(anotherHost) == nil)
        var anotherPair = reference
        anotherPair.pairID = "other-pair"
        #expect(newer.resolve(anotherPair) == nil)
        var anotherPane = reference
        anotherPane.paneID = UUID()
        #expect(newer.resolve(anotherPane) == nil)
        var anotherWindow = reference
        anotherWindow.windowID = UUID()
        #expect(newer.resolve(anotherWindow) == nil)
        #expect(try newer.resolve(#require(old.reference(sessionName: "project")))?.sessionName == "renamed")
    }

    @Test("A recycled pane number is not evidence of persistent identity")
    func reusedNumber() throws {
        let old = try #require(ViewerWorkspaceCatalog(state: message()))
        let saved = try #require(old.reference(paneID: "%1"))
        let replacement = PaneState(
            paneId: "%1",
            sessionName: "project",
            tmuxWindowId: "@1",
            workspaceIdentity: .init(serverID: "new", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        )
        let newer = try #require(ViewerWorkspaceCatalog(state: .init(pairId: "pair", paneStates: ["%1": replacement], workspaceIdentity: .init(hostID: host, serverID: "new"))))
        #expect(newer.resolve(saved) == nil)
        #expect(ViewerWorkspaceCatalog(state: .init(pairId: "pair", paneStates: message().paneStates)) == nil)
    }

    @Test("Mixed generations, duplicate UUIDs and inconsistent runtime names reject the catalog")
    func invalidCatalogs() {
        let valid = message()
        var panes = valid.paneStates
        #expect(ViewerWorkspaceCatalog(state: .init(pairId: "pair", paneStates: panes, workspaceIdentity: .init(hostID: host, serverID: "other"))) == nil)
        panes["%2"] = .init(paneId: "%2", sessionName: "project", tmuxWindowId: "@1", workspaceIdentity: panes["%1"]?.workspaceIdentity)
        #expect(ViewerWorkspaceCatalog(state: .init(pairId: "pair", paneStates: panes, workspaceIdentity: valid.workspaceIdentity)) == nil)
        panes["%2"]?.workspaceIdentity?.paneID = UUID()
        panes["%2"]?.sessionName = "different"
        #expect(ViewerWorkspaceCatalog(state: .init(pairId: "pair", paneStates: panes, workspaceIdentity: valid.workspaceIdentity)) == nil)
        panes["%2"]?.sessionName = "project"
        #expect(ViewerWorkspaceCatalog(state: .init(pairId: "pair", paneStates: panes, workspaceIdentity: valid.workspaceIdentity))?.routes.count == 2)
    }

    @MainActor
    @Test("A restarted Host can publish lower layout revisions; same-incarnation rollback remains rejected")
    func layoutGeneration() {
        let store = SessionStore()
        func state(_ server: String, _ revision: UInt64) -> SessionStateMessage {
            let base = message(server: server)
            return .init(
                pairId: base.pairId,
                paneStates: base.paneStates,
                sharedTerminalLayouts: ["project": .init(leftWindowId: "@1", revision: revision)],
                workspaceIdentity: base.workspaceIdentity
            )
        }
        store.handleStateUpdate(state("old", 10))
        store.handleStateUpdate(state("old", 2))
        #expect(store.sharedTerminalLayout(for: "pair", sessionName: "project")?.revision == 10)
        // A partial discovery must not erase the last known incarnation before
        // the next complete snapshot can compare its layout revision namespace.
        store.handleStateUpdate(.init(pairId: "pair", paneStates: [:], sharedTerminalLayouts: ["project": .init(leftWindowId: "@1", revision: 11)]))
        store.handleStateUpdate(state("new", 1))
        #expect(store.sharedTerminalLayout(for: "pair", sessionName: "project")?.revision == 1)
        store.clearSessions(for: "pair")
        #expect(store.workspaceCatalogsByHost["pair"] == nil)
        store.handleStateUpdate(state("again", 1))
        #expect(store.workspaceCatalogsByHost["pair"]?.scope.serverID == "again")
    }
}
