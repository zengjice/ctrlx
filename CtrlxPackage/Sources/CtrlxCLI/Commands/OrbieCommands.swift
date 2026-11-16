import ArgumentParser
import Foundation

struct OrbieCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "orbie", abstract: "Read associated Agents and Workflows from the verified Orbie Agent", subcommands: [OrbieAgentsCommand.self, OrbieWorkflowsCommand.self])
}

struct OrbieAgentsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "agents", subcommands: [OrbieAgentsListCommand.self, OrbieAgentsShowCommand.self])
}

struct OrbieWorkflowsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "workflows", subcommands: [OrbieWorkflowsListCommand.self, OrbieWorkflowsShowCommand.self])
}

struct OrbieQueryOptions: ParsableArguments {
    @Option var query: String?
    @Option var limit = 8
    @Option var since: String?
    @OptionGroup var options: GlobalOptions
    func parameters() throws -> [String: JSONValue] {
        try validateOrbieTargets(options)
        guard (query?.utf8.count ?? 0) <= 256, (1...12).contains(limit), since == nil || ISO8601DateFormatter().date(from: since ?? "") != nil else {
            throw ValidationError("Use query up to 256 UTF-8 bytes, limit 1–12, and an ISO-8601 --since timestamp.")
        }
        var params: [String: JSONValue] = ["query": .string(query ?? ""), "limit": .int(limit)]
        if let since {
            params["since"] = .string(since)
        }
        return params
    }
}

struct OrbieAgentsListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list")
    @OptionGroup var queryOptions: OrbieQueryOptions
    func parameters() throws -> [String: JSONValue] {
        try queryOptions.parameters()
    }

    func run() throws {
        try printResponse(executeRequest(method: "orbie.agents.list", params: parameters(), options: queryOptions.options, timeoutSeconds: 30, responseLimit: 128 * 1_024), json: true)
    }
}

struct OrbieWorkflowsListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list")
    @OptionGroup var queryOptions: OrbieQueryOptions
    @Option var tag: String?
    func run() throws {
        var params = try queryOptions.parameters()
        if let tag {
            params["tag"] = .string(tag)
        }
        try printResponse(executeRequest(method: "orbie.workflows.list", params: params, options: queryOptions.options, timeoutSeconds: 30, responseLimit: 128 * 1_024), json: true)
    }
}

struct OrbieAgentsShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show")
    @Argument(help: "HOST_UUID/PANE_UUID from agents list") var id: String
    @OptionGroup var options: GlobalOptions
    func parameters() throws -> [String: JSONValue] {
        try validateOrbieTargets(options)
        let parts = id.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ UUID(uuidString: String($0)) != nil }) else { throw ValidationError("Choose a Host/Pane identity from orbie agents list.") }
        return ["id": .string(id)]
    }

    func run() throws {
        try printResponse(executeRequest(method: "orbie.agents.show", params: parameters(), options: options, timeoutSeconds: 30, responseLimit: 32 * 1_024), json: true)
    }
}

struct OrbieWorkflowsShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show")
    @Argument var id: String
    @OptionGroup var options: GlobalOptions
    func run() throws {
        try validateOrbieTargets(options)
        guard UUID(uuidString: id) != nil else { throw ValidationError("Choose a Workflow UUID from orbie workflows list.") }
        try printResponse(executeRequest(method: "orbie.workflows.show", params: ["id": .string(id)], options: options, timeoutSeconds: 30, responseLimit: 32 * 1_024), json: true)
    }
}

private func validateOrbieTargets(_ options: GlobalOptions) throws {
    guard options.pane == nil, options.session == nil, options.window == nil else { throw ValidationError("Orbie queries authenticate the calling Agent. Target overrides are not supported.") }
}
