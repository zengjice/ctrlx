import CtrlxNetworking
import Foundation

struct AgentWorkflowArtifactRequest {
    let invocationID: UUID
    let operation: AgentWorkflowAttachmentUpload

    init(_ params: [String: JSONValue]) throws {
        guard
            let invocation = params["invocationId"]?.stringValue.flatMap(UUID.init(uuidString:)),
            let id = params["uploadId"]?.stringValue.flatMap(UUID.init(uuidString:)),
            let action = params["action"]?.stringValue else {
            throw AgentWorkflowError("Expected invocationId, uploadId and an artifact upload action.")
        }
        self.invocationID = invocation
        let base: Set = ["invocationId", "uploadId", "action"]
        let keys = Set(params.keys)
        switch action {
        case "begin":
            guard
                keys == base.union(["name", "mediaType", "size"]),
                let name = params["name"]?.stringValue,
                let type = params["mediaType"]?.stringValue,
                let size = params["size"]?.intValue else {
                throw AgentWorkflowError("Expected artifact name, mediaType and byte size.")
            }
            self.operation = .begin(id: id, name: name, mediaType: type, size: size)
        case "append":
            guard
                keys == base.union(["offset", "data"]),
                let offset = params["offset"]?.intValue, offset >= 0,
                let encoded = params["data"]?.stringValue, encoded.utf8.count <= 4 * ((AgentWorkflowWire.attachmentChunkBytes + 2) / 3),
                let data = Data(base64Encoded: encoded), !data.isEmpty,
                data.count <= AgentWorkflowWire.attachmentChunkBytes else {
                throw AgentWorkflowError("Expected an offset and a Base64 chunk of up to 64 KiB.")
            }
            self.operation = .append(id: id, offset: offset, data: data)
        case "finish":
            guard keys == base.union(["sha256"]), let hash = params["sha256"]?.stringValue else {
                throw AgentWorkflowError("Expected the complete file's SHA-256 digest.")
            }
            self.operation = .finish(id: id, sha256: hash)
        case "cancel":
            guard keys == base else { throw AgentWorkflowError("Unexpected artifact cancellation parameters.") }
            self.operation = .cancel(id: id)
        default:
            throw AgentWorkflowError("Unknown artifact upload action.")
        }
    }
}
