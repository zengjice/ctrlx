import CtrlxCommon
import SwiftUI

@MainActor
struct MacVoiceInputButton: View {
    let router: TerminalQuickActionRouter
    let settings: VoiceCorrectionSettings
    let context: TerminalPhraseContext
    let targetLabel: String
    let isSuspended: Bool
    let contextProvider: @MainActor () -> String?
    let willStart: @MainActor () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var voice = VoiceInputController()
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
        .help("Voice input for the focused terminal; inserts text without sending")
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
            guard let text = voice.completedTranscript, let captured = request else { return }
            guard !isSuspended else { cancel()
                return
            }
            request = nil
            if !text.isEmpty, !captured.insert(text, router: router, context: context) {
                voice.errorMessage = "The terminal changed. Record again in the intended pane."
            }
            showsPopover = false
        }
        .onChange(of: voice.phase) {
            if voice.phase == .recording { showsPopover = true }
            if voice.phase == .idle, voice.completedTranscript == nil { cancel() }
        }
        .onChange(of: router.token) { cancelIfTargetChanged() }
        .onChange(of: context) { cancelIfTargetChanged() }
        .onChange(of: isSuspended) {
            if isSuspended { cancel() }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background { cancel() }
        }
        .onDisappear(perform: cancel)
        .alert("Voice Input", isPresented: Binding(
            get: { voice.errorMessage != nil },
            set: { if !$0 { voice.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { voice.errorMessage = nil }
        } message: {
            Text(voice.errorMessage ?? "")
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice Input").font(.headline)
            Text(targetLabel).font(.caption).foregroundStyle(.secondary)
            Text(statusText).font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                Text(voice.transcript.isEmpty ? "Your words will appear here." : voice.transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 60, maxHeight: 180)
            Text("Stopping inserts the corrected text into this terminal. Press Enter yourself to send.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Stop and Insert", action: toggleRecording)
                    .disabled(!voice.isRecording)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var statusText: String {
        switch voice.phase {
        case .idle: "Ready"
        case .requestingPermission: "Preparing on-device speech recognition…"
        case .recording: "Listening…"
        case .finalizing: "Finishing and correcting…"
        }
    }

    private func toggleRecording() {
        if voice.phase == .idle {
            guard !isSuspended else { return }
            guard let captured = TerminalVoiceInputRequest(router: router, context: context) else { return }
            willStart()
            request = captured
            voice.toggleRecording(context: contextProvider(), correctionSelection: settings.selection)
            // Keep permission prompts outside the preview; preparation retains
            // the microphone's spinner/cancel action.
            if voice.phase == .idle { request = nil }
        } else {
            voice.toggleRecording(context: nil, correctionSelection: nil)
        }
    }

    private func cancelIfTargetChanged() {
        guard let request, !request.isValid(router: router, context: context) else { return }
        cancel()
    }

    private func cancel() {
        request = nil
        showsPopover = false
        voice.cancel()
    }
}
