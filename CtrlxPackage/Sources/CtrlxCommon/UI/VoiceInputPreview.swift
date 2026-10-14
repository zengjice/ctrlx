#if os(iOS) || os(macOS)
    import SwiftUI

    /// Shared presentation only: the owning input surface decides whether the
    /// captured target is still valid and handles the one-shot insertion.
    @MainActor
    package struct VoiceInputPreview: View {
        package let voice: VoiceInputController
        package var targetLabel: String?
        package let cancel: () -> Void
        package let stop: () -> Void

        package init(
            voice: VoiceInputController,
            targetLabel: String? = nil,
            cancel: @escaping () -> Void,
            stop: @escaping () -> Void
        ) {
            self.voice = voice
            self.targetLabel = targetLabel
            self.cancel = cancel
            self.stop = stop
        }

        package var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Voice Input").font(.headline)
                    Spacer()
                    Button("Cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("voice-preview-cancel")
                }
                if let targetLabel {
                    Text(targetLabel).font(.caption).foregroundStyle(.secondary)
                }
                Text(voice.stage.label)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("voice-preview-stage")
                ScrollView {
                    Text(voice.transcript.isEmpty ? "Your words will appear here." : voice.transcript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("voice-preview-transcript")
                }
                .frame(minHeight: 44, maxHeight: 140)
                HStack {
                    Text("Preview only. Stopping inserts text without sending.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop and Insert", action: stop)
                        .keyboardShortcut("m", modifiers: [.command, .shift])
                        .disabled(!voice.isRecording)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("voice-preview-stop")
                }
            }
            .padding(16)
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
