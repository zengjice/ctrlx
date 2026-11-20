import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
@Suite("SessionStore shared terminal layouts")
struct SessionStoreSharedTerminalLayoutTests {
    @Test
    func tabGroupsRejectAnOlderSnapshotAndStayScopedToTheHost() {
        let store = SessionStore()
        let session = UUID()
        let original = SessionTabLayout()
        let edited = SessionTabLayout(order: [.window(UUID())], revision: 2)
        store.handleStateUpdate(.init(pairId: "first", paneStates: [:], sessionTabLayouts: [session: edited]))
        store.handleStateUpdate(.init(pairId: "first", paneStates: [:], sessionTabLayouts: [session: original]))
        store.handleStateUpdate(.init(pairId: "second", paneStates: [:], sessionTabLayouts: [session: original]))

        #expect(store.sessionTabLayoutsByHost["first"]?[session] == edited)
        #expect(store.sessionTabLayoutsByHost["second"]?[session] == original)
        store.clearSessions(for: "first")
        #expect(store.sessionTabLayoutsByHost["first"] == nil)
    }

    @Test("An advertised layout is stored and cleared with its host")
    func storesAndClears() {
        let store = SessionStore()
        let layout = SharedTerminalLayout(
            leftWindowId: "@1",
            rightWindowIds: ["@2"],
            selectedRightWindowId: "@2",
            splitRatio: 0.5,
            revision: 1
        )

        store.handleStateUpdate(SessionStateMessage(
            pairId: "host-1",
            paneStates: [:],
            sharedTerminalLayouts: ["coding": layout]
        ))

        #expect(store.supportsSharedTerminalLayouts(for: "host-1"))
        #expect(store.sharedTerminalLayout(for: "host-1", sessionName: "coding") == layout)

        store.clearSessions(for: "host-1")
        #expect(!store.supportsSharedTerminalLayouts(for: "host-1"))
        #expect(store.sharedTerminalLayout(for: "host-1", sessionName: "coding") == nil)
    }

    @Test("An absent field identifies an older host")
    func detectsLegacyHost() {
        let store = SessionStore()
        store.handleStateUpdate(SessionStateMessage(
            pairId: "host-1",
            paneStates: [:],
            sharedTerminalLayouts: [:]
        ))
        #expect(store.supportsSharedTerminalLayouts(for: "host-1"))

        store.handleStateUpdate(SessionStateMessage(pairId: "host-1", paneStates: [:]))
        #expect(!store.supportsSharedTerminalLayouts(for: "host-1"))
    }

    @Test("Feature support does not authorize writes before this session has a Host layout")
    func waitsForPerSessionAuthority() {
        let store = SessionStore()
        store.handleStateUpdate(SessionStateMessage(
            pairId: "host-1",
            paneStates: [:],
            sharedTerminalLayouts: [:]
        ))

        #expect(store.supportsSharedTerminalLayouts(for: "host-1"))
        #expect(!store.hasAuthoritativeSharedTerminalLayout(
            for: "host-1",
            sessionName: "background"
        ))

        store.handleStateUpdate(SessionStateMessage(
            pairId: "host-1",
            paneStates: [:],
            sharedTerminalLayouts: [
                "background": SharedTerminalLayout(
                    leftWindowId: "@1",
                    revision: 1
                ),
            ]
        ))

        #expect(store.hasAuthoritativeSharedTerminalLayout(
            for: "host-1",
            sessionName: "background"
        ))
    }

    @Test("A stale snapshot cannot roll back a Host revision")
    func rejectsRevisionRollback() {
        let store = SessionStore()
        let newest = SharedTerminalLayout(
            leftWindowId: "@2",
            rightWindowIds: ["@3"],
            selectedRightWindowId: "@3",
            splitRatio: 0.6,
            revision: 5
        )
        let stale = SharedTerminalLayout(
            leftWindowId: "@1",
            rightWindowIds: [],
            selectedRightWindowId: nil,
            splitRatio: 0.5,
            revision: 4
        )

        store.handleStateUpdate(SessionStateMessage(
            pairId: "host-1",
            paneStates: [:],
            sharedTerminalLayouts: ["coding": newest]
        ))
        store.handleStateUpdate(SessionStateMessage(
            pairId: "host-1",
            paneStates: [:],
            sharedTerminalLayouts: ["coding": stale]
        ))

        #expect(store.sharedTerminalLayout(for: "host-1", sessionName: "coding") == newest)
    }
}
