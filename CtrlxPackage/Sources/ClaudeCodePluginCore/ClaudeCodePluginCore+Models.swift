import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation

extension ClaudeCodePluginCore: AgentModelProviding {
    public nonisolated var modelComposer: AgentWorkflowComposer {
        workflowComposer
    }

    public nonisolated func modelRuntimeIssue(_ context: AgentModelContext) -> String? {
        guard context.invocation.version == "2.1.310 (Claude Code)" else {
            return "Model shortcuts require a verified Claude Code version (2.1.310)."
        }
        if let effort = context.environment["CLAUDE_CODE_EFFORT_LEVEL"], !effort.isEmpty, effort != "auto" {
            return "CLAUDE_CODE_EFFORT_LEVEL fixes this session's effort. Use Claude Code's native controls."
        }
        if context.invocation.arguments.contains(where: { $0 == "--settings" || $0.hasPrefix("--settings=") }) {
            return "Model discovery with inline Claude Code settings is not supported. Use /model in this terminal."
        }
        return nil
    }

    public func modelOptions(_ context: AgentModelContext) async throws -> [AgentModelOption] {
        @Dependency(ProcessRunner.self) var runner
        var args = ["-C", context.directory, context.invocation.executable, "-p", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json", "--no-session-persistence"]
        // A metadata-only SDK handshake; no prompt, tools, hooks or conversation.
        let source = context.invocation.arguments
        let selectors = ["--model", "--setting-sources", "--effort"]
        var index = 0
        while index < source.count {
            let value = source[index]
            if selectors.contains(value), index + 1 < source.count {
                args += [value, source[index + 1]]
                index += 2
            } else if selectors.contains(where: { value.hasPrefix($0 + "=") }) {
                args.append(value)
                index += 1
            } else {
                index += 1
            }
        }
        args += ["--settings", "{\"disableAllHooks\":true}", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"]
        var environment = context.environment
        environment.removeValue(forKey: "CLAUDECODE")
        let input = Data("{\"type\":\"control_request\",\"request_id\":\"ctrlx-models\",\"request\":{\"subtype\":\"initialize\"}}\n".utf8)
        let result = try await runner.runWithExactEnvironment("/usr/bin/env", args, environment, 15, 2 * 1_024 * 1_024, input)
        guard result.isSuccess, !result.outputTruncated else {
            throw AgentModelError("Claude Code could not return its model catalog. Use /model in this terminal.")
        }
        return try ClaudeModelCatalog.parse(result.stdout)
    }

    public nonisolated func modelSelection(lines: [String], models: [AgentModelOption]) -> AgentModelSelection? {
        if let menu = ClaudeModelMenu(lines: lines, models: models), let current = menu.current {
            return .init(model: current, effort: menu.focused == current ? menu.effort : nil)
        }
        guard let header = lines.firstIndex(where: { $0.contains("Claude Code v") }), header + 1 < lines.count else { return nil }
        let text = lines[header + 1]
        guard let model = models.first(where: { model in model.screenNames.contains { text.contains($0 + " · ") || text.contains($0 + " with ") } }) else { return nil }
        let effort = model.efforts.first { text.contains(" with \($0) effort") }
            ?? model.efforts.first { value in lines.suffix(8).contains { $0.contains(" \(value) · /effort") } }
        return .init(model: model.id, effort: effort)
    }

    public nonisolated func isModelPicker(lines: [String], models: [AgentModelOption]) -> Bool {
        ClaudeModelMenu(lines: lines, models: models) != nil
    }

    public func selectModel(_ selection: AgentModelSelection, models: [AgentModelOption], terminal: AgentModelTerminal) async throws -> AgentModelSelection {
        guard
            let model = models.first(where: { $0.id == selection.model }),
            selection.effort.map(model.efforts.contains) ?? true else {
            throw AgentModelError("This model or effort is no longer available.")
        }
        try await terminal.submit("/model")
        let menu = try await terminal.wait { ClaudeModelMenu(lines: $0, models: models) }
        guard let target = menu.positions[model.id] else {
            try await terminal.send([.escape])
            throw AgentModelError("The native model menu differs from the catalog. Refresh the model list.")
        }
        try await terminal.send([.home, .delay(80)] + Array(repeating: [TmuxKey.down, .delay(80)], count: target - 1).flatMap { $0 })
        let focused = try await terminal.wait { lines -> ClaudeModelMenu? in
            guard let value = ClaudeModelMenu(lines: lines, models: models), value.focused == model.id else { return nil }
            return value
        }
        if
            let effort = selection.effort, let current = focused.effort,
            let from = model.efforts.firstIndex(of: current), let to = model.efforts.firstIndex(of: effort) {
            let key: TmuxKey = to > from ? .right : .left
            try await terminal.send(Array(repeating: [key, .delay(80)], count: abs(to - from)).flatMap { $0 })
            _ = try await terminal.wait { lines in
                ClaudeModelMenu(lines: lines, models: models)?.effort == effort ? true : nil
            }
        } else if selection.effort != nil {
            throw AgentModelError("Claude Code did not expose a recognized effort control. Nothing was selected.")
        }
        // Enter persists defaults; 's' is the native session-only action.
        try await terminal.send([.text("s")])
        _ = try await terminal.wait { lines in
            !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Select model" })
                && lines.contains(where: { $0.replacingOccurrences(of: "\u{a0}", with: " ").trimmingCharacters(in: .whitespaces) == "❯" }) ? true : nil
        }
        // Reopen to read the actual current checkmark, not a stale local-command
        // transcript or an optimistic selection of the requested row.
        try await terminal.submit("/model")
        let confirmed = try await terminal.wait { lines -> AgentModelSelection? in
            guard
                let current = ClaudeModelMenu(lines: lines, models: models),
                current.current == model.id, current.focused == model.id,
                selection.effort == nil || current.effort == selection.effort else { return nil }
            return .init(model: model.id, effort: current.effort)
        }
        try await terminal.send([.escape])
        _ = try await terminal.wait { lines in
            !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Select model" })
                && lines.contains(where: { $0.replacingOccurrences(of: "\u{a0}", with: " ").trimmingCharacters(in: .whitespaces) == "❯" }) ? true : nil
        }
        return confirmed
    }
}

struct ClaudeModelMenu: Sendable {
    let positions: [String: Int]
    let current: String?
    let focused: String?
    let effort: String?

    init?(lines: [String], models: [AgentModelOption]) {
        guard
            let start = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "Select model" }),
            lines.suffix(from: start).contains(where: { $0.contains("s to use this session only") }) else { return nil }
        var positions: [String: Int] = [:]
        var current: String?
        var focused: String?
        var effort: String?
        for line in lines.suffix(from: start) {
            let value = line.trimmingCharacters(in: .whitespaces)
            let row = value.hasPrefix("❯ ") ? String(value.dropFirst(2)) : value
            if let dot = row.firstIndex(of: "."), let position = Int(row[..<dot]), position > 0, position <= 100 {
                let title = row[row.index(after: dot)...].trimmingCharacters(in: .whitespaces)
                if
                    let model = models.first(where: { model in
                        ([model.name] + model.screenNames).contains { name in
                            guard title.hasPrefix(name) else { return false }
                            let rest = title.dropFirst(name.count)
                            return rest.hasPrefix("  ") || rest.hasPrefix(" ✔") || rest.isEmpty
                        }
                    }) {
                    positions[model.id] = position
                    if title.contains("✔") {
                        current = model.id
                    }
                    if value.hasPrefix("❯ ") {
                        focused = model.id
                    }
                }
            }
            if value.contains("←/→"), value.count > 2, let marker = value.range(of: " effort") {
                effort = String(value[value.index(value.startIndex, offsetBy: 2)..<marker.lowerBound]).lowercased()
            }
        }
        guard !positions.isEmpty, focused != nil else { return nil }
        self.positions = positions
        self.current = current
        self.focused = focused
        self.effort = effort
    }
}

