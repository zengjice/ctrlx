import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation

extension CodexPluginCore: AgentModelProviding {
    public nonisolated var modelComposer: AgentWorkflowComposer {
        workflowComposer
    }

    public nonisolated func modelRuntimeIssue(_ context: AgentModelContext) -> String? {
        guard let version = context.invocation.version, !version.isEmpty else {
            return "The Codex CLI version could not be read. Restart the Agent and resume this conversation, or use /model in this terminal."
        }
        guard version.hasPrefix("codex-cli "), version != "codex-cli " else {
            return "Unrecognized Codex CLI version (\(version)). Use /model in this terminal."
        }
        return nil
    }

    public func modelOptions(_ context: AgentModelContext) async throws -> [AgentModelOption] {
        if let issue = modelRuntimeIssue(context) {
            throw AgentModelError(issue)
        }
        @Dependency(ProcessRunner.self) var runner
        var args = ["-C", context.directory, context.invocation.executable, "debug", "models"]
        // Copy configuration selectors, never the original prompt/resume action.
        let source = context.invocation.arguments
        var index = 0
        while index < source.count {
            let value = source[index]
            if ["-c", "--config"].contains(value), index + 1 < source.count {
                args += [value, source[index + 1]]
                index += 2
            } else if value.hasPrefix("--config=") {
                args.append(value)
                index += 1
            } else if ["-p", "--profile"].contains(value) || value.hasPrefix("--profile=") {
                throw AgentModelError("Model discovery for a Codex --profile launch is not available yet. Use /model in this terminal.")
            } else {
                index += 1
            }
        }
        let result: ProcessResult
        do {
            result = try await runner.runWithExactEnvironment("/usr/bin/env", args, context.environment, 15, 8 * 1_024 * 1_024, nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AgentModelError("Codex model discovery failed (\(context.invocation.version ?? "unknown version")). Use /model in this terminal.")
        }
        guard result.isSuccess, !result.outputTruncated else {
            throw AgentModelError("Codex model discovery failed (\(context.invocation.version ?? "unknown version")). Use /model in this terminal.")
        }
        do {
            return try CodexModelCatalog.parse(result.stdout)
        } catch {
            throw AgentModelError("Codex returned an incompatible model catalog (\(context.invocation.version ?? "unknown version")). Use /model in this terminal.")
        }
    }

    public nonisolated func modelSelection(lines: [String], models: [AgentModelOption]) -> AgentModelSelection? {
        for line in lines.reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            for model in models {
                guard text.hasPrefix(model.name + " "), text.contains(" · ") else { continue }
                let value = text.dropFirst(model.name.count + 1).split(separator: " ").first.map(String.init)
                if value == "default" {
                    return .init(model: model.id, effort: model.defaultEffort)
                }
                guard let value, model.efforts.contains(value) else { continue }
                return .init(model: model.id, effort: value)
            }
        }
        return nil
    }

    public nonisolated func modelSwitchIssue(lines: [String], models: [AgentModelOption]) -> String? {
        guard modelSelection(lines: lines, models: models)?.effort != nil else {
            return "Codex's status line does not expose its model and effort. Restore them or use /model in this terminal."
        }
        return nil
    }

    public func selectModel(_ selection: AgentModelSelection, models: [AgentModelOption], terminal: AgentModelTerminal) async throws -> AgentModelSelection {
        guard
            let model = models.first(where: { $0.id == selection.model }),
            let effort = selection.effort ?? model.defaultEffort,
            model.efforts.contains(effort), Self.safeModelArgument(model.id), Self.safeModelArgument(effort) else {
            throw AgentModelError("This model or effort is no longer available.")
        }
        if let issue = try modelSwitchIssue(lines: await terminal.read(), models: models) {
            throw AgentModelError(issue)
        }
        let expected = AgentModelSelection(model: model.id, effort: effort)
        try await terminal.submit("/model \(model.id) --reasoning=\(effort)")
        return try await terminal.wait { [self] lines in
            modelSelection(lines: lines, models: models) == expected ? expected : nil
        }
    }

    private nonisolated static func safeModelArgument(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count < 200 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }
}

enum CodexModelCatalog {
    private struct Catalog: Decodable {
        let models: [Model]
        struct Model: Decodable {
            let slug: String
            let display_name: String
            let visibility: String
            let default_reasoning_level: String?
            let supported_reasoning_levels: [Effort]
        }

        struct Effort: Decodable { let effort: String }
    }

    static func parse(_ data: Data) throws -> [AgentModelOption] {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        let models = catalog.models.filter { $0.visibility == "list" }.map {
            AgentModelOption(id: $0.slug, name: $0.display_name, efforts: $0.supported_reasoning_levels.map(\.effort), defaultEffort: $0.default_reasoning_level)
        }
        guard !models.isEmpty, models.count <= 100, Set(models.map(\.id)).count == models.count else {
            throw AgentModelError("Codex returned an empty or ambiguous model catalog.")
        }
        return models
    }
}
