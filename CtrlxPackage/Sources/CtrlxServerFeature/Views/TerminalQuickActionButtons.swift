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

    private struct Presentation: Identifiable {
        let id = UUID()
        let token: TerminalQuickActionRouter.Token?
        let command: AgentCommandContext?
        let phrase: TerminalPhraseContext
        let label: String
    }

    var body: some View {
        Button {
            phrasePanel = nil
            commandPanel = presentation
        } label: {
            Text("/").font(.system(.body, design: .monospaced).bold())
        }
        .disabled(commandContext == nil)
        .help("Agent commands for the focused terminal")
        .accessibilityLabel("Agent Commands")
        .accessibilityIdentifier("terminal-agent-command-control")
        .popover(item: $commandPanel) { captured in
            MacAgentCommandPanel(
                commands: captured.command?.commands ?? [],
                targetLabel: captured.label,
                unavailableReason: commandContext?.unavailableReason,
                send: { command in
                    guard let token = captured.token,
                          let request = AgentCommandRequest(command, in: captured.command),
                          request.isValid(in: commandContext)
                    else { return false }
                    return router.send(command.keys, to: token)
                }
            )
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
            commandPanel = nil
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
private struct MacAgentCommandPanel: View {
    let commands: [AgentQuickCommand]
    let targetLabel: String
    let unavailableReason: String?
    let send: @MainActor (AgentQuickCommand) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var hasSubmitted = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Commands").font(.headline)
            Text(targetLabel).font(.caption).foregroundStyle(.secondary)
            if let reason = unavailableReason ?? error {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 105))], spacing: 8) {
                ForEach(commands) { command in
                    Button {
                        guard !hasSubmitted else { return }
                        if send(command) {
                            hasSubmitted = true
                            dismiss()
                        } else {
                            error = "The terminal changed. Reopen the panel to send."
                        }
                    } label: {
                        Text(command.text).monospaced().frame(maxWidth: .infinity, minHeight: 26)
                    }
                    .buttonStyle(.bordered)
                    .disabled(unavailableReason != nil || hasSubmitted)
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

@MainActor
private struct MacQuickPhrasePanel: View {
    let store: QuickPhraseStore
    let targetLabel: String
    let unavailableReason: String?
    let send: @MainActor (QuickPhrase) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var isAdding = false
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
                    isAdding = true
                    isEditorFocused = true
                } label: {
                    Label("Add Phrase", symbol: .plus)
                }
                .disabled(store.loadError != nil)
            }
            Text(targetLabel).font(.caption).foregroundStyle(.secondary)
            if let reason = store.loadError ?? error ?? unavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if isAdding {
                TextField("Single-line phrase", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($isEditorFocused)
                    .onSubmit(savePhrase)
                    .accessibilityIdentifier("quick-phrase-editor")
                HStack {
                    Button("Cancel") {
                        isAdding = false
                        draft = ""
                        error = nil
                    }
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
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func savePhrase() {
        do {
            try store.add(draft)
            draft = ""
            isAdding = false
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func submit(_ phrase: QuickPhrase) {
        guard !hasSubmitted, !isAdding, unavailableReason == nil else { return }
        if send(phrase) {
            hasSubmitted = true
            dismiss()
        } else {
            error = "The terminal changed. Reopen the panel to send."
        }
    }
}
