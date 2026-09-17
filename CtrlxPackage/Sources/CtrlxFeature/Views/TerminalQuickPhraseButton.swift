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
        @Binding var showsAddPhrase: Bool

        @ScaledMetric(relativeTo: .subheadline) private var minimumButtonWidth: CGFloat = 112
        @State private var hasSubmitted = false
        @State private var errorMessage: String?

        private var unavailableReason: String? {
            guard capturedContext.hasSameInput(as: currentContext) else {
                return "The pane or input changed. Reopen the phrase panel."
            }
            return currentContext.unavailableReason
        }

        var body: some View {
            if showsAddPhrase {
                QuickPhraseEditor(store: store, finish: { showsAddPhrase = false })
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
            close()
        }

        private func remove(_ phrase: QuickPhrase) {
            do { try store.remove(phrase.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    @MainActor
    private struct QuickPhraseEditor: View {
        let store: QuickPhraseStore
        /// Returns to the phrase list; never dismisses the surrounding session.
        let finish: () -> Void
        @State private var text = ""
        @State private var errorMessage: String?
        @FocusState private var isFocused: Bool

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Button("Cancel", action: finish)
                        .accessibilityIdentifier("terminal-quick-phrase-cancel")
                    Spacer()
                    Text("Add Phrase").font(.headline)
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
                try store.add(text)
                finish()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
#endif
