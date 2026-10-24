import ArgumentParser
import Foundation
import Testing
@testable import CtrlxCLI

struct WorkflowCommandTests {
    @Test
    func shareUsesTheAuthenticatedInvocationAndLocalFile() throws {
        let id = UUID()
        let command = try WorkflowShareCommand.parse(["--invocation", id.uuidString, "--file", "report.md", "--json"])
        #expect(try command.invocationID() == id)
        #expect(command.file == "report.md")
        #expect(try CtrlxCLI.parseAsRoot(["workflow", "share", "--invocation", id.uuidString, "--file", "report.md"]) is WorkflowShareCommand)
        for flag in ["--pane", "--session", "--window"] {
            let invalid = try WorkflowShareCommand.parse(["--invocation", id.uuidString, "--file", "report.md", flag, "other"])
            #expect(throws: (any Error).self) { try invalid.invocationID() }
        }
    }

    @Test
    func attachmentsCarryOnlyTheCurrentInvocation() throws {
        let id = UUID()
        let command = try WorkflowAttachmentsCommand.parse(["--invocation", id.uuidString, "--json"])
        #expect(try command.parameters() == ["invocationId": .string(id.uuidString)])
        #expect(try CtrlxCLI.parseAsRoot(["workflow", "attachments", "--invocation", id.uuidString]) is WorkflowAttachmentsCommand)
        for flag in ["--pane", "--session", "--window"] {
            let overridden = try WorkflowAttachmentsCommand.parse(["--invocation", id.uuidString, flag, "other"])
            #expect(throws: (any Error).self) { try overridden.parameters() }
        }
        let invalid = try WorkflowAttachmentsCommand.parse(["--invocation", "not-an-id"])
        #expect(throws: (any Error).self) { try invalid.parameters() }
    }

    @Test
    func finishCarriesExactInvocationAndLiteralReason() throws {
        let invocation = UUID()
        let reason = "审查通过\n$skill / literal; text"
        let command = try WorkflowFinishCommand.parse(["--invocation", invocation.uuidString, "--reason", reason])
        #expect(try command.parameters() == ["invocationId": .string(invocation.uuidString), "reason": .string(reason)])
        #expect(try CtrlxCLI.parseAsRoot(["workflow", "finish", "--invocation", invocation.uuidString, "--reason", reason]) is WorkflowFinishCommand)
    }

    @Test(arguments: ["--pane", "--session", "--window"])
    func finishCannotTargetAnotherAgent(_ flag: String) throws {
        let command = try WorkflowFinishCommand.parse(["--invocation", UUID().uuidString, "--reason", "Done", flag, "other"])
        #expect(throws: (any Error).self) { try command.parameters() }
    }

    @Test(arguments: ["", "not-a-uuid", "%1"])
    func invalidInvocationIsRejectedBeforeConnecting(_ id: String) throws {
        let command = try WorkflowFinishCommand.parse(["--invocation", id, "--reason", "Done"])
        #expect(throws: (any Error).self) { try command.parameters() }
    }

    @Test(arguments: ["", " \n", String(repeating: "猫", count: 2_731)])
    func reasonUsesUTF8ByteLimit(_ reason: String) throws {
        let command = try WorkflowFinishCommand.parse(["--invocation", UUID().uuidString, "--reason", reason])
        #expect(throws: (any Error).self) { try command.parameters() }
    }
}
