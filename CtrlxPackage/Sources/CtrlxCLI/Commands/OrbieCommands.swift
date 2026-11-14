import ArgumentParser
import Foundation

struct OrbieCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "orbie", abstract: "Read saved local tasks from the verified Orbie Agent", subcommands: [OrbieTasksCommand.self])
}

struct OrbieTasksCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tasks", abstract: "Find saved tasks without resuming or sending to them", subcommands: [OrbieTasksListCommand.self, OrbieTasksShowCommand.self])
}

struct OrbieTasksListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List bounded task summaries; authority comes from the calling Orbie process")
    @Option(help: "Task or project keywords (up to 256 UTF-8 bytes)") var query: String?
    @Option(help: "Maximum task count, 1–12") var limit = 8
    @Option(help: "Only tasks updated since this ISO-8601 timestamp") var since: String?
    @Flag(help: "Include manually archived tasks") var includeArchived = false
    @OptionGroup var options: GlobalOptions

    func parameters() throws -> [String: JSONValue] {
        try validateOrbieTargets(options)
        guard (query?.utf8.count ?? 0) <= 256, (1...12).contains(limit), since == nil || ISO8601DateFormatter().date(from: since ?? "") != nil else {
            throw ValidationError("Use query up to 256 UTF-8 bytes, limit 1–12, and an ISO-8601 --since timestamp.")
        }
        var params: [String: JSONValue] = ["query": .string(query ?? ""), "limit": .int(limit), "includeArchived": .bool(includeArchived)]
        if let since {
            params["since"] = .string(since)
        }
        return params
    }

    func run() throws {
        try printResponse(executeRequest(method: "orbie.tasks.list", params: parameters(), options: options, timeoutSeconds: 30, responseLimit: 128 * 1_024), json: true)
    }
}

struct OrbieTasksShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show one saved task and its Agent report references")
    @Argument(help: "Task UUID returned by list") var taskID: String
    @OptionGroup var options: GlobalOptions

    func parameters() throws -> [String: JSONValue] {
        try validateOrbieTargets(options)
        guard let id = UUID(uuidString: taskID) else { throw ValidationError("Provide a saved task UUID from orbie tasks list.") }
        return ["taskId": .string(id.uuidString)]
    }

    func run() throws {
        try printResponse(executeRequest(method: "orbie.tasks.show", params: parameters(), options: options, timeoutSeconds: 30, responseLimit: 32 * 1_024), json: true)
    }
}

private func validateOrbieTargets(_ options: GlobalOptions) throws {
    guard options.pane == nil, options.session == nil, options.window == nil else {
        throw ValidationError("Orbie queries authenticate the calling Agent. Target overrides are not supported.")
    }
}
