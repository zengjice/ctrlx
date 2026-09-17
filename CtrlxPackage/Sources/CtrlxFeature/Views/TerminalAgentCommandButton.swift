#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    @MainActor
    struct TerminalAgentCommandButton: View {
        let context: AgentCommandContext?
        @Binding var presentation: TerminalQuickActionPresentation

        var body: some View {
            Button(action: togglePanel) {
                Text("/")
                    .frame(minWidth: 16)
                    .terminalInputControlStyle()
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(context == nil)
            .opacity(context == nil ? 0.4 : 1)
            .accessibilityLabel("Agent Commands")
            .accessibilityHint(context == nil
                ? "No supported agent in this pane."
                : "Choose a command for the current agent")
            .accessibilityIdentifier("terminal-agent-command-control")
        }

        private func togglePanel() {
            guard let context else { return }
            presentation.toggle(.commands(context))
        }
    }

    @MainActor
    struct TerminalAgentCommandPanel: View {
        let capturedContext: AgentCommandContext
        let currentContext: AgentCommandContext?
        let sendCommand: @MainActor (AgentCommandRequest) -> Bool
        let close: () -> Void

        @ScaledMetric(relativeTo: .subheadline) private var minimumButtonWidth: CGFloat = 112
        @State private var hasSubmitted = false
        @State private var showsUnavailableAlert = false

        private var liveContext: AgentCommandContext? {
            capturedContext.hasSameInput(as: currentContext) ? currentContext : nil
        }

        private var unavailableReason: String? {
            guard let liveContext else {
                return "The pane, agent, or input changed. Reopen the command panel."
            }
            return liveContext.unavailableReason
        }

        var body: some View {
            VStack(spacing: 0) {
                TerminalQuickActionPanelHeader(title: "Commands", close: close)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let unavailableReason {
                            Text(unavailableReason)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("terminal-agent-command-unavailable")
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumButtonWidth), spacing: 8)], spacing: 8) {
                            ForEach(capturedContext.commands) { command in
                                Button {
                                    send(command)
                                } label: {
                                    Text(command.text)
                                        .font(.subheadline.monospaced().weight(.medium))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                        .frame(maxWidth: .infinity, minHeight: 36)
                                }
                                .accessibilityIdentifier("terminal-agent-command-\(command.id)")
                            }
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: 12))
                        .tint(.primary)
                        .disabled(hasSubmitted || liveContext?.canSend != true)
                    }
                    .padding(16)
                }
            }
            .alert("Command Not Sent", isPresented: $showsUnavailableAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("The pane, agent, input, or connection changed. Check the terminal and choose the command again.")
            }
        }

        private func send(_ command: AgentQuickCommand) {
            guard !hasSubmitted else { return }
            guard let request = AgentCommandRequest(command, in: liveContext), sendCommand(request) else {
                showsUnavailableAlert = true
                return
            }
            hasSubmitted = true
            close()
        }
    }
#endif
