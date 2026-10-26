import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct AgentWorkflowNavigationTests {
    @MainActor
    final private class Fixture {
        let hostID = UUID()
        var instance: AgentWorkflowInstance
        var runs: [AgentWorkflowRun] = []
        var onCatalog: (() -> Void)?
        var startContinuation: CheckedContinuation<AgentWorkflowResponse, any Error>?
        var startRequests: [ManageAgentWorkflows.Operation] = []

        init() {
            self.instance = .init(
                hostID: hostID, pluginID: "codex", processID: 123, processRuntimeID: "123:start",
                workspacePane: .init(serverID: "tmux", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
                paneID: "%1", conversationID: "native", displayName: "work · Developer", workingDirectory: "/work",
                capabilities: .init(maximumInputBytes: 100_000), readiness: .ready,
            )
        }

        var pane: PaneState {
            .init(paneId: instance.paneID, workspaceIdentity: instance.workspacePane)
        }

        func makeRun(status: AgentWorkflowRunStatus = .running) -> AgentWorkflowRun {
            let node = AgentWorkflowNode(name: "Developer", agentInstanceID: instance.id)
            let definition = AgentWorkflowDefinition(name: "Work", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id)
            var run = AgentWorkflowRun(definition: definition, instances: [instance], createdAt: Date(), authorizationExpiresAt: Date().addingTimeInterval(3_600))
            run.status = status
            return run
        }

        var endpoint: AgentWorkflowEndpoint {
            .init(id: "pair", name: "Host", connected: { true }, supported: { true }) { request in
                #expect(request.expectedHostID == nil || request.expectedHostID == self.hostID)
                var response = AgentWorkflowResponse(hostID: self.hostID)
                switch request.operation {
                case .definitions: response.definitions = .init(items: [], nextOffset: nil)
                case .runs: response.runs = .init(items: self.runs.map(AgentWorkflowRunSummary.init), nextOffset: nil)
                case .catalog:
                    self.onCatalog?()
                    response.instances = .init(items: [self.instance], nextOffset: nil)
                case let .run(id):
                    if let run = self.runs.first(where: { $0.id == id }) {
                        response.run = .init(run, currentInstances: [self.instance])
                    }
                case .start:
                    self.startRequests.append(request.operation)
                    return try await withCheckedThrowingContinuation { self.startContinuation = $0 }
                default: Issue.record("Unexpected workflow navigation request")
                }
                return response
            }
        }
    }

    @Test(arguments: ["stay", "back", "switch-host", "other-configuration", "already-away", "cancelled"])
    func delayedStartOnlyNavigatesFromItsOriginalConfiguration(scenario: String) async throws {
        let fixture = Fixture(), navigation = AgentWorkflowNavigation()
        let run = fixture.makeRun()
        let originalPath: [AgentWorkflowNavigation.Destination] = [
            .host("pair"), .configuration(route: "pair", hostID: fixture.hostID, id: run.definition.id),
        ]
        navigation.path = scenario == "already-away" ? [.host("another-pair")] : originalPath
        let attempt = ManageAgentWorkflows.Operation.start(
            definitionID: run.definition.id, expectedRevision: run.definition.revision,
            requestID: run.id, authorizationExpiresAt: run.authorizationExpiresAt,
        )
        let task = Task {
            try await navigation.startRun(attempt, endpoint: fixture.endpoint, hostID: fixture.hostID, configurationID: run.definition.id)
        }
        for _ in 0..<100 where fixture.startContinuation == nil {
            await Task.yield()
        }
        let continuation = try #require(fixture.startContinuation)
        switch scenario {
        case "back": navigation.path = [.host("pair")]
        case "switch-host": navigation.path = [.host("another-pair")]
        case "other-configuration": navigation.path = [.host("pair"), .configuration(route: "pair", hostID: fixture.hostID, id: UUID())]
        case "cancelled": task.cancel()
        default: break
        }
        let pathBeforeConfirmation = navigation.path
        var response = AgentWorkflowResponse(hostID: fixture.hostID)
        response.run = .init(run, currentInstances: [fixture.instance])
        continuation.resume(returning: response)
        let confirmed = try await task.value
        #expect(confirmed.summary.id == run.id && confirmed.summary.status == .running)
        #expect(fixture.startRequests == [attempt])
        #expect(navigation.path == (scenario == "stay"
                ? originalPath + [.run(route: "pair", hostID: fixture.hostID, id: run.id)] : pathBeforeConfirmation))
    }

    @Test(arguments: [AgentWorkflowRunStatus.running, .paused, .finishing])
    func terminalOpensItsCurrentRunIncludingPausedQuestions(status: AgentWorkflowRunStatus) async throws {
        let fixture = Fixture(), navigation = AgentWorkflowNavigation()
        let run = fixture.makeRun(status: status)
        fixture.runs = [run]
        try await navigation.open(for: fixture.pane, endpoint: fixture.endpoint)
        #expect(navigation.path == [.host("pair"), .run(route: "pair", hostID: fixture.hostID, id: run.id)])
        #expect(navigation.isPresented)
    }

    @Test
    func currentRunTakesPriorityOverRememberedConfiguration() async throws {
        let fixture = Fixture(), navigation = AgentWorkflowNavigation()
        navigation.path = [.host("pair"), .configuration(route: "pair", hostID: fixture.hostID, id: UUID())]
        navigation.remember(fixture.instance, route: "pair")
        let run = fixture.makeRun()
        fixture.runs = [run]
        try await navigation.open(for: fixture.pane, endpoint: fixture.endpoint)
        #expect(navigation.path.last == .run(route: "pair", hostID: fixture.hostID, id: run.id))
    }

    @Test(arguments: [false, true])
    func returningRestoresConfigurationOrFinishedRunWithoutHostPicker(finished: Bool) async throws {
        let fixture = Fixture(), navigation = AgentWorkflowNavigation()
        let run = fixture.makeRun(status: .completed)
        fixture.runs = [run]
        let destination: AgentWorkflowNavigation.Destination = finished
            ? .run(route: "pair", hostID: fixture.hostID, id: run.id)
            : .configuration(route: "pair", hostID: fixture.hostID, id: run.definition.id)
        navigation.path = [.host("pair"), destination]
        navigation.remember(fixture.instance, route: "pair")
        navigation.isPresented = false
        try await navigation.open(for: fixture.pane, endpoint: fixture.endpoint)
        #expect(navigation.path == [.host("pair"), destination])
        #expect(navigation.isPresented)
    }

    @Test
    func returningToTheSameRunPreservesItsConfigurationAncestor() async throws {
        let fixture = Fixture(), navigation = AgentWorkflowNavigation()
        let run = fixture.makeRun()
        fixture.runs = [run]
        let path: [AgentWorkflowNavigation.Destination] = [
            .host("pair"), .configuration(route: "pair", hostID: fixture.hostID, id: run.definition.id),
            .run(route: "pair", hostID: fixture.hostID, id: run.id),
        ]
        navigation.path = path
        navigation.remember(fixture.instance, route: "pair")
        try await navigation.open(for: fixture.pane, endpoint: fixture.endpoint)
        #expect(navigation.path == path)
    }

    @Test
    func reusedPaneNeverInheritsAnOldWorkflowReturnTarget() async throws {
        let fixture = Fixture(), navigation = AgentWorkflowNavigation()
        let run = fixture.makeRun()
        fixture.runs = [run]
        navigation.path = [.host("pair"), .run(route: "pair", hostID: fixture.hostID, id: run.id)]
        navigation.remember(fixture.instance, route: "pair")
        let old = fixture.instance
        fixture.instance = .init(
            hostID: fixture.hostID, pluginID: old.pluginID, processID: old.processID, processRuntimeID: "replacement",
            workspacePane: old.workspacePane, paneID: old.paneID, conversationID: old.conversationID,
            displayName: old.displayName, workingDirectory: old.workingDirectory, capabilities: old.capabilities, readiness: .ready,
        )
        await #expect(throws: AgentWorkflowError.self) { try await navigation.open(for: fixture.pane, endpoint: fixture.endpoint) }
        #expect(!navigation.isPresented)
    }

    @Test
    func replacedTmuxPaneWithSameRuntimeIDIsRejected() async throws {
        let fixture = Fixture(), navigation = AgentWorkflowNavigation()
        let oldPane = fixture.pane
        fixture.instance.workspacePane.paneID = UUID()
        fixture.runs = [fixture.makeRun()]
        await #expect(throws: AgentWorkflowError.self) { try await navigation.open(for: oldPane, endpoint: fixture.endpoint) }
        #expect(navigation.path.isEmpty)
    }

    @Test(arguments: [false, true])
    func navigationDuringLookupCannotBeOverwrittenByItsLateResult(hasRun: Bool) async throws {
        let fixture = Fixture(), navigation = AgentWorkflowNavigation()
        fixture.runs = hasRun ? [fixture.makeRun()] : []
        fixture.onCatalog = { navigation.path = [.host("another-pair")] }
        await #expect(throws: CancellationError.self) { try await navigation.open(for: fixture.pane, endpoint: fixture.endpoint) }
        #expect(navigation.path == [.host("another-pair")])
        #expect(!navigation.isPresented)
    }
}
