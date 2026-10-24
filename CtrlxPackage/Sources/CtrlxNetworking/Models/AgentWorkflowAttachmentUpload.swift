import Foundation

public enum AgentWorkflowAttachmentUpload: Codable, Equatable, Sendable {
    case begin(id: UUID, name: String, mediaType: String, size: Int)
    case append(id: UUID, offset: Int, data: Data)
    case finish(id: UUID, sha256: String)
    case cancel(id: UUID)

    public var id: UUID {
        switch self {
        case let .begin(id, _, _, _),
             let .append(id, _, _),
             let .finish(id, _),
             let .cancel(id): id
        }
    }
}

public extension AgentWorkflowDefinition {
    var attachmentIDs: Set<UUID> {
        Set(initialInput.attachmentIDs + nodes.flatMap(\.input.attachmentIDs))
    }
}

public extension AgentWorkflowRun {
    var attachmentIDs: Set<UUID> {
        definition.attachmentIDs.union(invocations.flatMap {
            $0.delivery.input.attachmentIDs + ($0.sharedAttachmentIDs ?? []) + ($0.result?.attachmentIDs ?? [])
        })
    }
}
