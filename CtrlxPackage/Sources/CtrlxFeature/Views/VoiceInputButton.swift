import SwiftUI

enum VoiceInputTextComposer {
    static func appending(_ transcript: String, to baseText: String) -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return baseText }
        guard !baseText.isEmpty else { return trimmedTranscript }

        let separator = baseText.last?.isWhitespace == true ? "" : " "
        return baseText + separator + trimmedTranscript
    }
}

struct VoiceInputTranscriptState {
    private(set) var finalizedText = ""
    private(set) var volatileText = ""

    var text: String {
        finalizedText + volatileText
    }

    mutating func reset() {
        finalizedText = ""
        volatileText = ""
    }

    @discardableResult
    mutating func receive(_ resultText: String, isFinal: Bool) -> String {
        if isFinal {
            finalizedText += resultText
            volatileText = ""
        } else {
            volatileText = resultText
        }
        return text
    }
}

/// Publishes the first volatile result immediately, then accepts only results
/// that extend the visible prefix. Live text never rewrites itself; the final
/// accurate transcript replaces it after recording ends.
struct VoiceInputStableTranscriptState {
    private(set) var text = ""

    mutating func reset() {
        text = ""
    }

    @discardableResult
    mutating func receive(_ candidate: String) -> String {
        guard !candidate.isEmpty else { return text }
        guard text.isEmpty || candidate.hasPrefix(text) else { return text }
        text = candidate
        return candidate
    }
}

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
    import AVFoundation
    import CtrlxCommon
    import CtrlxNetworking
    import Observation
    import Speech

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

    @Observable
    @MainActor
    private final class VoiceInputController {
        private(set) var phase: VoiceInputPhase = .idle
        private(set) var transcript = ""
        var errorMessage: String?

        @ObservationIgnored private let audioEngine = AVAudioEngine()
        @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
        @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
        @ObservationIgnored private var permissionTask: Task<Void, Never>?
        @ObservationIgnored private var finalizationTask: Task<Void, Never>?
        @ObservationIgnored private var hasAudioTap = false
        @ObservationIgnored private var activeRecognitionID: UUID?
        @ObservationIgnored private var modernSession: AnyObject?
        @ObservationIgnored private var recognitionContext: String?
        @ObservationIgnored private var correctionSelection: VoiceCorrectionSelection?

        var isRecording: Bool {
            phase == .recording
        }

        private func beginRecording(
            context: String?,
            correctionSelection: VoiceCorrectionSelection?
        ) {
            guard phase == .idle else { return }
            errorMessage = nil
            recognitionContext = context
            self.correctionSelection = correctionSelection
            transcript = ""
            phase = .requestingPermission

            permissionTask = Task { [weak self] in
                guard let self else { return }
                let speechStatus = await Self.requestSpeechAuthorization()
                guard !Task.isCancelled else { return }
                guard speechStatus == .authorized else {
                    finishPermissionRequest(
                        message: "Allow Speech Recognition in Settings to use voice input."
                    )
                    return
                }

                let microphoneGranted = await Self.requestMicrophonePermission()
                guard !Task.isCancelled else { return }
                guard microphoneGranted else {
                    finishPermissionRequest(
                        message: "Allow Microphone access in Settings to use voice input."
                    )
                    return
                }

                do {
                    try await startRecognition()
                } catch {
                    guard !Task.isCancelled else { return }
                    finishPermissionRequest(message: error.localizedDescription)
                }
            }
        }

        private func finishRecording() {
            guard phase == .recording else { return }

            if #available(iOS 26.0, *), let session = modernSession as? SpeechAnalyzerVoiceSession {
                finishModernRecognition(session)
            } else {
                finishLegacyRecognition()
            }
        }

        func toggleRecording(
            context: String?,
            correctionSelection: VoiceCorrectionSelection?
        ) {
            switch phase.tapAction {
            case .start:
                beginRecording(
                    context: context,
                    correctionSelection: correctionSelection
                )
            case .cancelPreparation:
                cancel()
            case .finish:
                finishRecording()
            case .none:
                break
            }
        }

        func cancel() {
            permissionTask?.cancel()
            permissionTask = nil
            cancelModernSession()
            stopAudio(cancelRecognition: true)
            recognitionContext = nil
            correctionSelection = nil
            phase = .idle
        }

        private func finishPermissionRequest(message: String) {
            cancelModernSession()
            stopAudio(cancelRecognition: true)
            recognitionContext = nil
            correctionSelection = nil
            phase = .idle
            errorMessage = message
        }

        private func startRecognition() async throws {
            if #available(iOS 26.0, *) {
                try await startModernRecognition()
            } else {
                try startLegacyRecognition()
            }
        }

        @available(iOS 26.0, *)
        private func startModernRecognition() async throws {
            let session = SpeechAnalyzerVoiceSession(contextualTerms: VoiceInputVocabulary.terms)
            modernSession = session

            do {
                try await session.start { [weak self, weak session] updatedTranscript in
                    guard let self, let session, modernSession === session,
                          phase == .requestingPermission || phase == .recording,
                          transcript != updatedTranscript
                    else { return }
                    transcript = updatedTranscript
                }
            } catch {
                if modernSession === session { modernSession = nil }
                await session.cancel()
                throw error
            }

            guard !Task.isCancelled, modernSession === session else {
                await session.cancel()
                return
            }

            phase = .recording
        }

        private func startLegacyRecognition() throws {
            let localeIdentifier = Locale.preferredLanguages.first ?? Locale.current.identifier
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
                throw VoiceInputError.unsupportedLanguage
            }
            guard recognizer.isAvailable else {
                throw VoiceInputError.recognizerUnavailable
            }
            guard recognizer.supportsOnDeviceRecognition else {
                throw VoiceInputError.onDeviceRecognitionUnavailable
            }

            recognitionTask?.cancel()
            recognitionTask = nil

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.addsPunctuation = true
            request.taskHint = .dictation
            request.contextualStrings = VoiceInputVocabulary.terms
            recognitionRequest = request
            let recognitionID = UUID()
            activeRecognitionID = recognitionID

            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                throw VoiceInputError.microphoneUnavailable
            }

            inputNode.installTap(
                onBus: 0,
                bufferSize: 1_024,
                format: recordingFormat
            ) { @Sendable [weak request] buffer, _ in
                request?.append(buffer)
            }
            hasAudioTap = true

            audioEngine.prepare()
            try audioEngine.start()
            phase = .recording

            recognitionTask = recognizer.recognitionTask(with: request) {
                @Sendable [weak self] result, error in
                    let update = result.map { ($0.bestTranscription.formattedString, $0.isFinal) }
                    let errorMessage = error?.localizedDescription

                    Task { @MainActor [weak self, update, errorMessage, recognitionID] in
                        self?.handleRecognitionUpdate(
                            recognitionID: recognitionID,
                            update,
                            errorMessage: errorMessage
                        )
                    }
                }
        }

        @available(iOS 26.0, *)
        private func finishModernRecognition(_ session: SpeechAnalyzerVoiceSession) {
            phase = .finalizing
            finalizationTask?.cancel()
            let terminalContext = recognitionContext
            let correctionSelection = correctionSelection
            finalizationTask = Task { [weak self, session, terminalContext, correctionSelection] in
                do {
                    let recognition = try await session.finish()
                    guard !Task.isCancelled, let self else { return }
                    modernSession = nil
                    let correctedTranscript = await VoiceTranscriptCorrector.correct(
                        recognition,
                        contextualTerms: VoiceInputVocabulary.terms,
                        terminalContext: terminalContext,
                        providerSelection: correctionSelection
                    )
                    guard !Task.isCancelled else { return }
                    completeModernRecognition(correctedTranscript)
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    modernSession = nil
                    let fallbackTranscript = transcript
                    if fallbackTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        recognitionContext = nil
                        phase = .idle
                        errorMessage = error.localizedDescription
                    } else {
                        let correctedTranscript = await VoiceTranscriptCorrector.correct(
                            fallbackTranscript,
                            contextualTerms: VoiceInputVocabulary.terms,
                            terminalContext: terminalContext,
                            providerSelection: correctionSelection
                        )
                        guard !Task.isCancelled else { return }
                        completeModernRecognition(correctedTranscript)
                    }
                }
            }
        }

        private func completeModernRecognition(_ completedTranscript: String) {
            finalizationTask = nil
            recognitionContext = nil
            correctionSelection = nil
            transcript = completedTranscript
            phase = .idle
        }

        private func finishLegacyRecognition() {
            guard phase == .recording else { return }
            phase = .finalizing
            stopAudioInput()
            recognitionRequest?.endAudio()

            let recognitionID = activeRecognitionID
            finalizationTask?.cancel()
            finalizationTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled,
                      let self,
                      phase == .finalizing,
                      activeRecognitionID == recognitionID
                else { return }

                completeRecognition(cancelRecognition: true)
            }
        }

        private func handleRecognitionUpdate(
            recognitionID: UUID,
            _ update: (String, Bool)?,
            errorMessage: String?
        ) {
            guard activeRecognitionID == recognitionID else { return }

            if let update, transcript != update.0 {
                transcript = update.0
            }

            if update?.1 == true {
                completeRecognition(cancelRecognition: false)
                return
            }

            if let errorMessage {
                let wasFinalizing = phase == .finalizing
                if wasFinalizing, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    completeRecognition(cancelRecognition: false)
                    return
                }
                stopAudio(cancelRecognition: false)
                phase = .idle
                if transcript.isEmpty || !wasFinalizing {
                    self.errorMessage = errorMessage
                }
            }
        }

        private func completeRecognition(cancelRecognition: Bool) {
            let completedTranscript = transcript
            let terminalContext = recognitionContext
            let correctionSelection = correctionSelection
            stopAudio(cancelRecognition: cancelRecognition)
            phase = .finalizing
            finalizationTask = Task {
                [weak self, completedTranscript, terminalContext, correctionSelection] in
                guard let self else { return }
                let correctedTranscript = await VoiceTranscriptCorrector.correct(
                    completedTranscript,
                    contextualTerms: VoiceInputVocabulary.terms,
                    terminalContext: terminalContext,
                    providerSelection: correctionSelection
                )
                guard !Task.isCancelled else { return }
                finalizationTask = nil
                recognitionContext = nil
                self.correctionSelection = nil
                transcript = correctedTranscript
                phase = .idle
            }
        }

        private func stopAudioInput() {
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            if hasAudioTap {
                audioEngine.inputNode.removeTap(onBus: 0)
                hasAudioTap = false
            }
        }

        private func stopAudio(cancelRecognition: Bool) {
            stopAudioInput()
            finalizationTask?.cancel()
            finalizationTask = nil

            if cancelRecognition {
                recognitionTask?.cancel()
            }
            recognitionTask = nil
            recognitionRequest = nil
            activeRecognitionID = nil

            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        private func cancelModernSession() {
            guard #available(iOS 26.0, *), let session = modernSession as? SpeechAnalyzerVoiceSession else {
                modernSession = nil
                return
            }
            modernSession = nil
            Task {
                await session.cancel()
            }
        }

        /// TCC invokes authorization completions on an arbitrary dispatch queue.
        /// Keep these bridges outside the controller's MainActor isolation; the
        /// awaiting controller task resumes on MainActor before touching state.
        private nonisolated static func requestSpeechAuthorization() async
            -> SFSpeechRecognizerAuthorizationStatus
        {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }

        private nonisolated static func requestMicrophonePermission() async -> Bool {
            await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

    }

    private enum VoiceInputError: LocalizedError {
        case microphoneUnavailable
        case onDeviceRecognitionUnavailable
        case recognizerUnavailable
        case unsupportedLanguage

        var errorDescription: String? {
            switch self {
            case .microphoneUnavailable:
                "The microphone is unavailable."
            case .onDeviceRecognitionUnavailable:
                "On-device speech recognition is unavailable for the current language."
            case .recognizerUnavailable:
                "Speech recognition is temporarily unavailable."
            case .unsupportedLanguage:
                "Speech recognition does not support the current language."
            }
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
                Button("OK", role: .cancel) {}
            } message: {
                Text(controller.errorMessage ?? "Please try again.")
            }
        }

        @ViewBuilder
        private var buttonContent: some View {
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
                correctionSelection: isStarting ? settings.voiceCorrectionSelection : nil
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
