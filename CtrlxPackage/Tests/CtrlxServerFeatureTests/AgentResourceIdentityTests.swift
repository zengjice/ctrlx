import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentResourceIdentityTests {
    @Test
    func conversationKeyUsesStablePaneAndNeverVersionsOrWindowPlacement() {
        let host = UUID()
        var pane = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        func identity(_ host: UUID, _ pane: WorkspacePaneIdentity, _ plugin: String = "codex", _ conversation: String = "thread") -> AgentResourceIdentity {
            .init(hostID: host, pane: pane, pluginID: plugin, conversationID: conversation)
        }
        let original = identity(host, pane)
        pane.windowID = UUID()
        pane.sessionID = UUID()
        #expect(identity(host, pane) == original)
        #expect(identity(UUID(), pane).key != original.key)
        #expect(identity(host, pane, "claude-code").key != original.key)
        #expect(identity(host, pane, "codex", "fork").key != original.key)
        pane.paneID = UUID()
        #expect(identity(host, pane).key != original.key)
        #expect(identity(host, pane, "a:b", "c").key != identity(host, pane, "a", "b:c").key)
    }
}
