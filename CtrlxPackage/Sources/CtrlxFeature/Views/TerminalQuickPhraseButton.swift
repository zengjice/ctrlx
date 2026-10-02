#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    @MainActor
    struct TerminalQuickPhraseButton: View {
        let context: TerminalPhraseContext
        @Binding var presentation: TerminalQuickActionPresentation

        var body: some View {
            Button(action: togglePanel) {
                Symbols.textBubbleFill.image
                    .frame(minWidth: 16)
                    .terminalInputControlStyle()
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quick Phrases")
            .accessibilityIdentifier("terminal-quick-phrase-control")
        }

        private func togglePanel() {
            presentation.toggle(.phrases(context))
        }
    }

    @MainActor
    struct TerminalQuickPhrasePanel: View {
        let store: QuickPhraseStore
        let capturedContext: TerminalPhraseContext
        let currentContext: TerminalPhraseContext
        let sendPhrase: @MainActor (TerminalPhraseRequest) -> Bool
        let close: () -> Void
        @Binding var isEditingPhrase: Bool

        @ScaledMetric(relativeTo: .subheadline) private var minimumButtonWidth: CGFloat = 112
        @State private var hasSubmitted = false
        @State private var errorMessage: String?
        @State private var editingPhrase: QuickPhrase?

        private var unavailableReason: String? {
            guard capturedContext.hasSameInput(as: currentContext) else {
                return "The pane or input changed. Reopen the phrase panel."
            }
            return currentContext.unavailableReason
        }

        var body: some View {
            if isEditingPhrase {
                QuickPhraseEditor(store: store, phrase: editingPhrase) {
                    isEditingPhrase = false
                    editingPhrase = nil
                }
            } else {
                phraseList
            }
        }

        private var phraseList: some View {
            VStack(spacing: 0) {
                TerminalQuickActionPanelHeader(title: "Quick Phrases", close: close)
                Divider()
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
                                // Offline phrases remain manageable; send() checks availability.
                                .disabled(hasSubmitted || store.loadError != nil)
                                .foregroundStyle(unavailableReason == nil ? Color.primary : .secondary)
                                .accessibilityIdentifier("terminal-quick-phrase-\(phrase.id)")
                                .contextMenu {
                                    Button {
                                        beginEditing(phrase)
                                    } label: {
                                        Label("Edit", symbol: .pencil)
                                    }
                                    Button(role: .destructive) {
                                        remove(phrase)
                                    } label: {
                                        Label("Delete", symbol: .trash)
                                    }
                                }
                                .quickPhraseReordering(phrase, store: store) { errorMessage = $0 }
                            }
                            Button { beginEditing(nil) } label: {
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
                        Text("Tap to send and Return. Drag onto a highlighted tile to reorder; its number shows the new position. Long-press to Edit or Delete. Existing terminal input is kept.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let errorMessage {
                            Text(errorMessage).font(.footnote).foregroundStyle(.red)
                        }
                    }
                    .padding(16)
                }
            }
        }

        private func send(_ phrase: QuickPhrase) {
            guard !hasSubmitted, !isEditingPhrase, unavailableReason == nil else { return }
            let request = TerminalPhraseRequest(phrase: phrase, context: currentContext)
            guard sendPhrase(request) else {
                errorMessage = "Phrase not sent. The pane, input, or connection changed."
                return
            }
            hasSubmitted = true
            close()
        }

        private func remove(_ phrase: QuickPhrase) {
            do { try store.remove(phrase.id) }
            catch { errorMessage = error.localizedDescription }
        }

        private func beginEditing(_ phrase: QuickPhrase?) {
            editingPhrase = phrase
            errorMessage = nil
            isEditingPhrase = true
        }
    }

    @MainActor
    private struct QuickPhraseEditor: View {
        let store: QuickPhraseStore
        let phrase: QuickPhrase?
        /// Returns to the phrase list; never dismisses the surrounding session.
        let finish: () -> Void
        @State private var text: String
        @State private var errorMessage: String?
        @FocusState private var isFocused: Bool

        init(store: QuickPhraseStore, phrase: QuickPhrase?, finish: @escaping () -> Void) {
            self.store = store
            self.phrase = phrase
            self.finish = finish
            _text = State(initialValue: phrase?.text ?? "")
        }

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Button("Cancel", action: finish)
                        .accessibilityIdentifier("terminal-quick-phrase-cancel")
                    Spacer()
                    Text(phrase == nil ? "Add Phrase" : "Edit Phrase").font(.headline)
                    Spacer()
                    Button("Save", action: save)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("terminal-quick-phrase-save")
                }
                .padding(16)
                Divider()
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
                .scrollContentBackground(.hidden)
            }
            .task { isFocused = true }
        }

        private func save() {
            do {
                if let phrase {
                    try store.update(phrase, text: text)
                } else {
                    try store.add(text)
                }
                finish()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
#endif
