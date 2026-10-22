#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftUI

    /// Shared by the SwiftUI input controls and the native shortcut accessory.
    enum TerminalInputControlMetrics {
        static let buttonHeight: CGFloat = 32
        static let buttonWidth: CGFloat = 44
    }

    /// A dedicated terminal-input control that stays outside terminal content.
    struct TerminalKeyboardBar: View {
        let voiceSession: TerminalVoiceInputSession
        let relayClient: ViewerRelayClient
        @Binding var clipboardPaste: TerminalImagePasteRequest?
        let isEnabled: Bool
        var contextProvider: TerminalVoiceInputContextProvider = { nil }
        let sendKeys: ([TmuxKey]) -> Void
        let phraseContext: TerminalPhraseContext
        @Binding var quickActionPresentation: TerminalQuickActionPresentation
        let customButtonStore: TerminalCustomButtonStore
        let sendCustomButton: (TerminalCustomButtonRequest) -> Bool
        var agentCommandContext: AgentCommandContext? = nil
        var showsTerminalControls = true

        /// Editing disables terminal keystrokes, not the panel toggles.
        private var terminalInputEnabled: Bool {
            isEnabled && !quickActionPresentation.suspendsTerminalInput
        }

        var body: some View {
            HStack(spacing: 4) {
                // Keep Send visible even on narrow screens or large text sizes.
                ScrollView(.horizontal) {
                    inputControls
                }
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: false, vertical: true)

                if showsTerminalControls {
                    Button(action: sendReturn) {
                        Text("Send")
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .terminalInputControlStyle()
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!terminalInputEnabled)
                    .opacity(terminalInputEnabled ? 1 : 0.4)
                    .accessibilityLabel("Send Return")
                    .accessibilityIdentifier("terminal-return-control")
                }
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
                ImageUploadToolbarButton(
                    paneId: terminalInputEnabled && !quickActionPresentation.isPresented ? phraseContext.target.paneID : nil,
                    relayClient: relayClient,
                    clipboardPaste: $clipboardPaste
                )

                if showsTerminalControls {
                    TerminalVoiceInputButton(
                        session: voiceSession, context: phraseContext,
                        isDisabled: !terminalInputEnabled || quickActionPresentation.isPresented,
                        showsLabel: false,
                        usesControlStyle: true,
                        contextProvider: contextProvider
                    )
                    .id(phraseContext.target)

                    TerminalQuickPhraseButton(
                        context: phraseContext,
                        presentation: $quickActionPresentation
                    )

                    TerminalAgentCommandButton(
                        context: agentCommandContext,
                        terminalContext: phraseContext,
                        presentation: $quickActionPresentation
                    )

                    RepeatingTerminalKeyButton(
                        title: "←",
                        key: .left,
                        accessibilityLabel: "Move Left",
                        accessibilityIdentifier: "terminal-left-control",
                        isEnabled: terminalInputEnabled,
                        sendKeys: sendKeys
                    )

                    RepeatingTerminalKeyButton(
                        title: "→",
                        key: .right,
                        accessibilityLabel: "Move Right",
                        accessibilityIdentifier: "terminal-right-control",
                        isEnabled: terminalInputEnabled,
                        sendKeys: sendKeys
                    )

                    RepeatingTerminalKeyButton(
                        title: "⌫",
                        key: .backspace,
                        accessibilityLabel: "Delete",
                        accessibilityIdentifier: "terminal-delete-control",
                        isEnabled: terminalInputEnabled,
                        sendKeys: sendKeys
                    )

                    Button(action: sendEscape) {
                        Text("esc")
                            .terminalInputControlStyle()
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!terminalInputEnabled)
                    .opacity(terminalInputEnabled ? 1 : 0.4)
                    .accessibilityLabel("Escape")
                    .accessibilityIdentifier("terminal-escape-control")

                    Button(action: sendDollar) {
                        Text("$")
                            .terminalInputControlStyle()
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!terminalInputEnabled)
                    .opacity(terminalInputEnabled ? 1 : 0.4)
                    .accessibilityLabel("Dollar Sign")
                    .accessibilityIdentifier("terminal-dollar-control")

                    ForEach(customButtonStore.buttons) { button in
                        TerminalCustomButtonControl(
                            button: button, store: customButtonStore,
                            context: phraseContext, isInputEnabled: terminalInputEnabled,
                            send: sendCustomButton
                        )
                    }
                    .id(phraseContext.target)

                    Button {
                        quickActionPresentation.toggle(.addCustomButton(phraseContext))
                    } label: {
                        Label("Add Button", symbol: .plus)
                            .labelStyle(.iconOnly)
                            .terminalInputControlStyle()
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("terminal-add-custom-button")
                }
            }
        }

        private func sendReturn() {
            sendKeys([.enter])
        }

        private func sendEscape() {
            sendKeys([.escape])
        }

        private func sendDollar() {
            sendKeys([.text("$")])
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
