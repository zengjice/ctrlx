import CtrlxNetworking
import Foundation

/// Mac Host and both Viewers share the same operator API. The route ID belongs
/// to the client; response.hostID is the durable identity used for mutations.
@MainActor
public struct AgentWorkflowEndpoint: Identifiable {
    public let id: String
    public let name: String
    private let connected: @MainActor @Sendable () -> Bool
    private let supported: @MainActor @Sendable () -> Bool
    private let perform: @MainActor @Sendable (ManageAgentWorkflows) async throws -> AgentWorkflowResponse

    public var isConnected: Bool {
        connected()
    }

    public var isSupported: Bool {
        supported()
    }

    public init(
        id: String, name: String,
        connected: @escaping @MainActor @Sendable () -> Bool,
        supported: @escaping @MainActor @Sendable () -> Bool,
        perform: @escaping @MainActor @Sendable (ManageAgentWorkflows) async throws -> AgentWorkflowResponse
    ) {
        self.id = id
        self.name = name
        self.connected = connected
        self.supported = supported
        self.perform = perform
    }

    public func request(_ operation: ManageAgentWorkflows.Operation, hostID: UUID? = nil) async throws -> AgentWorkflowResponse {
        guard isConnected else { throw AgentWorkflowError("The Host is offline. Its workflows continue there.") }
        guard isSupported else { throw AgentWorkflowError("Update the Host Mac to manage Agent workflows.") }
        let command = ManageAgentWorkflows(operation, expectedHostID: hostID)
        guard try JSONEncoder().encode(command).count <= AgentWorkflowWire.maximumEncodedBytes else {
            throw AgentWorkflowError("The workflow request is too large.")
        }
        if case let .save(definition, _) = operation {
            try AgentWorkflowWire.validate(definition)
        }
        let response = try await perform(command)
        guard response.version == AgentWorkflowWire.version, hostID == nil || response.hostID == hostID else {
            throw AgentWorkflowError("The Host or workflow protocol changed. Reload before continuing.")
        }
        return response
    }

    public static func remote(_ host: PairedHost, manager: ViewerConnectionManager?) -> Self {
        let connection = manager?.connection(for: host.id)
        return Self(
            id: host.id, name: host.displayName,
            connected: { connection?.isHostConnected == true },
            supported: { connection?.relayClient.hostAgentWorkflowVersion == AgentWorkflowWire.version }
        ) { command in
            guard let connection else { throw ViewerRelayClientError.notConnected }
            let response = try await connection.relayClient.sendCommand(command, paneId: "", timeout: 30).get()
            guard response.success, let workflow = response.agentWorkflow else {
                throw AgentWorkflowError(response.error ?? "The Host did not return workflow data.")
            }
            return workflow
        }
    }
}
