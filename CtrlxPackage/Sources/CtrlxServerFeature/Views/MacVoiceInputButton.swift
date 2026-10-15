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
    @State private var heldRequestID: UUID?
    @State private var pointerHoldID: UUID?

    var body: some View {
        let token = router.token
        Button(action: toggleRecording) {
            Group {
                if voice.phase == .requestingPermission || voice.phase == .finalizing {
                    ProgressView().controlSize(.mini)
                } else {
                    Symbols.micFill.image
                        .foregroundStyle(voice.isRecording ? Color.red : Color.primary)
                }
            }
            .frame(minWidth: 16, idealWidth: 32, maxWidth: 32, minHeight: 24)
        }
        .background {
            MacVoiceInputPressTarget(onTap: {
                if router.matches(token) {
                    toggleRecording()
                }
            }, onBegin: {
                guard router.matches(token), context.canSend, !isSuspended, voice.phase == .idle else { return false }
                pointerHoldID = router.beginVoiceInputHold()
                return pointerHoldID != nil
            }, onEnd: { cancelled in
                guard let id = pointerHoldID else { return }
                pointerHoldID = nil
                router.endVoiceInputHold(id, cancelled: cancelled)
            })
            .accessibilityHidden(true)
        }
        .disabled((!context.canSend || isSuspended) && voice.phase == .idle)
        .help("Hold to talk, release to insert. Click or ⌘⌥M to start / stop. Text is not sent automatically.")
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
            if voice.phase == .idle, voice.completedTranscript == nil, voice.correctionNotice == nil {
                cancel()
            }
        }
        .onChange(of: router.token) { cancelIfTargetChanged() }
        .onChange(of: router.voiceInputRequest) {
            if ownsShortcutFocus {
                toggleRecording()
            }
        }
        .onChange(of: router.voiceInputHold) {
            guard ownsShortcutFocus, let hold = router.voiceInputHold else { return }
            switch hold.state {
            case .pressed:
                guard router.matches(hold.token), voice.phase == .idle, context.canSend, !isSuspended else { return }
                heldRequestID = hold.id
                toggleRecording()
            case .released:
                guard heldRequestID == hold.id else { return }
                guard router.matches(hold.token) else { cancel()
                    return
                }
                heldRequestID = nil
                if request != nil, voice.phase == .recording || voice.phase == .requestingPermission {
                    session.toggle(in: context, snapshot: nil, selection: nil)
                }
            case .cancelled:
                if heldRequestID == hold.id {
                    cancel()
                }
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
        if let heldRequestID {
            router.endVoiceInputHold(heldRequestID, cancelled: true)
        }
        heldRequestID = nil
        request = nil
        session.cancel()
    }
}
