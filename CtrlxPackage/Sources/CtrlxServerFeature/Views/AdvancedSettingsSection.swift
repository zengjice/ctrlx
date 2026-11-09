import AppKit
import SwiftUI

struct AdvancedSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator
    @Bindable var drafts: SettingsDrafts
    @Environment(\.settingsSearchSection) private var searchSection
    @Environment(\.settingsSearchRequestID) private var searchRequestID
    @State private var tmuxExpanded = false
    @State private var diagnosticsExpanded = false

    private var draft: TmuxSettingsDraft {
        drafts.tmux ?? settings.savedTmuxConfiguration
    }

    private var draftBinding: Binding<TmuxSettingsDraft> {
        Binding(get: { draft }, set: { value in
            guard value != draft else { return }
            drafts.tmux = value
            errorMessage = nil
        })
    }

    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var settings = settings
        Section("Advanced") {
            DisclosureGroup("tmux Configuration", isExpanded: $tmuxExpanded) {
                tmuxFields
            }
            .settingsAnchor(.tmux)
            DisclosureGroup("Diagnostics", isExpanded: $diagnosticsExpanded) {
                Toggle("Debug Mode", isOn: $settings.debugModeEnabled)
                    .accessibilityIdentifier("debug-mode-toggle")
                Text("Show additional diagnostic information across CtrlX. Off by default on this device. Browser recording diagnostics stay local; turning this off keeps existing logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .settingsAnchor(.diagnostics)
        }
        .onChange(of: searchRequestID, initial: true) { _, _ in
            if searchSection == .tmux {
                tmuxExpanded = true
            }
            if searchSection == .diagnostics {
                diagnosticsExpanded = true
            }
        }
        .onChange(of: drafts.tmux) { _, draft in
            if draft == nil {
                errorMessage = nil
            }
        }
    }

    private var tmuxFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Path to tmux", text: draftBinding.tmuxPath)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings-tmux-path")
                    .onSubmit { Task { await save() } }
                    .onExitCommand { drafts.tmux = nil
                        errorMessage = nil
                    }
                Button("Browse…", action: browse)
            }
            TextField("Socket (empty for default)", text: draftBinding.socketPath)
                .accessibilityIdentifier("settings-tmux-socket")
                .onExitCommand { drafts.tmux = nil
                    errorMessage = nil
                }
                .onSubmit { Task { await save() } }
            Button(isSaving ? "Validating…" : "Save for Next Launch") {
                Task { await save() }
            }
            .disabled(isSaving || draft == settings.savedTmuxConfiguration)
            .accessibilityIdentifier("settings-tmux-save")
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            if settings.pendingTmuxConfiguration != nil {
                Text("Saved. Restart CtrlX to use this tmux configuration.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-tmux-restart")
            }
            Text("Save to apply after restarting CtrlX. Unapplied edits are kept while switching pages and discarded when this window closes. Escape reverts the fields.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(isSaving)
    }

    private func save() async {
        guard !isSaving, draft != settings.savedTmuxConfiguration else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await coordinator.saveTmuxConfigurationForNextLaunch(draft)
            drafts.tmux = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the tmux executable"
        panel.directoryURL = URL(fileURLWithPath: draft.tmuxPath).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            drafts.tmux = TmuxSettingsDraft(tmuxPath: url.path, socketPath: draft.socketPath)
        }
    }
}
