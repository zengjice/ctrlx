import Foundation
import Testing
@testable import CtrlxNetworking

struct AgentWorkflowAttachmentWireTests {
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
