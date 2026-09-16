#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    @MainActor
    struct TerminalQuickPhraseButton: View {
        let store: QuickPhraseStore
        let context: TerminalPhraseContext
        let sendPhrase: @MainActor (TerminalPhraseRequest) -> Bool
        /// Suspend the terminal's native input while the phrase editor owns focus.
        @Binding var isPresented: Bool
        @State private var presentedContext: TerminalPhraseContext?

        var body: some View {
            Button(action: showPanel) {
                Symbols.textBubbleFill.image
                    .frame(minWidth: 16)
                    .terminalInputControlStyle()
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quick Phrases")
            .accessibilityIdentifier("terminal-quick-phrase-control")
            .sheet(item: $presentedContext, onDismiss: { isPresented = false }) { capturedContext in
                TerminalQuickPhrasePanel(
                    store: store,
                    capturedContext: capturedContext,
                    currentContext: context,
                    sendPhrase: sendPhrase
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .onChange(of: context) { _, current in
                if let presentedContext, !presentedContext.hasSameInput(as: current) {
                    self.presentedContext = nil
                }
            }
            .onDisappear { isPresented = false }
        }

        private func showPanel() {
            isPresented = true
            presentedContext = context
        }
    }

    @MainActor
    private struct TerminalQuickPhrasePanel: View {
        let store: QuickPhraseStore
        let capturedContext: TerminalPhraseContext
        let currentContext: TerminalPhraseContext
        let sendPhrase: @MainActor (TerminalPhraseRequest) -> Bool

        @Environment(\.dismiss) private var dismiss
        @ScaledMetric(relativeTo: .subheadline) private var minimumButtonWidth: CGFloat = 112
        @State private var showsAddPhrase = false
        @State private var hasSubmitted = false
        @State private var errorMessage: String?

        private var unavailableReason: String? {
            guard capturedContext.hasSameInput(as: currentContext) else {
                return "The pane or input changed. Reopen the phrase panel."
            }
            return currentContext.unavailableReason
        }

        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let message = store.loadError ?? unavailableReason {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if store.phrases.isEmpty {
                            ContentUnavailableView(
                                "No Quick Phrases",
                                symbol: .textBubbleFill,
                                description: "Add phrases to reuse in any terminal window."
                            )
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumButtonWidth), spacing: 8)], spacing: 8) {
                            ForEach(store.phrases) { phrase in
                                Button { send(phrase) } label: {
                                    Text(phrase.text)
                                        .font(.subheadline.weight(.medium))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, minHeight: 36)
                                }
                                .disabled(hasSubmitted || unavailableReason != nil)
                                .accessibilityIdentifier("terminal-quick-phrase-\(phrase.id)")
                                .contextMenu {
                                    Button(role: .destructive) {
                                        remove(phrase)
                                    } label: {
                                        Label("Delete", symbol: .trash)
                                    }
                                }
                            }
                            Button { showsAddPhrase = true } label: {
                                Label("Add Phrase", symbol: .plus)
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .disabled(store.loadError != nil)
                            .accessibilityIdentifier("terminal-quick-phrase-add")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: 12))
                        .tint(.primary)
                        Text("Tap a phrase to send it and Return. Existing terminal input is kept. Long-press to delete.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let errorMessage {
                            Text(errorMessage).font(.footnote).foregroundStyle(.red)
                        }
                    }
                    .padding(16)
                }
                .navigationTitle("Quick Phrases")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: {
                            Label("Close", symbol: .xmark).labelStyle(.iconOnly)
                        }
                    }
                }
                .navigationDestination(isPresented: $showsAddPhrase) {
                    QuickPhraseEditor(store: store)
                }
            }
        }

        private func send(_ phrase: QuickPhrase) {
            guard !hasSubmitted, unavailableReason == nil else { return }
            let request = TerminalPhraseRequest(phrase: phrase, context: currentContext)
            guard sendPhrase(request) else {
                errorMessage = "Phrase not sent. The pane, input, or connection changed."
                return
            }
            hasSubmitted = true
            dismiss()
        }

        private func remove(_ phrase: QuickPhrase) {
            do { try store.remove(phrase.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    @MainActor
    private struct QuickPhraseEditor: View {
        let store: QuickPhraseStore
        @Environment(\.dismiss) private var dismiss
        @State private var text = ""
        @State private var errorMessage: String?
        @FocusState private var isFocused: Bool

        var body: some View {
            Form {
                Section {
                    TextField("Phrase", text: $text)
                        .focused($isFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("terminal-quick-phrase-text")
                } footer: {
                    Text("Saved on this iPhone for all windows. Use a single line; saving does not send it.")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Add Phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("terminal-quick-phrase-save")
                }
            }
            .task { isFocused = true }
        }

        private func save() {
            do {
                try store.add(text)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
#endif
