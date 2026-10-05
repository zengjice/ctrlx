#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    @MainActor
    struct TerminalCustomButtonControl: View {
        let button: TerminalCustomButton
        let store: TerminalCustomButtonStore
        let context: TerminalPhraseContext
        let isInputEnabled: Bool
        let send: (TerminalCustomButtonRequest) -> Bool
        @State private var didLongPress = false
        @State private var errorMessage: String?

        var body: some View {
            Button(action: sendButton) {
                Text(button.name)
                    .lineLimit(1)
                    .frame(minWidth: 20)
                    .terminalInputControlStyle()
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            // Keep management available offline; only the tap action is gated.
            .opacity(isInputEnabled && context.canSend ? 1 : 0.4)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.7, maximumDistance: 10)
                    .onEnded { _ in deleteButton() }
            )
            .accessibilityHint("Tap to execute. Long-press to delete.")
            .accessibilityAction(named: "Delete", deleteButton)
            .accessibilityIdentifier("terminal-custom-button-\(button.id)")
            .alert("Could Not Delete Button", isPresented: Binding(
                get: { errorMessage != nil },
                set: { presented in
                    if !presented {
                        errorMessage = nil
                        didLongPress = false
                    }
                }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
        }

        private func sendButton() {
            guard !didLongPress, isInputEnabled else { return }
            _ = send(TerminalCustomButtonRequest(button: button, context: context))
        }

        private func deleteButton() {
            // Set before removal: releasing a recognized long press must never
            // run the Button's normal tap action, even if saving fails.
            didLongPress = true
            do { try store.remove(button.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    @MainActor
    struct TerminalCustomButtonEditor: View {
        let store: TerminalCustomButtonStore
        let close: () -> Void
        @State private var name = ""
        @State private var text = ""
        @State private var usesKey = false
        @State private var key: TerminalCustomButton.Key = .tab
        @State private var sendReturn = false
        @State private var errorMessage: String?
        @FocusState private var nameFocused: Bool

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Button("Cancel", action: close)
                    Spacer()
                    Text("Add Button").font(.headline)
                    Spacer()
                    Button("Save", action: save)
                        .disabled(store.loadError != nil)
                }
                .padding(16)
                Divider()
                Form {
                    Section {
                        TextField("Button Name", text: $name)
                            .focused($nameFocused)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("terminal-custom-button-name")
                        Picker("Action", selection: $usesKey) {
                            Text("Text").tag(false)
                            Text("Special Key").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if usesKey {
                            Picker("Key", selection: $key) {
                                ForEach(TerminalCustomButton.Key.allCases) { key in
                                    Text(key.title).tag(key)
                                }
                            }
                            .pickerStyle(.menu)
                        } else {
                            TextField("Text to Send", text: $text)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("terminal-custom-button-text")
                            Toggle("Send Return After Text", isOn: $sendReturn)
                        }
                    } footer: {
                        Text("Saved on this device for all windows. Saving does not send input. Long-press a custom button to delete it.")
                    }
                    if let error = store.loadError ?? errorMessage {
                        Section { Text(error).foregroundStyle(.red) }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .task { nameFocused = true }
        }

        private func save() {
            do {
                try store.add(name: name, action: usesKey ? .key(key) : .text(text, sendReturn: sendReturn))
                close()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
#endif
