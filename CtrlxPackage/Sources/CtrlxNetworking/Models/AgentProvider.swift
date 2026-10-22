import Foundation

/// A Provider choice shown by a Viewer. Provider configuration and credentials
/// stay on the Host; the Viewer only sends the selected identifier back.
public struct AgentProviderOption: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
