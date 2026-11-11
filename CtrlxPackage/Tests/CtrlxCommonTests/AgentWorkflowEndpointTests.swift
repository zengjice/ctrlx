import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct AgentWorkflowEndpointTests {
    @MainActor
    final private class Transport {
        var connected = true
        var supported = true
        var response = AgentWorkflowResponse(hostID: UUID())
        var replies: [AgentWorkflowResponse] = []
        var requests: [ManageAgentWorkflows] = []

        var endpoint: AgentWorkflowEndpoint {
            .init(id: "route", name: "Host", connected: { self.connected }, supported: { self.supported }) { command in
                self.requests.append(command)
                return self.replies.isEmpty ? self.response : self.replies.removeFirst()
            }
        }
    }

    @Test(arguments: [false, true], [AgentWorkflowRunStatus.running, .paused])
    func terminalControlPreservesIntentWhenAnotherOperatorChangedTheState(paused: Bool, status: AgentWorkflowRunStatus) async throws {
        let transport = Transport(), hostID = transport.response.hostID
        let instance = AgentWorkflowInstance(
            hostID: hostID,
            pluginID: "codex",
            processID: 42,
            processRuntimeID: "42:start",
            workspacePane: .init(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: "%1",
            conversationID: "native",
            displayName: "Developer",
            workingDirectory: "/work",
            capabilities: .init(maximumInputBytes: 1_000),
            readiness: .ready
        )
        let node = AgentWorkflowNode(name: "Developer", agentInstanceID: instance.id)
        let definition = AgentWorkflowDefinition(name: "Work", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id)
        var run = AgentWorkflowRun(definition: definition, instances: [instance], createdAt: Date(), authorizationExpiresAt: Date().addingTimeInterval(3_600))
        run.status = status
        transport.response.run = .init(run, currentInstances: [instance])
        _ = try await transport.endpoint.setWorkflowPaused(paused, pane: instance.workspacePane, hostID: hostID)
        #expect(transport.requests[0].operation == .terminal(instance.workspacePane))
        let alreadyApplied = (status == .paused) == paused
        #expect(transport.requests.count == (alreadyApplied ? 1 : 2))
        if !alreadyApplied {
            #expect(transport.requests[1].operation == (paused ? .pause(run.id, expectedRevision: run.revision) : .resume(run.id, expectedRevision: run.revision, roundLimit: nil)))
        }
    }

    @Test
    func disconnectedOrOldHostNeverReceivesCommands() async throws {
        let transport = Transport()
        let endpoint = transport.endpoint
        transport.connected = false
        await #expect(throws: AgentWorkflowError.self) { try await endpoint.request(.runs(offset: 0)) }
        transport.connected = true
        transport.supported = false
        await #expect(throws: AgentWorkflowError.self) { try await endpoint.request(.runs(offset: 0)) }
        #expect(transport.requests.isEmpty)
        transport.supported = true
        #expect(try await endpoint.request(.runs(offset: 0)) == transport.response)
        #expect(transport.requests.count == 1)
    }

    @Test
    func requestBindsToHostAndRejectsChangedIdentityOrProtocol() async throws {
        let transport = Transport()
        let hostID = transport.response.hostID
        let endpoint = transport.endpoint
        _ = try await endpoint.request(.pause(UUID(), expectedRevision: 3), hostID: hostID)
        #expect(transport.requests.first?.expectedHostID == hostID)
        transport.response = .init(hostID: UUID())
        await #expect(throws: AgentWorkflowError.self) { try await endpoint.request(.runs(offset: 0), hostID: hostID) }
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(transport.response)) as? [String: Any])
        object["version"] = 1
        transport.response = try JSONDecoder().decode(AgentWorkflowResponse.self, from: JSONSerialization.data(withJSONObject: object))
        await #expect(throws: AgentWorkflowError.self) { try await endpoint.request(.runs(offset: 0)) }
    }

    @Test
    func oversizedConfigurationIsRejectedBeforeTransport() async throws {
        let transport = Transport()
        let node = AgentWorkflowNode(name: "Agent", agentInstanceID: UUID())
        let definition = AgentWorkflowDefinition(
            name: "Large", hostID: transport.response.hostID, nodes: [node], edges: [], entryNodeID: node.id,
            initialInput: .init(text: String(repeating: "x", count: AgentWorkflowWire.maximumDefinitionBytes))
        )
        await #expect(throws: AgentWorkflowError.self) {
            try await transport.endpoint.request(.save(definition, expectedRevision: nil), hostID: definition.hostID)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test
    func overviewPinsHostAcrossAllPagesAndBothLists() async throws {
        let transport = Transport()
        let hostID = transport.response.hostID
        let node = AgentWorkflowNode(name: "Agent", agentInstanceID: UUID())
        let one = AgentWorkflowDefinition(name: "One", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id)
        let two = AgentWorkflowDefinition(name: "Two", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id)
        var first = AgentWorkflowResponse(hostID: hostID)
        first.definitions = .init(items: [.init(one)], nextOffset: 1)
        var second = AgentWorkflowResponse(hostID: hostID)
        second.definitions = .init(items: [.init(two)], nextOffset: nil)
        var third = AgentWorkflowResponse(hostID: hostID)
        third.runs = .init(items: [], nextOffset: nil)
        transport.replies = [first, second, third]
        let overview = try await transport.endpoint.overview()
        #expect(overview.hostID == hostID)
        #expect(overview.definitions.map(\.id) == [one.id, two.id])
        #expect(overview.runs.isEmpty)
        #expect(transport.requests.map(\.operation) == [.definitions(offset: 0), .definitions(offset: 1), .runs(offset: 0)])
        #expect(transport.requests.map(\.expectedHostID) == [nil, hostID, hostID])
    }

    @Test
    func hostChangeOrRepeatedCursorCannotMixListsOrLoopForever() async throws {
        let transport = Transport()
        let hostID = transport.response.hostID
        var first = AgentWorkflowResponse(hostID: hostID)
        first.definitions = .init(items: [], nextOffset: 0)
        transport.response = first
        await #expect(throws: AgentWorkflowError.self) { try await transport.endpoint.overview() }
        #expect(transport.requests.count == 1)
        first.definitions = .init(items: [], nextOffset: nil)
        transport.replies = [first, .init(hostID: UUID())]
        await #expect(throws: AgentWorkflowError.self) { try await transport.endpoint.overview() }
        #expect(transport.requests.count == 3)
    }

    @Test
    func textReaderUsesByteOffsetsAndRejectsTruncation() async throws {
        let transport = Transport()
        let hostID = transport.response.hostID
        let runID = UUID(), invocationID = UUID()
        var first = AgentWorkflowResponse(hostID: hostID)
        first.text = .init(text: "中", nextOffset: 3, totalBytes: 7)
        var last = AgentWorkflowResponse(hostID: hostID)
        last.text = .init(text: "🙂", nextOffset: nil, totalBytes: 7)
        transport.replies = [first, last]
        let text = try await transport.endpoint.text(runID: runID, invocationID: invocationID, part: .result, hostID: hostID)
        #expect(text == "中🙂")
        #expect(transport.requests.map(\.operation) == [
            .text(runID: runID, invocationID: invocationID, part: .result, offset: 0),
            .text(runID: runID, invocationID: invocationID, part: .result, offset: 3),
        ])
        first.text = .init(text: "中", nextOffset: nil, totalBytes: 7)
        transport.response = first
        await #expect(throws: AgentWorkflowError.self) {
            try await transport.endpoint.text(runID: runID, invocationID: invocationID, part: .input, hostID: hostID)
        }
    }

    @Test
    func cancelledReadersDoNotStartAnotherRequest() async throws {
        let transport = Transport()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.endpoint.overview()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(transport.requests.isEmpty)
    }

    @Test
    func openingAnAgentResolvesTheStableTargetAcrossRestarts() async throws {
        let transport = Transport()
        let hostID = transport.response.hostID
        let instance = AgentWorkflowInstance(
            hostID: hostID, pluginID: "codex", processID: 123, processRuntimeID: "start",
            workspacePane: .init(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: "%1", conversationID: "conversation", displayName: "Developer", workingDirectory: "/work",
            capabilities: .init(maximumInputBytes: 100_000), readiness: .ready
        )
        var moved = instance
        moved.workspacePane.serverID = "restarted-server"
        moved.workspacePane.sessionID = UUID()
        transport.response.instances = .init(items: [moved], nextOffset: nil)
        #expect(try await transport.endpoint.currentInstance(instance) == moved)
        let replacement = AgentWorkflowInstance(
            hostID: hostID, pluginID: "codex", processID: 123, processRuntimeID: "another-start",
            workspacePane: moved.workspacePane, paneID: "%1", conversationID: "conversation", displayName: "Developer",
            workingDirectory: "/work", capabilities: instance.capabilities, readiness: .ready
        )
        transport.response.instances = .init(items: [replacement], nextOffset: nil)
        #expect(try await transport.endpoint.currentInstance(instance) == replacement)
        var differentWindow = moved
        differentWindow.workspacePane.windowID = UUID()
        transport.response.instances = .init(items: [differentWindow], nextOffset: nil)
        await #expect(throws: AgentWorkflowError.self) { try await transport.endpoint.currentInstance(instance) }
        moved.readiness = .unavailable
        transport.response.instances = .init(items: [moved], nextOffset: nil)
        await #expect(throws: AgentWorkflowError.self) { try await transport.endpoint.currentInstance(instance) }
    }
}
