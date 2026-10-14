import CtrlxCommon
import SwiftUI

@MainActor
struct MacVoiceInputButton: View {
    let router: TerminalQuickActionRouter
    var ownsShortcutFocus = true
    let settings: VoiceCorrectionSettings
    let context: TerminalPhraseContext
    let session: TerminalVoiceInputSession
    let isSuspended: Bool
    let contextProvider: @MainActor () -> VoiceInputContextSnapshot?
    let willStart: @MainActor () -> Void
    @Environment(\.scenePhase) private var scenePhase
    private var voice: VoiceInputController {
        session.voice
    }

    @State private var request: TerminalVoiceInputRequest?

    var body: some View {
        Button(action: toggleRecording) {
            if voice.phase == .requestingPermission || voice.phase == .finalizing {
                ProgressView().controlSize(.mini)
            } else {
                Symbols.micFill.image
                    .foregroundStyle(voice.isRecording ? Color.red : Color.primary)
            }
        }
        .disabled((!context.canSend || isSuspended) && voice.phase == .idle)
        .help("Start / Stop Voice Input (⇧⌘M); inserts text without sending")
        .accessibilityLabel("Voice Input")
        .accessibilityValue(voice.phase.accessibilityValue)
        .accessibilityHint(voice.phase.accessibilityHint)
        .accessibilityIdentifier("terminal-voice-input-control")
        .onChange(of: voice.completedTranscript) {
            guard voice.completedTranscript != nil, let captured = request else { return }
            guard !isSuspended else { cancel()
                return
            }
            request = nil
            session.deliver(in: context) { text in
                captured.insert(text, router: router, context: context)
            }
        }
        .onChange(of: voice.phase) {
            if voice.phase == .idle, voice.completedTranscript == nil {
                cancel()
            }
        }
        .onChange(of: router.token) { cancelIfTargetChanged() }
        .onChange(of: router.voiceInputRequest) {
            if ownsShortcutFocus {
                toggleRecording()
            }
        }
        .onChange(of: context) { cancelIfTargetChanged() }
        .onChange(of: isSuspended) {
            if isSuspended {
                cancel()
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background {
                cancel()
            }
        }
        .onDisappear(perform: cancel)
        .modifier(VoiceInputErrorAlert(voice: voice))
    }

    private func toggleRecording() {
        if voice.phase == .idle {
            guard !isSuspended else { return }
            guard let captured = TerminalVoiceInputRequest(router: router, context: context) else { return }
            willStart()
            request = captured
            session.toggle(in: context, snapshot: contextProvider(), selection: settings.selection)
            if voice.phase == .idle {
                request = nil
            }
        } else {
            session.toggle(in: context, snapshot: nil, selection: nil)
        }
    }

    private func cancelIfTargetChanged() {
        guard let request, !request.isValid(router: router, context: context) else { return }
        cancel()
    }

    private func cancel() {
        request = nil
        session.cancel()
    }
}
