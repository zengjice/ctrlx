import CtrlxNetworking
import Observation
import SwiftUI

/// Client-owned navigation. Execution and membership still come from the Host.
@MainActor
@Observable
final public class AgentWorkflowNavigation {
    public enum Destination: Hashable {
        case host(String)
        case configuration(route: String, hostID: UUID, id: UUID)
        case run(route: String, hostID: UUID, id: UUID)

        public var route: String {
            switch self {
            case let .host(route),
                 let .configuration(route, _, _),
                 let .run(route, _, _): route
            }
        }
    }

    public var path: [Destination] = []
    public var isPresented = false
    private var returnTargets: [UUID: (instance: AgentWorkflowInstance, destination: Destination)] = [:]
    private var lookupID: UUID?

    public init() { }

    public func remember(_ instance: AgentWorkflowInstance, route: String) {
        guard let destination = path.last, destination.route == route else { return }
        returnTargets[instance.id] = (instance, destination)
    }

    func startRun(
        _ attempt: ManageAgentWorkflows.Operation, endpoint: AgentWorkflowEndpoint,
        hostID: UUID, configurationID: UUID
    ) async throws -> AgentWorkflowRunState {
        let originalPath = path
        let configuration = Destination.configuration(route: endpoint.id, hostID: hostID, id: configurationID)
        let response = try await endpoint.request(attempt, hostID: hostID)
        guard let run = response.run else { throw AgentWorkflowError("The Host did not confirm the workflow. Retry to check this request.") }
        // The Host start can succeed after the operator leaves its configuration.
        if !Task.isCancelled, path == originalPath, originalPath.last == configuration {
            path.append(.run(route: endpoint.id, hostID: hostID, id: run.summary.id))
        }
        return run
    }

    public func open(for pane: PaneState, endpoint: AgentWorkflowEndpoint) async throws {
        guard let identity = pane.workspaceIdentity else { throw AgentWorkflowError("Waiting for the terminal's current identity.") }
        let requestID = UUID()
        lookupID = requestID
        let originalPath = path
        let overview = try await endpoint.overview()
        guard
            let live = try await endpoint.instances(hostID: overview.hostID).first(where: {
                $0.workspacePane.isSamePane(as: identity) && $0.readiness != .unavailable
            }) else { throw AgentWorkflowError("This Agent instance is no longer available.") }
        var destination: Destination?
        for summary in overview.runs where !summary.status.isTerminal {
            let response = try await endpoint.request(.run(summary.id), hostID: overview.hostID)
            guard let run = response.run else { throw AgentWorkflowError("The Host did not return this workflow.") }
            if run.nodes.contains(where: { $0.instance.map { live.matchesBinding($0) } == true }) {
                destination = .run(route: endpoint.id, hostID: overview.hostID, id: summary.id)
                break
            }
        }
        if destination == nil, let previous = returnTargets[live.id], previous.instance.matchesBinding(live), previous.destination.route == endpoint.id {
            destination = previous.destination
        }
        try Task.checkCancellation()
        guard lookupID == requestID, path == originalPath else { throw CancellationError() }
        guard let destination else { throw AgentWorkflowError("This Agent is not participating in an active workflow.") }
        if path.first != .host(endpoint.id) || path.last != destination {
            path = [.host(endpoint.id), destination]
        }
        isPresented = true
    }
}

public extension EnvironmentValues {
    @Entry var agentWorkflowNavigation: AgentWorkflowNavigation? = nil
}
