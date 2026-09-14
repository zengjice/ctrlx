#if os(iOS)
    import CtrlxNetworking
    import SwiftUI

    /// Shared by the SwiftUI input controls and the native shortcut accessory.
    enum TerminalInputControlMetrics {
        static let buttonHeight: CGFloat = 32
    }

    /// A dedicated terminal-input control that stays outside terminal content.
    struct TerminalKeyboardBar: View {
        let keyboardRequested: Bool
        let isEnabled: Bool
        let action: () -> Void
        var contextProvider: TerminalVoiceInputContextProvider = { nil }
        let sendKeys: ([TmuxKey]) -> Void
        var agentCommandContext: AgentCommandContext? = nil
        var sendAgentCommand: @MainActor (AgentCommandRequest) -> Bool = { _ in false }

        var body: some View {
            HStack(spacing: 6) {
                Button(action: action) {
                    Label(
                        "Keyboard",
                        symbol: keyboardRequested ? .keyboardChevronCompactDown : .keyboard
                    )
                    .frame(maxWidth: .infinity)
                    .terminalInputControlStyle()
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.4)
                .accessibilityLabel(keyboardRequested ? "Hide Keyboard" : "Show Keyboard")
                .accessibilityIdentifier("terminal-keyboard-control")

                TerminalVoiceInputButton(
                    isDisabled: !isEnabled,
                    showsLabel: true,
                    contextProvider: contextProvider,
                    sendKeys: sendKeys
                )

                TerminalAgentCommandButton(
                    context: agentCommandContext,
                    sendCommand: sendAgentCommand
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

                Button(action: sendReturn) {
                    HStack(spacing: 4) {
                        Text("↵")
                        Text("Send")
                    }
                    .terminalInputControlStyle()
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.4)
                .accessibilityLabel("Send Return")
                .accessibilityIdentifier("terminal-return-control")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.bar)
            .overlay(alignment: .top) {
                Divider()
            }
        }

        private func sendReturn() {
            sendKeys([.enter])
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
