#if os(iOS) || os(macOS)
    import SwiftUI

    /// Passive preview only. The microphone remains the start/stop control;
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
                    Text(voice.stage.label)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("voice-preview-stage")
                    Text(voice.transcript.isEmpty ? "Say something…" : voice.transcript)
                        .font(.callout).foregroundStyle(.primary)
                        .lineLimit(2, reservesSpace: true)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("voice-preview-transcript")
                }
                .allowsHitTesting(false)
                Button(action: cancel) {
                    Label("Cancel Voice Input", symbol: .xmark)
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
                    .keyboardShortcut(.cancelAction)
                #endif
                    .help("Cancel Voice Input (Esc)")
                    .accessibilityIdentifier("voice-preview-cancel")
            }
            .padding(.vertical, 8)
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
            .accessibilityIdentifier("voice-input-preview")
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