enum ClaudeModelCatalog {
    static func parse(_ data: Data) throws -> [AgentModelOption] {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard
                let message = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                message["type"] as? String == "control_response",
                let envelope = message["response"] as? [String: Any],
                let response = envelope["response"] as? [String: Any],
                let values = response["models"] as? [[String: Any]] else { continue }
            var models: [AgentModelOption] = []
            for value in values {
                guard let alias = value["value"] as? String, let name = value["displayName"] as? String else { continue }
                let id = value["resolvedModel"] as? String ?? alias
                let description = value["description"] as? String ?? ""
                let screenName = description.components(separatedBy: " · ").first ?? name
                let efforts = value["supportedEffortLevels"] as? [String] ?? []
                if let existing = models.firstIndex(where: { $0.id == id }) {
                    let previous = models[existing]
                    models[existing] = .init(id: id, name: alias == "default" ? previous.name : name, efforts: efforts, defaultEffort: nil, screenNames: previous.screenNames + [name, screenName])
                } else {
                    models.append(.init(id: id, name: name, efforts: efforts, defaultEffort: nil, screenNames: [name, screenName]))
                }
            }
            guard !models.isEmpty, models.count <= 100, Set(models.map(\.id)).count == models.count else { break }
            return models
        }
        throw AgentModelError("Claude Code returned an empty or ambiguous model catalog.")
    }
}
