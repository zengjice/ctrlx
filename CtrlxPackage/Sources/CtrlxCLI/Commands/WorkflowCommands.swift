import ArgumentParser
import Foundation

struct WorkflowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workflow",
        abstract: "Read task attachments, share artifacts or request workflow completion",
        subcommands: [WorkflowFinishCommand.self, WorkflowAttachmentsCommand.self, WorkflowShareCommand.self]
    )
}

struct WorkflowShareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "share", abstract: "Share an immutable file snapshot with this task's downstream Agents")

    @Option(name: .long, help: "Invocation UUID supplied with this workflow task") var invocation: String
    @Option(name: .long, help: "Local image, audio, video or UTF-8 text file to snapshot") var file: String
    @OptionGroup var options: GlobalOptions

    func invocationID() throws -> UUID {
        guard options.pane == nil, options.session == nil, options.window == nil else {
            throw ValidationError("Workflow authority comes from the calling Agent; target overrides are not supported.")
        }
        guard let id = UUID(uuidString: invocation) else {
            throw ValidationError("--invocation must be the UUID supplied with this workflow task.")
        }
        return id
    }

    func run() throws {
        let id = try invocationID()
        do {
            let response = try WorkflowArtifactUpload.send(file: URL(fileURLWithPath: file), invocationID: id) {
                try SocketClient.send($0, socketPath: options.socket, timeoutSeconds: 30, responseLimit: 64 * 1_024)
            }
            printResponse(response, json: true)
        } catch {
            if options.json {
                printResponse(.init(id: id.uuidString, error: .init(code: "workflow_share_failed", message: error.localizedDescription)), json: true)
                throw ExitCode.failure
            }
            throw error
        }
    }
}

struct WorkflowAttachmentsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "attachments", abstract: "Get verified files authorized for this Agent invocation")

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
        abstract: "Request workflow completion, then provide your final Agent answer"
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
