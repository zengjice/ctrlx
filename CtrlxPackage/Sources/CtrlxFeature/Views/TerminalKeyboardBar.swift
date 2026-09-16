#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftUI

    /// Shared by the SwiftUI input controls and the native shortcut accessory.
    enum TerminalInputControlMetrics {
        static let buttonHeight: CGFloat = 32
        /// With the shared 10-point side insets these produce 64-point controls.
        /// Keyboard no longer expands to consume all spare width; Send keeps its
        /// text instead of collapsing to the roughly 32-point Return icon.
        static let keyboardContentMaxWidth: CGFloat = 44
        static let sendContentWidth: CGFloat = 44
    }

    /// A dedicated terminal-input control that stays outside terminal content.
    struct TerminalKeyboardBar: View {
        let keyboardRequested: Bool
        let isEnabled: Bool
        let action: () -> Void
        var contextProvider: TerminalVoiceInputContextProvider = { nil }
        let sendKeys: ([TmuxKey]) -> Void
        let quickPhrases: QuickPhraseStore
        let phraseContext: TerminalPhraseContext
        let sendPhrase: @MainActor (TerminalPhraseRequest) -> Bool
        @Binding var isPhrasePanelPresented: Bool
        var agentCommandContext: AgentCommandContext? = nil
        var sendAgentCommand: @MainActor (AgentCommandRequest) -> Bool = { _ in false }
        @State private var isAgentCommandPanelPresented = false

        var body: some View {
            HStack(spacing: 4) {
                // Keep Send visible even on narrow screens or large text sizes.
                ScrollView(.horizontal) {
                    inputControls
                }
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: false, vertical: true)

                Button(action: sendReturn) {
                    Text("Send")
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(width: TerminalInputControlMetrics.sendContentWidth)
                        .terminalInputControlStyle()
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.4)
                .accessibilityLabel("Send Return")
                .accessibilityIdentifier("terminal-return-control")
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.bar)
            .overlay(alignment: .top) {
                Divider()
            }
        }

        private var inputControls: some View {
            HStack(spacing: 4) {
                Button(action: action) {
                    ViewThatFits(in: .horizontal) {
                        Label(
                            "Keyboard",
                            symbol: keyboardRequested ? .keyboardChevronCompactDown : .keyboard
                        )
                        .fixedSize()
                        (keyboardRequested ? Symbols.keyboardChevronCompactDown : Symbols.keyboard).image
                    }
                    .frame(maxWidth: TerminalInputControlMetrics.keyboardContentMaxWidth)
                    .terminalInputControlStyle()
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.4)
                .accessibilityLabel(keyboardRequested ? "Hide Keyboard" : "Show Keyboard")
                .accessibilityIdentifier("terminal-keyboard-control")

                TerminalVoiceInputButton(
                    isDisabled: !isEnabled || isPhrasePanelPresented || isAgentCommandPanelPresented,
                    showsLabel: false,
                    usesControlStyle: true,
                    contextProvider: contextProvider,
                    sendKeys: sendKeys
                )
                .id(phraseContext.target)

                TerminalQuickPhraseButton(
                    store: quickPhrases,
                    context: phraseContext,
                    sendPhrase: sendPhrase,
                    isPresented: $isPhrasePanelPresented
                )

                TerminalAgentCommandButton(
                    context: agentCommandContext,
                    sendCommand: sendAgentCommand,
                    isPresented: $isAgentCommandPanelPresented
                )
                // An open panel must not silently switch to another pane/agent.
                .id(agentCommandContext?.target)

                RepeatingTerminalKeyButton(
                    title: "←",
                    key: .left,
                    accessibilityLabel: "Move Left",
                    accessibilityIdentifier: "terminal-left-control",
                    isEnabled: isEnabled,
                    sendKeys: sendKeys
                )

                RepeatingTerminalKeyButton(
                    title: "→",
                    key: .right,
                    accessibilityLabel: "Move Right",
                    accessibilityIdentifier: "terminal-right-control",
                    isEnabled: isEnabled,
                    sendKeys: sendKeys
                )

                RepeatingTerminalKeyButton(
                    title: "⌫",
                    key: .backspace,
                    accessibilityLabel: "Delete",
                    accessibilityIdentifier: "terminal-delete-control",
                    isEnabled: isEnabled,
                    sendKeys: sendKeys
                )

                Button(action: sendEscape) {
                    Text("esc")
                        .frame(minWidth: 20)
                        .terminalInputControlStyle()
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.4)
                .accessibilityLabel("Escape")
                .accessibilityIdentifier("terminal-escape-control")
            }
        }

        private func sendReturn() {
            sendKeys([.enter])
        }

        private func sendEscape() {
            sendKeys([.escape])
        }
    }

    private struct RepeatingTerminalKeyButton: View {
        let title: String
        let key: TmuxKey
        let accessibilityLabel: String
        let accessibilityIdentifier: String
        let isEnabled: Bool
        let sendKeys: ([TmuxKey]) -> Void

        var body: some View {
            Button(action: sendKey) {
                Text(title)
                    .frame(minWidth: 20)
                    .terminalInputControlStyle()
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .buttonRepeatBehavior(.enabled)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.4)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Press and hold to repeat")
            .accessibilityIdentifier(accessibilityIdentifier)
        }

        private func sendKey() {
            sendKeys([key])
        }
    }
#endif
