import Crypto
import CtrlxEncryption
import Foundation
import Testing
@testable import CtrlxNetworking

struct AgentWorkflowAttachmentWireTests {
    @Test
    func largestSingleImageRequestFitsTheEncryptedRelayEnvelope() throws {
        let id = UUID(), hostID = UUID()
        func command(_ size: Int) -> ManageAgentWorkflows {
            .init(.uploadAttachment(.image(id: id, name: "image.png", mediaType: "image/png", data: Data(repeating: 255, count: size), sha256: String(repeating: "a", count: 64))), expectedHostID: hostID)
        }
        let encoder = JSONEncoder()
        var lower = 0, upper = SendDroppedFiles.maxRawBytes
        while lower < upper {
            let middle = (lower + upper + 1) / 2
            if try encoder.encode(command(middle)).count <= AgentWorkflowWire.imageEncodedBytes {
                lower = middle
            } else {
                upper = middle - 1
            }
        }
        let request = command(lower)
        #expect(try encoder.encode(request).count <= request.maximumEncodedBytes)
        #expect(try encoder.encode(command(lower + 1)).count > request.maximumEncodedBytes)
        let message = WebSocketMessage.command(.init(id: UUID(), paneId: "", command: request.commandType))
        let key = SymmetricKey(size: .bits256)
        let bytes = try encoder.encode(message)
        let sealed = try ChaChaPoly.seal(bytes, using: key)
        let envelope = WebSocketMessage.encrypted(EncryptedWebSocketMessage(payload: EncryptedPayload(ciphertext: sealed.combined, senderKeyId: UUID().uuidString)))
        #expect(try encoder.encode(envelope).count < RelayPayloadLimits.maxWebSocketFrameBytes)
    }

    @Test
    func slashHeavyChunkFitsRequestBudget() throws {
        let command = ManageAgentWorkflows(.uploadAttachment(.append(
            id: UUID(),
            offset: 0,
            data: Data(repeating: 255, count: AgentWorkflowWire.attachmentChunkBytes)
        )), expectedHostID: UUID())
        let encoded = try JSONEncoder().encode(command)
        #expect(encoded.count < AgentWorkflowWire.maximumEncodedBytes)
        #expect(try JSONDecoder().decode(ManageAgentWorkflows.self, from: encoded) == command)
        #expect(command.operation.isMutation)
        #expect(!ManageAgentWorkflows.Operation.attachments([UUID()]).isMutation)
        #expect(ManageAgentWorkflows.Operation.discardAttachments([UUID()]).isMutation)
    }
}
