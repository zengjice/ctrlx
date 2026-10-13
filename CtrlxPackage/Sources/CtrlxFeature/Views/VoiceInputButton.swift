import CtrlxCommon
import SwiftUI

extension View {
    @ViewBuilder
    func voiceInputAccessory(text: Binding<String>, isDisabled: Bool) -> some View {
        #if os(iOS)
            padding(.trailing, 36)
                .overlay(alignment: .bottomTrailing) {
                    VoiceInputButton(text: text, isDisabled: isDisabled)
                }
        #else
            self
        #endif
    }
}

#if os(iOS)
    import CtrlxNetworking

    typealias TerminalVoiceInputContextProvider = @MainActor () -> String?

    private struct TerminalInputControlStyle: ViewModifier {
        let isActive: Bool

        func body(content: Content) -> some View {
            content
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? Color.red : Color.primary)
                .padding(.horizontal, 10)
                .frame(minHeight: TerminalInputControlMetrics.buttonHeight)
                .background(
                    Capsule()
                        .fill(isActive ? Color.red.opacity(0.12) : Color.secondary.opacity(0.1))
                )
                .overlay {
                    Capsule()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                }
        }
    }

    extension View {
        func terminalInputControlStyle(isActive: Bool = false) -> some View {
            modifier(TerminalInputControlStyle(isActive: isActive))
        }
    }

    struct VoiceInputButton: View {
        @Environment(IOSSettings.self) private var settings
        @Environment(\.scenePhase) private var scenePhase

        @Binding var text: String
        let isDisabled: Bool
        var showsLabel = false
        var usesControlStyle = false
        var onInputStart: (() -> Void)?
        var contextProvider: TerminalVoiceInputContextProvider = { nil }

        @State private var controller = VoiceInputController()
        @State private var baseText = ""

        var body: some View {
            Button(action: toggleRecording) {
                if usesControlStyle, !showsLabel {
                    buttonContent
                        .terminalInputControlStyle(isActive: controller.isRecording)
                        .contentShape(Capsule())
                } else {
                    buttonContent.contentShape(.rect)
                }
            }
            .buttonStyle(.plain)
            .disabled(isDisabled || controller.phase.tapAction == .none)
            .opacity(isDisabled ? 0.4 : 1)
            .accessibilityLabel("Voice Input")
            .accessibilityValue(controller.phase.accessibilityValue)
            .accessibilityHint(controller.phase.accessibilityHint)
            .accessibilityIdentifier("terminal-voice-input-control")
            .sensoryFeedback(.impact(weight: .light), trigger: controller.isRecording)
            .onChange(of: controller.transcript, updateText)
            .onChange(of: isDisabled) {
                if isDisabled {
                    controller.cancel()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase != .active { controller.cancel() }
            }
            .onDisappear(perform: controller.cancel)
            .alert("Voice Input Unavailable", isPresented: isShowingError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(controller.errorMessage ?? "Please try again.")
            }
        }

        @ViewBuilder private var buttonContent: some View {
            if controller.phase == .requestingPermission || controller.phase == .finalizing {
                if showsLabel {
                    labeledContent {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 30, height: 30)
                }
            } else {
                if showsLabel {
                    labeledContent {
                        (controller.isRecording ? Symbols.micFill : Symbols.mic).image
                    }
                } else if usesControlStyle {
                    // The shared row style owns the font, foreground and background.
                    // Standalone accessory styling must not dim an enabled row button.
                    (controller.isRecording ? Symbols.micFill : Symbols.mic).image
                        .frame(width: 30, height: 30)
                        .scaleEffect(controller.isRecording ? 1.08 : 1)
                        .animation(.easeInOut(duration: 0.15), value: controller.isRecording)
                } else {
                    (controller.isRecording ? Symbols.micFill : Symbols.mic).image
                        .font(.body)
                        .foregroundStyle(controller.isRecording ? .red : .secondary)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(controller.isRecording ? Color.red.opacity(0.12) : Color.clear)
                        )
                        .scaleEffect(controller.isRecording ? 1.08 : 1)
                        .animation(.easeInOut(duration: 0.15), value: controller.isRecording)
                }
            }
        }

        private func labeledContent<Icon: View>(@ViewBuilder icon: () -> Icon) -> some View {
            HStack(spacing: 5) {
                icon()
                Text(controller.isRecording ? "Stop" : "Voice")
            }
            .terminalInputControlStyle(isActive: controller.isRecording)
            .scaleEffect(controller.isRecording ? 1.04 : 1)
            .animation(.easeInOut(duration: 0.15), value: controller.isRecording)
        }

        private func toggleRecording() {
            guard !isDisabled, controller.phase.tapAction != .none else { return }
            let isStarting = controller.phase.tapAction == .start
            if isStarting { prepareInput() }
            controller.toggleRecording(
                context: isStarting ? contextProvider() : nil,
                correctionSelection: isStarting ? settings.voiceCorrection.selection : nil
            )
        }

        private var isShowingError: Binding<Bool> {
            Binding(
                get: { controller.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        controller.errorMessage = nil
                    }
                }
            )
        }

        private func prepareInput() {
            onInputStart?()
            baseText = text
        }

        private func updateText() {
            let updatedText = VoiceInputTextComposer.appending(controller.transcript, to: baseText)
            if text != updatedText {
                text = updatedText
            }
        }
    }

    /// Dictation is an end-of-document correction stream, independent of the
    /// native keyboard's caret-aware shadow editor.
    struct TerminalVoiceInputButton: View {
        let isDisabled: Bool
        var showsLabel = false
        var usesControlStyle = false
        var contextProvider: TerminalVoiceInputContextProvider = { nil }
        let sendKeys: ([TmuxKey]) -> Void

        @State private var transcript = ""
        @State private var synchronizer = TerminalInputDocumentSynchronizer()

        var body: some View {
            VoiceInputButton(
                text: $transcript,
                isDisabled: isDisabled,
                showsLabel: showsLabel,
                usesControlStyle: usesControlStyle,
                onInputStart: beginInput,
                contextProvider: contextProvider
            )
            .onChange(of: transcript, synchronizeInput)
        }

        private func beginInput() {
            synchronizer.reset()
            transcript = ""
        }

        private func synchronizeInput() {
            let delta = synchronizer.advance(to: transcript)
            var keys = Array(repeating: TmuxKey.backspace, count: delta.deletionCount)
            if !delta.insertion.isEmpty {
                keys.append(.text(delta.insertion))
            }
            if !keys.isEmpty {
                sendKeys(keys)
            }
        }
    }
#endif
