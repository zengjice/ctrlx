import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct OrbieQueryTests {
    @Test
    func authenticatedReadOnlyQueriesExposeOnlyAssociatedAgents() async throws {
        let f = try await AgentInteractionTestSupport()
        let main = await f.orbie()
        try await main.create(pluginID: "codex", providerID: nil)
        let orbiters = await f.orbiters()
        orbiters.draft.title = "Audio"
        orbiters.draft.goal = "Inspect audio"
        orbiters.draft.directory = f.root.path
        let id = try await orbiters.create(pluginID: "codex", providerID: nil)
        let query = OrbieQueryService(orbie: .init(paths: f.paths, hostID: f.hostID), orbiters: .init(paths: f.paths, hostID: f.hostID), interaction: f.interaction, workflows: { nil }, inspect: { $0 })
        let mainPID = try #require(main.instance?.processID)
        let peer = try #require(PluginIngressPeer.capture(peerPID: mainPID, userID: 501) { pid in
            .init(processID: pid, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0)
        })
        let request = JSONRPCRequest(id: "list", method: "orbie.agents.list", params: ["query": .string("Audio"), "limit": .int(3)])
        #expect(await !query.handle(request, peer: nil).ok)
        #expect(await query.handle(request, peer: peer).ok)
        #expect(await query.handle(.init(id: "show", method: "orbie.agents.show", params: ["id": .string(id)]), peer: peer).ok)
        #expect(await !query.handle(.init(id: "show", method: "orbie.agents.show", params: ["id": .string("\(UUID())/\(UUID())")]), peer: peer).ok)
        #expect(await !query.handle(.init(id: "spoof", method: "orbie.agents.list", params: ["pane": .string("%100")]), peer: peer).ok)
        #expect(await !query.handle(.init(id: "old", method: "orbie.tasks.list", params: [:]), peer: peer).ok)
        #expect(await !query.handle(.init(id: "bad", method: "orbie.agents.list", params: ["limit": .int(13)]), peer: peer).ok)
        #expect(f.writes.isEmpty)
        try await f.cleanup()
    }

    @Test
    func candidatesUseHostAndPaneIdentityAndNeverAcceptPathsOrCommands() {
        let id = "\(UUID())/\(UUID())"
        #expect(OrbieAgentCatalog.candidates(in: "Open [CtrlX Agent: \(id)] twice [CtrlX Agent: \(id)]") == [id])
        #expect(OrbieAgentCatalog.candidates(in: "[CtrlX Agent: /tmp/file] [CtrlX task: \(UUID())]").isEmpty)
        #expect(OrbieAgentCatalog.bounded(String(repeating: "🌍音", count: 100), bytes: 31).utf8.count <= 31)
    }
}
