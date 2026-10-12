import ArgumentParser
import CtrlxSimulatorProtocol
import Dependencies
import Foundation

struct SimulatorBatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch", abstract: "Execute 1...16 simulator argument arrays in one request; stop on the first error")
    @Option(help: "JSON file containing simulator argument arrays, up to 64 KB") var input: String
    @Option var socket: String?

    func prepare(_ data: Data) throws -> (actions: [SimulatorActionCommand], parameters: [String: JSONValue]) {
        guard data.count <= SimulatorBatchLimits.maximumRequestBytes else { throw ValidationError("Batch input exceeds 64 KB") }
        let words = try JSONDecoder().decode([[String]].self, from: data)
        guard (1...SimulatorBatchLimits.maximumActions).contains(words.count) else {
            throw ValidationError("Batch requires 1...16 simulator argument arrays")
        }
        var actions: [SimulatorActionCommand] = []
        var parameters: [JSONValue] = []
        for (index, arguments) in words.enumerated() {
            let action = try SimulatorActionCommand.parse(arguments)
            guard action.socket == nil else { throw ValidationError("Use the batch's --socket, not an action's --socket") }
            guard action.operation != "screenshot" || index == words.count - 1 else {
                throw ValidationError("A batch can contain one screenshot, as its final action")
            }
            parameters.append(.object(try action.parameters()))
            actions.append(action)
        }
        let params: [String: JSONValue] = ["command": .string("batch"), "actions": .array(parameters)]
        let request = JSONRPCRequest(id: UUID().uuidString, method: "simulator.action", params: params)
        guard try JSONEncoder().encode(request).count <= SimulatorBatchLimits.maximumRequestBytes else {
            throw ValidationError("Prepared batch request exceeds 64 KB")
        }
        return (actions, params)
    }

    func execute(_ data: Data) throws -> [String: JSONValue] {
        let prepared = try prepare(data)
        @Dependency(SimulatorCommandClient.self) var client
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let response = try client.send(
            JSONRPCRequest(id: UUID().uuidString, method: "simulator.action", params: prepared.parameters), socket,
            SimulatorBatchLimits.transportSeconds, SimulatorBatchLimits.maximumResponseBytes)
        guard response.ok, var result = response.result else { throw ValidationError(response.error?.message ?? "Simulator batch failed") }
        guard case var .array(rows)? = result["results"], let success = result["success"]?.boolValue,
              result["planned"]?.intValue == prepared.actions.count, let completed = result["completed"]?.intValue,
              (0...prepared.actions.count).contains(completed), rows.count == completed + (success ? 0 : 1),
              success ? completed == prepared.actions.count : result["stoppedAt"]?.intValue == completed else {
            throw ValidationError("Invalid simulator batch results; no actions were retried")
        }
        for (index, value) in rows.enumerated() {
            guard case var .object(row) = value, row["index"]?.intValue == index,
                  row["command"]?.stringValue == prepared.actions[index].operation,
                  row["ok"]?.boolValue == (index < completed) else {
                throw ValidationError("Invalid simulator batch result order; no actions were retried")
            }
            if row["ok"]?.boolValue == true, case let .object(actionResult)? = row["result"] {
                do {
                    row["result"] = .object(try prepared.actions[index].saveScreenshot(actionResult, requestedAt: requestedAt))
                } catch {
                    var metadata = actionResult
                    metadata.removeValue(forKey: "data")
                    row["result"] = .object(metadata)
                    row["ok"] = .bool(false)
                    row["error"] = .object(["code": .string("artifact_error"), "message": .string(error.localizedDescription)])
                    row["outcome"] = .string("action-completed-artifact-failed")
                    result["success"] = .bool(false)
                    result["stoppedAt"] = .int(index)
                }
                rows[index] = .object(row)
            }
        }
        result["results"] = .array(rows)
        return result
    }

    func run() throws {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: input))
        defer { try? file.close() }
        let data = try file.read(upToCount: SimulatorBatchLimits.maximumRequestBytes + 1) ?? Data()
        let result = try execute(data)
        print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
        if result["success"]?.boolValue != true { throw ExitCode.failure }
    }
}
