import CtrlxCommon
import SwiftUI

extension View {
    @ViewBuilder
    func voiceInputAccessory(text: Binding<String>, isDisabled: Bool) -> some View {
        #if os(iOS)
            modifier(VoiceInputAccessory(text: text, isDisabled: isDisabled))
        #else
            self
        #endif
    }
}

#if os(iOS)
    import CtrlxNetworking

    typealias TerminalVoiceInputContextProvider = @MainActor () -> VoiceInputContextSnapshot?

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

    private struct VoiceInputControl: View {
        let controller: VoiceInputController
        let isDisabled: Bool
        var showsLabel = false
        var usesControlStyle = false
        let toggleRecording: () -> Void

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
    }

    /// Native reply editors own their full draft; unlike terminals, they can
    /// provide it as explicit context and append only after finalization.
    private struct VoiceInputAccessory: ViewModifier {
        @Environment(IOSSettings.self) private var settings
        @Environment(\.scenePhase) private var scenePhase
        @Binding var text: String
        let isDisabled: Bool
        @State private var controller = VoiceInputController()
        @State private var baseText = ""

        func body(content: Content) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                content.padding(.trailing, 36)
                    .overlay(alignment: .bottomTrailing) {
                        VoiceInputControl(controller: controller, isDisabled: isDisabled, toggleRecording: toggle)
                    }
                if controller.phase != .idle {
                    VoiceInputPreview(voice: controller, cancel: cancel)
                }
            }
            .onChange(of: controller.completedTranscript) {
                guard let transcript = controller.takeCompletedTranscript() else { return }
                let valid = !isDisabled && text == baseText && scenePhase == .active
                if valid {
                    text = VoiceInputTextComposer.appending(transcript, to: baseText)
                }
                controller.recordDelivery(enqueued: valid)
            }
            .onChange(of: text) {
                if controller.phase != .idle && text != baseText {
                    cancel()
                }
            }
            .onChange(of: isDisabled) {
                if isDisabled {
                    cancel()
                }
            }
            .onChange(of: scenePhase) {
                if scenePhase != .active {
                    cancel()
                }
            }
            .onDisappear(perform: cancel)
            .modifier(VoiceInputErrorAlert(voice: controller))
        }

        private func toggle() {
            guard !isDisabled else { return }
            let starting = controller.phase == .idle
            if starting {
                baseText = text
            }
            controller.toggleRecording(
                context: starting ? .init(inputDraft: baseText) : nil,
                correctionSelection: starting ? settings.voiceCorrection.selection : nil
            )
        }

        private func cancel() {
            controller.cancel()
        }
    }

    struct TerminalVoiceInputButton: View {
        @Environment(IOSSettings.self) private var settings
        let session: TerminalVoiceInputSession
        let context: TerminalPhraseContext
        let isDisabled: Bool
        var showsLabel = false
        var usesControlStyle = false
        var contextProvider: TerminalVoiceInputContextProvider = { nil }
        var body: some View {
            VoiceInputControl(
                controller: session.voice,
                isDisabled: isDisabled || !context.canSend,
                showsLabel: showsLabel,
                usesControlStyle: usesControlStyle,
                toggleRecording: toggle
            )
            .onChange(of: isDisabled) {
                if isDisabled {
                    session.cancel()
                }
            }
        }

        private func toggle() {
            guard !isDisabled else { return }
            let starting = session.voice.phase == .idle
            session.toggle(
                in: context, snapshot: starting ? contextProvider() : nil,
                selection: starting ? settings.voiceCorrection.selection : nil
            )
        }
    }
#endif
