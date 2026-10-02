import CtrlxCommon
import CtrlxNetworking
import SwiftUI

/// Mac presentation only. The catalog, storage format, input sequence and stale
/// request checks are shared with iOS.
@MainActor
struct TerminalQuickActionButtons: View {
    let router: TerminalQuickActionRouter
    @Environment(AppSettings.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(EditorSessionManager.self) private var editorSessionManager
    @State private var commandPanel: Presentation?
    @State private var phrasePanel: Presentation?

    struct Presentation: Identifiable {
        let id = UUID()
        let token: TerminalQuickActionRouter.Token?
        var command: AgentCommandContext?
        let phrase: TerminalPhraseContext
        let label: String

        mutating func updateCommand(_ current: AgentCommandContext?, terminal: TerminalPhraseContext) -> Bool {
            guard phrase.hasSameInput(as: terminal) else { return false }
            if let command { return command.hasSameInput(as: current) }
            guard let current else { return true }
            guard current.target.hostID == phrase.target.hostID,
                  current.target.paneID == phrase.target.paneID,
                  current.inputRevision == phrase.inputRevision
            else { return false }
            command = current
            return true
        }
    }

    var body: some View {
        Button {
            phrasePanel = nil
            commandPanel = presentation
        } label: {
            Text("/").font(.system(.body, design: .monospaced).bold())
        }
        .help("Agent commands for the focused terminal")
        .accessibilityLabel("Agent Commands")
        .accessibilityIdentifier("terminal-agent-command-control")
        .popover(item: $commandPanel) { captured in
            MacAgentCommandPanel(
                commands: captured.command?.commands ?? [],
                targetLabel: captured.label,
                unavailableReason: commandUnavailableReason,
                send: { command in
                    guard let token = captured.token,
                          let request = AgentCommandRequest(command, in: captured.command),
                          request.isValid(in: commandContext)
                    else { return false }
                    return router.send(command.keys, to: token)
                }
            )
            .task(id: captured.id) {
                guard captured.command == nil, captured.phrase.target.hostID == "local",
                      router.matches(captured.token)
                else { return }
                await coordinator.refreshAgentCommandIdentity()
            }
        }

        Button {
            commandPanel = nil
            phrasePanel = presentation
        } label: {
            Symbols.textBubbleFill.image
        }
        .help("Quick phrases for the focused terminal")
        .accessibilityLabel("Quick Phrases")
        .accessibilityIdentifier("terminal-quick-phrase-control")
        .popover(item: $phrasePanel) { captured in
            MacQuickPhrasePanel(
                store: settings.quickPhrases,
                targetLabel: captured.label,
                unavailableReason: phraseContext.unavailableReason,
                send: { phrase in
                    let request = TerminalPhraseRequest(phrase: phrase, context: captured.phrase)
                    guard let token = captured.token,
                          request.isValid(in: phraseContext, savedPhrases: settings.quickPhrases.phrases)
                    else { return false }
                    return router.send(phrase.keys, to: token)
                }
            )
        }
        .onChange(of: router.token) {
            // Focus changes, pane replacement, keyboard input and a successful
            // send all invalidate the captured action. Never retarget a popover.
            commandPanel = nil
            phrasePanel = nil
        }
        .onChange(of: commandContext?.target) {
            guard var captured = commandPanel else { return }
            commandPanel = captured.updateCommand(commandContext, terminal: phraseContext) ? captured : nil
        }
    }

    private var pane: PaneState? {
        guard let endpoint = router.active, endpoint.isMounted else { return nil }
        if let host = endpoint.hostID {
            return coordinator.remoteSessionStore?.paneState(for: endpoint.paneID, hostId: host)
        }
        return windowManager.paneStates[endpoint.paneID]
    }

    private var isConnected: Bool {
        guard let endpoint = router.active else { return false }
        guard let host = endpoint.hostID else { return pane != nil }
        guard let connection = coordinator.viewerConnectionManager?.connection(for: host) else { return false }
        return connection.isHostConnected && connection.isRelayConnected
    }

    private var hasExternalEditor: Bool {
        guard let pane else { return false }
        return pane.editorSession != nil || (router.active?.hostID == nil
            && editorSessionManager.session(for: pane.paneId) != nil)
    }

    private var commandContext: AgentCommandContext? {
        AgentCommandContext(
            hostID: router.active?.hostID ?? "local", paneID: pane?.paneId,
            session: pane?.agentSession, isConnected: isConnected,
            isInputAvailable: router.active?.isReady == true && router.active?.isAvailable == true,
            hasExternalEditor: hasExternalEditor,
            inputRevision: router.active?.inputRevision ?? 0
        )
    }

    private var commandUnavailableReason: String? {
        if let context = commandContext { return context.unavailableReason }
        return pane == nil
            ? "Select a terminal pane to view agent commands."
            : "No supported agent is currently identified in this pane. Commands will appear when Codex or Claude Code is identified."
    }

    private var phraseContext: TerminalPhraseContext {
        TerminalPhraseContext(
            hostID: router.active?.hostID ?? "local", paneID: pane?.paneId,
            inputRevision: router.active?.inputRevision ?? 0,
            isConnected: isConnected,
            isInputAvailable: router.active?.isReady == true && router.active?.isAvailable == true,
            hasExternalEditor: hasExternalEditor,
            hasBlockingForm: pane?.agentSession?.state.openForm != nil
        )
    }

    private var presentation: Presentation {
        let label: String
        if let pane {
            let host = router.active?.hostID.flatMap {
                coordinator.viewerConnectionManager?.connection(for: $0)?.hostName
            } ?? "This Mac"
            label = "\(host) · \(pane.sessionName):\(pane.windowName) · \(pane.paneId)"
        } else {
            label = "No terminal selected"
        }
        return Presentation(token: router.token, command: commandContext, phrase: phraseContext, label: label)
    }
}

@MainActor
struct TerminalQuickActionStatusBarButtons: View {
    let hostID: String?
    let paneIDs: [String]
    @Environment(\.terminalQuickActions) private var router

