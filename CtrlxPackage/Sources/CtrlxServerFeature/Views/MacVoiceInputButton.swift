import CtrlxCommon
import SwiftUI

@MainActor
struct MacVoiceInputButton: View {
    let router: TerminalQuickActionRouter
    var ownsShortcutFocus = true
    let settings: VoiceCorrectionSettings
    let context: TerminalPhraseContext
    let targetLabel: String
    let isSuspended: Bool
    let contextProvider: @MainActor () -> VoiceInputContextSnapshot?
    let willStart: @MainActor () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = TerminalVoiceInputSession()
    private var voice: VoiceInputController {
        session.voice
    }

    @State private var request: TerminalVoiceInputRequest?
    @State private var showsPopover = false

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
        .background {
            MacVoiceInputPopover(isPresented: showsPopover, onCancel: cancel) {
                preview
            }
        }
        .onChange(of: voice.completedTranscript) {
            guard voice.completedTranscript != nil, let captured = request else { return }
            guard !isSuspended else { cancel()
                return
            }
            request = nil
            session.deliver(in: context) { text in
                captured.insert(text, router: router, context: context)
            }
            showsPopover = false
        }
        .onChange(of: voice.phase) {
            if voice.phase == .recording {
                showsPopover = true
            }
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

    private var preview: some View {
        VoiceInputPreview(voice: voice, targetLabel: targetLabel, cancel: cancel, stop: toggleRecording)
            .frame(width: 360)
    }

    private func toggleRecording() {
        if voice.phase == .idle {
            guard !isSuspended else { return }
            guard let captured = TerminalVoiceInputRequest(router: router, context: context) else { return }
            willStart()
            request = captured
            session.toggle(in: context, snapshot: contextProvider(), selection: settings.selection)
            // Keep permission prompts outside the preview; preparation retains
            // the microphone's spinner/cancel action.
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
        showsPopover = false
        session.cancel()
    }
}
