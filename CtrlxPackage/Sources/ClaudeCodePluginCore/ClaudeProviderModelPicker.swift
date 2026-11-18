import CtrlxPluginProtocol
import Foundation

/// Only this metadata-only inline setting may be replayed by discovery or recovery.
enum ClaudeProviderModelPicker {
    static func settings(for profile: ClaudeProviderProfile) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "modelPicker": [
                "replaceBuiltInOptions": true,
                "options": profile.modelIDs.map { ["model": $0, "label": $0] },
            ],
        ], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func extracting(from arguments: [String]) throws -> (arguments: [String], settings: [String: Any]?) {
        var remaining: [String] = []
        var settings: [String: Any]?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let value: String
            if argument == "--settings", index + 1 < arguments.count {
                index += 1
                value = arguments[index]
            } else if argument.hasPrefix("--settings=") {
                value = String(argument.dropFirst("--settings=".count))
            } else if argument != "--settings" {
                remaining.append(argument)
                index += 1
                continue
            } else {
                throw AgentModelError("Claude Code's inline model settings are incomplete.")
            }
            guard
                settings == nil,
                let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
                Set(object.keys) == ["modelPicker"],
                let picker = object["modelPicker"] as? [String: Any],
                Set(picker.keys) == ["replaceBuiltInOptions", "options"],
                picker["replaceBuiltInOptions"] as? Bool == true,
                let options = picker["options"] as? [[String: String]],
                !options.isEmpty, options.count <= 100,
                options.allSatisfy({ Set($0.keys) == ["model", "label"] && $0["model"] == $0["label"] && $0["model"].map(AgentProviderModels.isValidID) == true }),
                Set(options.compactMap { $0["model"] }).count == options.count else {
                throw AgentModelError("Only CtrlX Provider model-picker settings are supported here. Use the native terminal for other inline settings.")
            }
            settings = object
            index += 1
        }
        return (remaining, settings)
    }
}
