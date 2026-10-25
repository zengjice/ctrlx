import CtrlxCommon
import Foundation

/// Builds the per-Provider model catalog that makes Codex's native `/model`
/// command aware of a custom Provider's model and reasoning levels.
enum CodexProviderModelCatalog {
    static let maximumBundledCatalogBytes = 4 * 1_024 * 1_024
    static let commandTimeout: TimeInterval = 30

    static func write(
        provider: CodexProviderProfile,
        command: String,
        stateDirectory: URL,
        processRunner: ProcessRunner
    ) async throws -> URL {
        let result = try await processRunner.runBounded(
            "/usr/bin/env",
            [command, "debug", "models", "--bundled"],
            nil,
            commandTimeout,
            maximumBundledCatalogBytes
        )
        guard result.isSuccess else {
            let diagnostic = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CodexProviderModelCatalogError.commandFailed(
                diagnostic.isEmpty ? "exit code \(result.exitCode)" : diagnostic
            )
        }
        guard !result.outputTruncated else {
            throw CodexProviderModelCatalogError.bundledCatalogTooLarge
        }
        guard
            let object = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
            let models = object["models"] as? [[String: Any]],
            var model = models.first
        else {
            throw CodexProviderModelCatalogError.invalidBundledCatalog
        }
        guard let instructions = instructionTemplate(from: model) else {
            throw CodexProviderModelCatalogError.missingInstructions
        }

        model = customModel(from: model, provider: provider, instructions: instructions)
        let catalog = try JSONSerialization.data(
            withJSONObject: ["models": [model]],
            options: [.sortedKeys]
        )
        let directory = stateDirectory.appendingPathComponent("model-catalogs", isDirectory: true)
        let catalogURL = directory.appendingPathComponent("\(provider.id).json", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try catalog.write(to: catalogURL, options: .atomic)
        } catch {
            throw CodexProviderModelCatalogError.writeFailed(error.localizedDescription)
        }
        return catalogURL
    }

    private static func instructionTemplate(from model: [String: Any]) -> String? {
        let messages = model["model_messages"] as? [String: Any]
        let template = messages?["instructions_template"] as? String
        let legacy = model["base_instructions"] as? String
        guard let instructions = template ?? legacy, !instructions.isEmpty else { return nil }
        return instructions
    }

    private static func customModel(
        from template: [String: Any],
        provider: CodexProviderProfile,
        instructions: String
    ) -> [String: Any] {
        var model = template
        model["slug"] = provider.model
        model["display_name"] = provider.model
        model["description"] = "Configured for \(provider.name)"
        model["default_reasoning_level"] = (provider.reasoningEffort ?? .medium).rawValue
        model["supported_reasoning_levels"] = CodexReasoningEffort.allCases.map {
            ["effort": $0.rawValue, "description": $0.catalogDescription]
        }

        // The bundled prompt is preserved, but capability flags and service
        // tiers must describe the configured Responses endpoint rather than the
        // bundled model that supplied the instruction template.
        model["shell_type"] = "unified_exec"
        model["visibility"] = "list"
        model["supported_in_api"] = true
        model["priority"] = 0
        model["additional_speed_tiers"] = [String]()
        model["service_tiers"] = [[String: Any]]()
        model["include_skills_usage_instructions"] = false
        model["include_plugin_usage_instructions"] = false
        model["include_apps_usage_instructions"] = false
        model["supports_reasoning_summary_parameter"] = true
        model["default_reasoning_summary"] = "auto"
        model["support_verbosity"] = false
        model["web_search_tool_type"] = "text"
        model["truncation_policy"] = ["mode": "bytes", "limit": 10_000]
        model["supports_image_detail_original"] = false
        model["context_window"] = 272_000
        model["max_context_window"] = 272_000
        model["effective_context_window_percent"] = 95
        model["experimental_supported_tools"] = [String]()
        model["input_modalities"] = ["text", "image"]
        model["supports_search_tool"] = false
        model["supports_experimental_context"] = false
        model["use_responses_lite"] = false
        model["supports_reasoning_effort_updates"] = false
        model["node_repl_auto_review_required"] = false
        model["node_repl_disabled"] = false
        model["model_messages"] = ["instructions_template": instructions]

        for key in [
            "base_instructions",
            "upgrade",
            "availability_nux",
            "default_service_tier",
            "available_access_programs",
            "default_verbosity",
            "apply_patch_tool_type",
            "auto_compact_token_limit",
            "comp_hash",
            "guardian",
            "auto_review_model_override",
            "model_specialty",
            "tool_mode",
            "multi_agent_version",
            "multi_agent_reasoning_effort",
        ] {
            model.removeValue(forKey: key)
        }
        return model
    }
}

private extension CodexReasoningEffort {
    var catalogDescription: String {
        switch self {
        case .none: "No reasoning"
        case .minimal: "Minimal reasoning"
        case .low: "Fast responses with lighter reasoning"
        case .medium: "Balances speed and reasoning depth for everyday tasks"
        case .high: "Greater reasoning depth for complex problems"
        case .xhigh: "Extra high reasoning depth for complex problems"
        case .max: "Maximum reasoning depth for the hardest problems"
        case .ultra: "Maximum reasoning with automatic task delegation"
        }
    }
}

private enum CodexProviderModelCatalogError: LocalizedError {
    case commandFailed(String)
    case bundledCatalogTooLarge
    case invalidBundledCatalog
    case missingInstructions
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(diagnostic):
            "Codex could not export its bundled model catalog: \(diagnostic)"
        case .bundledCatalogTooLarge:
            "Codex returned an unexpectedly large bundled model catalog."
        case .invalidBundledCatalog:
            "Codex returned an invalid bundled model catalog."
        case .missingInstructions:
            "The bundled model catalog has no instruction template."
        case let .writeFailed(diagnostic):
            "The custom model catalog could not be written: \(diagnostic)"
        }
    }
}
