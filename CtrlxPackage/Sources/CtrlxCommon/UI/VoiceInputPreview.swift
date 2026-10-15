#if os(iOS) || os(macOS)
    import SwiftUI

    /// Recording preview and post-insertion notice. The microphone remains the start/stop control;
    /// the owning input surface validates and delivers the finalized text.
    @MainActor
    package struct VoiceInputPreview: View {
        package let voice: VoiceInputController
        package let cancel: () -> Void

        package init(
            voice: VoiceInputController,
            cancel: @escaping () -> Void
        ) {
            self.voice = voice
            self.cancel = cancel
        }

        package var body: some View {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(voice.correctionNotice == nil ? voice.stage.label : "Transcription Only")
                        .font(.caption2)
                        .foregroundStyle(voice.correctionNotice == nil ? Color.secondary : .orange)
                        .lineLimit(1)
                        .accessibilityIdentifier("voice-preview-stage")
                    Text(voice.correctionNotice ?? (voice.transcript.isEmpty ? "Say something…" : voice.transcript))
                        .font(.callout).foregroundStyle(.primary)
                        .lineLimit(voice.correctionNotice == nil ? 2 : 4, reservesSpace: voice.correctionNotice == nil)
                        .truncationMode(voice.correctionNotice == nil ? .head : .tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("voice-preview-transcript")
                }
                .allowsHitTesting(false)
                Button(action: dismiss) {
                    Label(voice.correctionNotice == nil ? "Cancel Voice Input" : "Dismiss Voice Notice", symbol: .xmark)
                        .labelStyle(.iconOnly)
                    #if os(iOS)
                        .frame(width: 44, height: 44)
                    #else
                        .frame(width: 28, height: 28)
                    #endif
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                #if os(iOS)
                    .keyboardShortcut(voice.correctionNotice == nil ? .cancelAction : nil)
                #endif
                    .help(voice.correctionNotice == nil ? "Cancel Voice Input (Esc)" : "Dismiss Voice Notice")
                    .accessibilityIdentifier("voice-preview-cancel")
            }
            .padding(.vertical, 8)
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
            .accessibilityIdentifier("voice-input-preview")
        }

        private func dismiss() {
            if voice.correctionNotice != nil {
                voice.dismissCorrectionNotice()
            } else {
                cancel()
            }
        }
    }

    @MainActor
    package struct VoiceInputErrorAlert: ViewModifier {
        package let voice: VoiceInputController

        package init(voice: VoiceInputController) {
            self.voice = voice
        }

        package func body(content: Content) -> some View {
            content.alert("Voice Input", isPresented: Binding(
                get: { voice.errorMessage != nil },
                set: {
                    if !$0 {
                        voice.errorMessage = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) { voice.errorMessage = nil }
            } message: {
                Text(voice.errorMessage ?? "Please try again.")
            }
        }
    }
#endif
