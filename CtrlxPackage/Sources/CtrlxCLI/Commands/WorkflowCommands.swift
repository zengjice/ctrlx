import ArgumentParser
import Foundation

struct WorkflowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workflow",
        abstract: "Read task attachments or request workflow completion",
        subcommands: [WorkflowFinishCommand.self, WorkflowAttachmentsCommand.self]
    )
}

struct WorkflowAttachmentsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attachments", abstract: "Get verified files authorized for this Agent invocation",
        discussion: """
        Returns authorized Host-local paths, media types and checksums for the current invocation. Read returned images with an image-reading tool and text files with a file-reading tool; the listing itself contains metadata, not image pixels.
        If a file cannot be read, report the limitation. Audio and video require a supported conversion. Use only the invocation UUID supplied with this task.
        """
    )

    @Option(name: .long, help: "Invocation UUID supplied with this workflow task") var invocation: String
    @OptionGroup var options: GlobalOptions

    func parameters() throws -> [String: JSONValue] {
        guard options.pane == nil, options.session == nil, options.window == nil else {
            throw ValidationError("Workflow authority comes from the calling Agent; target overrides are not supported.")
        }
        guard let id = UUID(uuidString: invocation) else {
            throw ValidationError("--invocation must be the UUID supplied with this workflow task.")
        }
        return ["invocationId": .string(id.uuidString)]
    }

    func run() throws {
        let response = try executeRequest(
            method: "workflow.attachments",
            params: parameters(),
            options: options,
            timeoutSeconds: 30,
            responseLimit: 256 * 1_024
        )
        printResponse(response, json: true)
    }
}

struct WorkflowFinishCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "finish",
        abstract: "Request completion of an authorized workflow invocation",
        discussion: """
        Available only when the current step grants completion permission. The Host validates the calling Agent, invocation and grant; knowing a UUID does not grant authority.
        Completion conditions come from the workflow's configured task or step instructions. This command does not define business criteria.
        Success records a completion request. The workflow completes after the Host verifies the current turn's final result. A paused workflow remains paused until an operator continues it. This command does not kill Agents.
        """
    )

    @Option(name: .long, help: "Invocation UUID supplied with this workflow task") var invocation: String

    @Option(name: .long, help: "Why this workflow should finish") var reason: String

    @OptionGroup var options: GlobalOptions

    func parameters() throws -> [String: JSONValue] {
        guard options.pane == nil, options.session == nil, options.window == nil else {
            throw ValidationError("Workflow authority comes from the calling Agent; target overrides are not supported.")
        }
        guard let id = UUID(uuidString: invocation) else {
            throw ValidationError("--invocation must be the UUID supplied with this workflow task.")
        }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.utf8.count <= 8_192 else {
            throw ValidationError("--reason must contain 1–8192 UTF-8 bytes of nonblank text.")
        }
        return ["invocationId": .string(id.uuidString), "reason": .string(reason)]
    }

    func run() throws {
        let response = try executeRequest(
            method: "workflow.finish", params: parameters(), options: options,
            timeoutSeconds: 30, responseLimit: 64 * 1_024
        )
        if options.json {
            printResponse(response, json: true)
        } else if let message = response.result?["message"]?.stringValue {
            print(message)
        }
    }
}