    var body: some View {
        if let router {
            let ownsFocus = router.containsFocus(hostID: hostID, paneIDs: paneIDs)
            HStack(spacing: 12) {
                TerminalQuickActionButtons(router: router)
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            // Reserve the controls' height so focus changes never resize terminals.
            .opacity(ownsFocus ? 1 : 0)
            .disabled(!ownsFocus)
            .accessibilityHidden(!ownsFocus)
            .accessibilityIdentifier("terminal-quick-action-status-bar")
        }
    }
}

@MainActor
private struct MacAgentCommandPanel: View {
    let commands: [AgentQuickCommand]
    let targetLabel: String
    let unavailableReason: String?
    let send: @MainActor (AgentQuickCommand) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var hasSubmitted = false
    @State private var error: String?

    private var sections: [AgentCommandSection] {
        AgentCommandSection.sections(for: commands)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Commands").font(.headline)
            Text(targetLabel).font(.caption).foregroundStyle(.secondary)
            if let reason = unavailableReason ?? error {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(sections) { section in
                        if section.id == .sessionActions {
                            Divider()
                            Text("Session Actions").font(.subheadline.weight(.semibold))
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105))], spacing: 8) {
                            ForEach(section.commands) { command in
                                Button {
                                    submit(command)
                                } label: {
                                    Text(command.text).monospaced().frame(maxWidth: .infinity, minHeight: 26)
                                }
                                .accessibilityIdentifier("terminal-agent-command-\(command.id)")
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(section.id == .sessionActions ? Color.red : Color.accentColor)
                        .disabled(unavailableReason != nil || hasSubmitted)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 360)
        }
        .padding(16)
        .frame(width: 380)
    }

    private func submit(_ command: AgentQuickCommand) {
        guard !hasSubmitted else { return }
        if send(command) {
            hasSubmitted = true
            dismiss()
        } else {
            error = "The terminal changed. Reopen the panel to send."
        }
    }
}

@MainActor
private struct MacQuickPhrasePanel: View {
    let store: QuickPhraseStore
    let targetLabel: String
    let unavailableReason: String?
    let send: @MainActor (QuickPhrase) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var showsEditor = false
    @State private var editingPhrase: QuickPhrase?
    @State private var draft = ""
    @State private var error: String?
    @State private var hasSubmitted = false
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Quick Phrases").font(.headline)
                Spacer()
                Button {
                    beginEditing(nil)
                } label: {
                    Label("Add Phrase", symbol: .plus)
                }
                .disabled(store.loadError != nil || showsEditor)
            }
            Text(targetLabel).font(.caption).foregroundStyle(.secondary)
            if let reason = store.loadError ?? error ?? unavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if showsEditor {
                Text(editingPhrase == nil ? "Add Phrase" : "Edit Phrase").font(.subheadline)
                TextField("Single-line phrase", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($isEditorFocused)
                    .onSubmit(savePhrase)
                    .accessibilityIdentifier("quick-phrase-editor")
                HStack {
                    Button("Cancel", action: finishEditing)
                    Spacer()
                    Button("Save", action: savePhrase)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if store.phrases.isEmpty {
                Text("No saved phrases yet.").foregroundStyle(.secondary).padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145))], spacing: 8) {
                        ForEach(store.phrases) { phrase in
                            Button { submit(phrase) } label: {
                                Text(phrase.text)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, minHeight: 30)
                            }
                            .buttonStyle(.bordered)
                            .help(phrase.text)
                            // Keep the button enabled for its context menu while
                            // offline; submission itself checks live availability.
                            .foregroundStyle(unavailableReason == nil ? Color.primary : .secondary)
                            .contextMenu {
                                Button {
                                    beginEditing(phrase)
                                } label: {
                                    Label("Edit", symbol: .pencil)
                                }
                                .disabled(store.loadError != nil || showsEditor)
                                Button(role: .destructive) {
                                    do {
                                        try store.remove(phrase.id)
                                    } catch {
                                        self.error = error.localizedDescription
                                    }
                                } label: {
                                    Label("Delete", symbol: .trash)
                                }
                            }
                            .quickPhraseReordering(phrase, store: store) { error = $0 }
                        }
                    }
                }
                .frame(maxHeight: 280)
                Text("Drag phrases to reorder. Right-click to Edit or Delete.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func savePhrase() {
        do {
            if let editingPhrase {
                try store.update(editingPhrase, text: draft)
            } else {
                try store.add(draft)
            }
            finishEditing()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func beginEditing(_ phrase: QuickPhrase?) {
        editingPhrase = phrase
        draft = phrase?.text ?? ""
        error = nil
        showsEditor = true
        isEditorFocused = true
    }

    private func finishEditing() {
        showsEditor = false
        editingPhrase = nil
        draft = ""
        error = nil
        isEditorFocused = false
    }

    private func submit(_ phrase: QuickPhrase) {
        guard !hasSubmitted, !showsEditor, unavailableReason == nil else { return }
        if send(phrase) {
            hasSubmitted = true
            dismiss()
        } else {
            error = "The terminal changed. Reopen the panel to send."
        }
    }
}
