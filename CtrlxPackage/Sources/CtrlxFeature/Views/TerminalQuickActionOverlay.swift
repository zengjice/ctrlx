#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    /// Lives above the terminal content, outside its sizing and responder paths.
    /// Unlike a sheet, opening this does not transform the presenting page or
    /// remove the native keyboard/accessory from the active terminal.
    @MainActor
    struct TerminalQuickActionOverlay: ViewModifier {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Binding var presentation: TerminalQuickActionPresentation
        let store: QuickPhraseStore
        let phraseContext: TerminalPhraseContext
        let sendPhrase: @MainActor (TerminalPhraseRequest) -> Bool
        var commandContext: AgentCommandContext? = nil
        var sendCommand: @MainActor (AgentCommandRequest) -> Bool = { _ in false }

        func body(content: Content) -> some View {
            content
                .overlay {
                    // Measure only the overlay's available viewport. It must
                    // never contribute height to the terminal or safe-area bar.
                    GeometryReader { geometry in
                        ZStack(alignment: .bottom) {
                            if let panel = presentation.panel {
                                Button(action: close) {
                                    Color.black.opacity(0.08)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Close Quick Actions")
                                .accessibilityIdentifier("terminal-quick-action-backdrop")
                                .transition(.opacity)

                                panelContent(panel)
                                    .frame(
                                        width: max(0, min(560, geometry.size.width - 24)),
                                        height: max(0, min(420, geometry.size.height - 24))
                                    )
                                    .modifier(TerminalQuickActionPanelSurface())
                                    .padding(12)
                                    .accessibilityAddTraits(.isModal)
                                    .accessibilityIdentifier("terminal-quick-action-panel")
                                    // Avoid sweeping a full-height live glass
                                    // surface over the continuously updating terminal.
                                    .transition(reduceMotion ? .opacity : .offset(y: 24).combined(with: .opacity))
                                    .zIndex(1)
                            }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
                        // Keep animation transactions inside the overlay. The
                        // terminal, safe-area bar and responder must not animate.
                        .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.2),
                                   value: presentation.isPresented)
                        .allowsHitTesting(presentation.isPresented)
                    }
                    // Sliding out must not cover the fixed keyboard rows.
                    .clipped()
                }
                .onChange(of: phraseContext) { validate() }
                .onChange(of: commandContext) { validate() }
                .onDisappear(perform: close)
        }

        @ViewBuilder
        private func panelContent(_ panel: TerminalQuickActionPresentation.Panel) -> some View {
            switch panel {
            case let .commands(captured):
                TerminalAgentCommandPanel(
                    capturedContext: captured,
                    currentContext: commandContext,
                    sendCommand: sendCommand,
                    close: close
                )
            case let .phrases(captured):
                TerminalQuickPhrasePanel(
                    store: store,
                    capturedContext: captured,
                    currentContext: phraseContext,
                    sendPhrase: sendPhrase,
                    close: close,
                    showsAddPhrase: $presentation.isEditingPhrase
                )
            }
        }

        private func close() { presentation.dismiss() }

        private func validate() {
            presentation.validate(phraseContext: phraseContext, commandContext: commandContext)
        }
    }

    /// One glass surface for the whole panel. Buttons retain their existing
    /// styling; stacking glass layers makes text-heavy terminal content noisy.
    @MainActor
    private struct TerminalQuickActionPanelSurface: ViewModifier {
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        private let shape = RoundedRectangle(cornerRadius: 28)

        func body(content: Content) -> some View {
            if reduceTransparency {
                content.background(Color(uiColor: .secondarySystemBackground), in: shape)
                    .clipShape(shape)
            } else if #available(iOS 26, *) {
                content.clipShape(shape)
                    .glassEffect(.regular, in: shape)
            } else {
                content.background(.ultraThinMaterial, in: shape)
                    .clipShape(shape)
            }
        }
    }

    /// A panel-local header, not a navigation bar. Overlays inherit the session's
    /// navigation environment, so they must not introduce another NavigationStack
    /// or use the environment dismiss action to implement panel-local navigation.
    @MainActor
    struct TerminalQuickActionPanelHeader: View {
        let title: LocalizedStringKey
        let close: () -> Void

        var body: some View {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(action: close) {
                    Label("Close", symbol: .xmark).labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("terminal-quick-action-close")
            }
            .padding(16)
        }
    }
#endif
