#if os(macOS)
    import AppKit
    import ClaudeCodePluginCore
    import CodexPluginCore
    import CtrlxEncryption
    import CtrlxNetworking
    import CtrlxPluginProtocol
    import Dependencies
    import SwiftUI
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Agent Provider settings") @MainActor
    struct AgentProviderSettingsTests {
        @Test(
            "Generated and existing identities keep credentials and defaults after a rename",
            arguments: ["codex", "claude-code"],
            [false, true]
        )
        func renamePreservesLaunch(pluginID: String, legacy: Bool) async throws {
            var draft = AgentProviderDraft(pluginID: pluginID)
            if legacy {
                if pluginID == "codex" {
                    draft = AgentProviderDraft(profile: CodexProviderProfile(
                        id: "existing-provider", name: "Old name", baseURL: "", model: "", environmentKey: draft.environmentKey
                    ), pluginID: pluginID)
                } else {
                    draft = AgentProviderDraft(profile: ClaudeProviderProfile(
                        id: "existing-provider", name: "Old name", baseURL: "", model: "", authKind: draft.authKind, environmentKey: draft.environmentKey
                    ), pluginID: pluginID)
                }
            }
            draft.name = "团队接入"
            draft.baseURL = "https://api.example.com/v1"
            draft.model = "test-model"
            let providerID = draft.providerID
            let originalSettings = try settings(draft, pluginID: pluginID)
            let secrets = SecretsService.inMemory()
            try await secrets.storeSecret("fixture-key", AgentProviderKeychainAccount.account(pluginID: pluginID, providerID: providerID))

            try await withDependencies {
                $0[SecretsService.self] = secrets
            } operation: {
                let core: any AgentProviderSelecting = pluginID == "codex" ? CodexPluginCore() : ClaudeCodePluginCore()
                _ = await core.applySettings(originalSettings)
                let before = try #require(try await core.commandForLaunch(projectPath: "/fixture", providerID: nil))
                var edited: AgentProviderDraft
                if pluginID == "codex" {
                    let saved = try JSONDecoder().decode(CodexSettings.self, from: originalSettings)
                    edited = try AgentProviderDraft(profile: #require(saved.providers.first), pluginID: pluginID)
                } else {
                    let saved = try JSONDecoder().decode(ClaudeCodeSettings.self, from: originalSettings)
                    edited = try AgentProviderDraft(profile: #require(saved.providers.first), pluginID: pluginID)
                }
                edited.name = "新的显示名称"
                _ = try await core.applySettings(settings(edited, pluginID: pluginID))
                let after = try #require(try await core.commandForLaunch(projectPath: "/fixture", providerID: nil))
                #expect(after.env == before.env)
                #expect(after.env[AgentProviderEnvironment.markerKey] == providerID)
                #expect(after.env[pluginID == "codex" ? "OPENAI_API_KEY" : "ANTHROPIC_AUTH_TOKEN"] == "fixture-key")
                #expect(await core.providerOptions().contains(AgentProviderOption(id: providerID, name: edited.name)))
            }
        }

        @Test("New and renamed Providers reject duplicate names, including the built-in choice")
        func duplicateNames() {
            var draft = AgentProviderDraft(pluginID: "codex")
            let providers = [CodexSettings.builtInProvider, AgentProviderOption(id: "other", name: " Team API ")]
            let add = AgentProviderEditorPresentation(pluginID: "codex", original: nil, providers: providers)
            draft.name = "  team api\n"
            #expect(add.nameValidationError(for: draft) != nil)
            draft.name = CodexSettings.builtInProvider.name.uppercased()
            #expect(add.nameValidationError(for: draft) != nil)
            draft.name = "原来的名称"
            let edit = AgentProviderEditorPresentation(pluginID: "codex", original: draft, providers: providers)
            draft.name = "TEAM API"
            #expect(edit.nameValidationError(for: draft) != nil)
            draft.name = "另一个名称"
            #expect(edit.nameValidationError(for: draft) == nil)
            draft.name = " \n"
            #expect(edit.nameValidationError(for: draft) != nil)
        }

        @Test("Existing duplicate names allow connection edits; separate Agents have independent names")
        func existingNames() {
            var original = AgentProviderDraft(pluginID: "codex")
            original.name = "Team API"
            let edit = AgentProviderEditorPresentation(
                pluginID: "codex", original: original,
                providers: [AgentProviderOption(id: original.providerID, name: original.name), AgentProviderOption(id: "legacy-duplicate", name: original.name)]
            )
            var draft = original
            draft.baseURL = "https://new.example.com"
            #expect(edit.nameValidationError(for: draft) == nil)
            let claude = AgentProviderEditorPresentation(pluginID: "claude-code", original: nil, providers: [ClaudeCodeSettings.builtInProvider])
            var other = AgentProviderDraft(pluginID: "claude-code")
            other.name = original.name
            #expect(claude.nameValidationError(for: other) == nil)
        }

        @Test(
            "Provider forms render without accessing the system Keychain",
            arguments: ["codex", "claude-code"],
            [false, true]
        )
        func renderForm(pluginID: String, editing: Bool) async throws {
            _ = NSApplication.shared
            var original = AgentProviderDraft(pluginID: pluginID)
            original.name = "团队 API"
            original.baseURL = "https://api.example.com/v1"
            original.model = "test-model"
            let presentation = AgentProviderEditorPresentation(pluginID: pluginID, original: editing ? original : nil, providers: [])
            let sheet = withDependencies {
                $0[SecretsService.self] = .inMemory()
            } operation: {
                AgentProviderEditorSheet(presentation: presentation, onSave: { _ in Issue.record("Rendering must not save") })
            }
            let view = NSHostingView(rootView: sheet.environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let folder = ProcessInfo.processInfo.environment["CTRLX_PROVIDER_UI_SNAPSHOTS"] {
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(pluginID)-\(editing ? "edit" : "add").png"))
            }
        }

        private func settings(_ draft: AgentProviderDraft, pluginID: String) throws -> Data {
            if pluginID == "codex" {
                return try JSONEncoder().encode(CodexSettings(exportTelemetry: false, providers: [draft.codexProfile()], defaultProviderID: draft.providerID))
            }
            return try JSONEncoder().encode(ClaudeCodeSettings(providers: [draft.claudeProfile()], defaultProviderID: draft.providerID))
        }
    }
#endif
