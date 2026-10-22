import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

struct ViewerWorkspaceInputTests {
    @Test("Creation replies wait for their own Host incarnation and cannot select recycled pane IDs")
    func createdSessionBinding() {
        var input = ViewerWorkspaceInputState()
        let scope = WorkspaceIdentityScope(hostID: UUID(), serverID: "10:100")
        let identity = WorkspacePaneIdentity(serverID: "10:100", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let pane = PaneState(paneId: "%1", sessionName: "created", tmuxWindowId: "@1", workspaceIdentity: identity)
        #expect(input.createdSessionBinding(pane: pane, scope: scope) == nil)
        for currentScope in [scope, .init(hostID: UUID(), serverID: scope.serverID), .init(hostID: scope.hostID, serverID: "20:200")] {
            var current = pane
            current.workspaceIdentity?.serverID = currentScope.serverID ?? ""
            input.update(.init(pairId: "pair", paneStates: ["%1": current], workspaceIdentity: currentScope, supportsWorkspaceInputIdentity: true))
            let binding = input.createdSessionBinding(pane: current, scope: scope)
            #expect((binding != nil) == (currentScope == scope))
            #expect(input.createdSessionBinding(pane: current, scope: nil) == nil)
        }
        input.update(.init(pairId: "pair", paneStates: [:], workspaceIdentity: scope, supportsWorkspaceInputIdentity: true))
        #expect(input.createdSessionBinding(pane: pane, scope: scope) == nil)
        input.update(.init(pairId: "old", paneStates: [:]))
        #expect(input.createdSessionBinding(pane: pane, scope: nil) == .legacy(pairID: "old"))
        #expect(input.createdSessionBinding(pane: pane, scope: scope) == nil)
    }

    @Test("A session confirmation survives child replacement but cannot close a new session or Host")
    func sessionBinding() throws {
        var input = ViewerWorkspaceInputState()
        let host = UUID()
        let identity = WorkspacePaneIdentity(serverID: "10:100", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        func state(_ identity: WorkspacePaneIdentity, hostID: UUID? = nil, name: String = "project") -> SessionStateMessage {
            .init(pairId: "pair", paneStates: ["%1": .init(paneId: "%1", sessionName: name, tmuxWindowId: "@3", workspaceIdentity: identity)], workspaceIdentity: .init(hostID: hostID ?? host, serverID: identity.serverID), supportsWorkspaceInputIdentity: true)
        }
        input.update(state(identity))
        let confirmation = input.sessionBinding(name: "project")
        var changedChildren = identity
        changedChildren.windowID = UUID()
        changedChildren.paneID = UUID()
        input.update(state(changedChildren))
        #expect(try confirmation.expectedPane(current: input.sessionBinding(name: "project")) == identity)
        input.update(state(changedChildren, name: "renamed"))
        #expect(input.sessionBinding(name: "project") == .unavailable)
        #expect(try confirmation.expectedPane(current: input.sessionBinding(name: "renamed")) == identity)
        var replacement = identity
        replacement.sessionID = UUID()
        var restarted = identity
        restarted.serverID = "20:200"
        for message in [state(replacement), state(restarted), state(identity, hostID: UUID())] {
            input.update(message)
            #expect(throws: (any Error).self) { try confirmation.expectedPane(current: input.sessionBinding(name: "project")) }
        }
        input.invalidate()
        #expect(input.sessionBinding(name: "project") == .unavailable)
        input.update(.init(pairId: "old", paneStates: [:]))
        #expect(input.sessionBinding(name: "project") == .legacy(pairID: "old"))
        input.update(.init(pairId: "old", paneStates: [:], supportsWorkspaceInputIdentity: true))
        #expect(input.sessionBinding(name: "project") == .unavailable)
    }

    @Test("Window actions survive active pane replacement but reject a reconstructed window")
    func windowBinding() throws {
        var input = ViewerWorkspaceInputState()
        let host = UUID()
        let identity = WorkspacePaneIdentity(serverID: "10:100", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        func state(_ identity: WorkspacePaneIdentity, pane: String = "%1", hostID: UUID? = nil) -> SessionStateMessage {
            .init(pairId: "pair", paneStates: [pane: .init(paneId: pane, sessionName: "project", windowIndex: 2, tmuxWindowId: "@3", workspaceIdentity: identity)], workspaceIdentity: .init(hostID: hostID ?? host, serverID: identity.serverID), supportsWorkspaceInputIdentity: true)
        }
        input.update(state(identity))
        let binding = input.windowBinding(target: "@3")
        #expect(try binding.expectedPane(current: input.windowBinding(target: "project:2")) == identity)
        #expect(try binding.expectedPane(current: input.windowBinding(target: "%1")) == identity)
        var changedPane = identity
        changedPane.paneID = UUID()
        input.update(state(changedPane, pane: "%8"))
        #expect(try binding.expectedPane(current: input.windowBinding(target: "@3")) == identity)
        var replacement = identity
        replacement.windowID = UUID()
        var rebooted = identity
        rebooted.serverID = "20:200"
        for message in [state(replacement), state(rebooted), state(identity, hostID: UUID())] {
            input.update(message)
            #expect(throws: (any Error).self) { try binding.expectedPane(current: input.windowBinding(target: "@3")) }
        }
        input.invalidate()
        #expect(input.windowBinding(target: "@3") == .unavailable)
        input.update(.init(pairId: "old", paneStates: [:]))
        #expect(input.windowBinding(target: "old:1") == .legacy(pairID: "old"))
    }

    @Test("Queued input retains its original pane through disconnects, replacement and ID reuse")
    func inputBinding() throws {
        var input = ViewerWorkspaceInputState()
        #expect(input.binding(paneID: "%1") == .unavailable)
        let host = UUID()
        let original = WorkspacePaneIdentity(serverID: "10:100", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        func state(_ identity: WorkspacePaneIdentity, pair: String = "pair", hostID: UUID? = nil) -> SessionStateMessage {
            .init(pairId: pair, paneStates: ["%1": .init(paneId: "%1", sessionName: "project", tmuxWindowId: "@1", workspaceIdentity: identity)], workspaceIdentity: .init(hostID: hostID ?? host, serverID: identity.serverID), supportsWorkspaceInputIdentity: true)
        }
        input.update(state(original))
        let binding = input.binding(paneID: "%1")
        #expect(try binding.expectedPane(current: input.binding(paneID: "%1")) == original)
        input.invalidate()
        #expect(throws: (any Error).self) { try binding.expectedPane(current: input.binding(paneID: "%1")) }
        input.update(state(original))
        #expect(try binding.expectedPane(current: input.binding(paneID: "%1")) == original)
        var moved = original
        moved.windowID = UUID()
        moved.sessionID = UUID()
        input.update(state(moved))
        #expect(try binding.expectedPane(current: input.binding(paneID: "%1")) == original)
        for message in [state(original, pair: "another"), state(original, hostID: UUID()), state(.init(serverID: "20:200", sessionID: original.sessionID, windowID: original.windowID, paneID: original.paneID)), state(.init(serverID: original.serverID, sessionID: original.sessionID, windowID: original.windowID, paneID: UUID()))] {
            input.update(message)
            #expect(throws: (any Error).self) { try binding.expectedPane(current: input.binding(paneID: "%1")) }
        }
    }

    @Test("Old Hosts retain input support; missing new identities never downgrade to legacy")
    func capability() throws {
        var input = ViewerWorkspaceInputState()
        input.update(.init(pairId: "old", paneStates: [:]))
        let legacy = input.binding(paneID: "%1")
        #expect(try legacy.expectedPane(current: legacy) == nil)
        input.update(.init(pairId: "old", paneStates: [:], supportsWorkspaceInputIdentity: true))
        #expect(input.binding(paneID: "%1") == .unavailable)
        #expect(throws: (any Error).self) { try legacy.expectedPane(current: input.binding(paneID: "%1")) }
    }
}
