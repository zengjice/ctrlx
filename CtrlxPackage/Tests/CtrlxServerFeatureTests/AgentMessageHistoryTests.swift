import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentMessageHistoryTests {
    @Test
    func fullConversationsPageThroughAllHistoryAndAttachments() async throws {
        let f = try await AgentInteractionTestSupport()
        let initial = await f.orbie()
        try await initial.create(pluginID: "codex", providerID: nil)
        let instance = try #require(initial.instance)
        let attachment = f.root.appendingPathComponent("original.txt")
        try Data("original attachment".utf8).write(to: attachment)
        var ids: [UUID] = []
        for i in 0..<250 {
            var message = AgentMessage(instance: instance, text: "message \(i)")
            message.status = .succeeded
            message.answer = "answer \(i)"
            if i == 0 {
                message.attachments = [.init(metadata: .init(name: "original.txt", mediaType: "text/plain", byteCount: 19, sha256: "fixture"), path: attachment.path)]
            }
            try await f.interaction.store.importMessage(message)
            ids.append(message.id)
        }
        var record = try #require(initial.record)
        record.messageIDs = ids
        try await OrbieStore(paths: f.paths, hostID: f.hostID).save(record)
        var index = OrbiterIndex(hostID: f.hostID)
        let agent = OrbiterRecord(agentID: instance.agentID, binding: instance, pane: instance.workspacePane, messageIDs: ids)
        index.agents = [agent]
        try await OrbiterStore(paths: f.paths, hostID: f.hostID).save(index)
        let main = await f.orbie()
        let orbiters = await f.orbiters()
        orbiters.historyAgentID = agent.id
        await orbiters.refresh(inspect: false)
        #expect(main.historyPage.messages.map(\.id) == Array(ids.suffix(100)))
        #expect(orbiters.history(agent).map(\.id) == Array(ids.suffix(100)))
        for expected in [Array(ids[50..<150]), Array(ids[..<50])] {
            try await main.loadHistory(endingAt: #require(main.historyPage.olderPageEndID))
            try await orbiters.loadHistory(endingAt: #require(orbiters.historyPage.olderPageEndID))
            #expect(main.historyPage.messages.map(\.id) == expected)
            #expect(orbiters.history(agent).map(\.id) == expected)
            // A refresh or the compact panel still sees the latest message.
            await main.refresh(inspect: false)
            await orbiters.refresh(inspect: false)
            #expect(main.messages.last?.id == ids.last)
            #expect(orbiters.messages.last?.id == ids.last)
            #expect(main.historyPage.messages.map(\.id) == expected)
        }
        #expect(main.historyPage.olderPageEndID == nil && orbiters.historyPage.olderPageEndID == nil)
        #expect(main.historyPage.messages.first?.attachments?.first?.path == attachment.path)
        #expect(orbiters.history(agent).first?.attachments?.first?.path == attachment.path)
        #expect(try String(contentsOf: attachment, encoding: .utf8) == "original attachment")
        try await main.loadHistory(endingAt: #require(main.historyPage.newerPageEndID))
        try await orbiters.loadHistory(endingAt: #require(orbiters.historyPage.newerPageEndID))
        #expect(main.historyPage.messages.map(\.id) == Array(ids[50..<150]))
        #expect(orbiters.history(agent).map(\.id) == Array(ids[50..<150]))

        main.draft = "new message while reading history"
        await main.send()
        try await f.complete(#require(main.messages.last))
        await main.refresh(inspect: false)
        #expect(main.historyPage.messages.map(\.id) == Array(ids[50..<150]))
        #expect(main.messages.last?.text == "new message while reading history")
        await main.loadHistory(endingAt: nil)
        await orbiters.loadHistory(endingAt: nil)
        #expect(main.historyPage.messages == main.messages)
        #expect(orbiters.history(agent).map(\.id) == Array(ids.suffix(100)))
        #expect(main.historyPage.newerPageEndID == nil)

        orbiters.historyAgentID = nil
        #expect(orbiters.historyPage.messages.isEmpty)
        orbiters.historyAgentID = agent.id
        await orbiters.refresh(inspect: false)
        #expect(orbiters.history(agent).map(\.id) == Array(ids.suffix(100)))
        #expect(try await f.interaction.store.page([]).messages.isEmpty)
        await #expect(throws: AgentWorkflowError.self) { try await f.interaction.store.page(ids, endingAt: UUID()) }
        try await f.cleanup()
    }
}
