import ArgumentParser
import Foundation

struct ListProjectsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-projects",
        abstract: "List projects discovered by enabled agents on the host"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(method: "project.list", options: options)
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .array(projects) = result["projects"] {
            for project in projects {
                if
                    case let .object(obj) = project,
                    case let .string(name) = obj["name"],
                    case let .string(path) = obj["path"] {
                    print("\(name)\t\(path)")
                } else {
                    let warning = "warning: skipping project entry missing 'name' or 'path'\n"
                    FileHandle.standardError.write(Data(warning.utf8))
                }
            }
        }
    }
}

struct StartProjectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start-project",
        abstract: "Start a new tmux session for a project and run an agent (default: Codex)"
    )

    @Argument(help: "Project path (the directory to run the agent in)")
    var path: String

    @Argument(parsing: .postTerminator, help: "Agent launch arguments replacing its defaults (pass after `--`)")
    var extraArgs: [String] = []

    @Option(name: .customLong("agent"), help: "Agent plugin ID, e.g. codex or claude-code")
    var pluginID: String = "codex"

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let expandedPath = (path as NSString).expandingTildeInPath
        var params: [String: JSONValue] = ["path": .string(expandedPath), "plugin_id": .string(pluginID)]
        if !extraArgs.isEmpty {
            params["args"] = .array(extraArgs.map { .string($0) })
        }
        let response = try executeRequest(method: "project.start", params: params, options: options)
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .string(id) = result["id"] {
            print("Started session: \(id)")
        }
    }
}
