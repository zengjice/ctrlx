#if os(iOS) || os(macOS)
    import AVFoundation
    import Dependencies
    import Foundation
    import Observation
    import Speech

    @Observable
    @MainActor
    final public class VoiceInputController {
        public private(set) var phase: VoiceInputPhase = .idle
        public private(set) var transcript = ""
        /// Only successful finalization publishes a result for one-shot input surfaces.
        public private(set) var completedTranscript: String?
        public var errorMessage: String?

        @ObservationIgnored private var audioEngine: AVAudioEngine?
        @ObservationIgnored @Dependency(VoiceInputAuthorization.self) private var authorization
        @ObservationIgnored private let ownership: VoiceInputRecordingOwnership
        @ObservationIgnored private var recordingLease: UUID?
        @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
        @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
        @ObservationIgnored private var permissionTask: Task<Void, Never>?
        @ObservationIgnored private var finalizationTask: Task<Void, Never>?
        @ObservationIgnored private var hasAudioTap = false
        @ObservationIgnored private var ownsAudioSession = false
        @ObservationIgnored private var activeRecognitionID: UUID?
        @ObservationIgnored private var modernSession: AnyObject?
        @ObservationIgnored private var recognitionContext: String?
        @ObservationIgnored private var contextualTerms = VoiceInputVocabulary.terms
        @ObservationIgnored private var correctionSelection: VoiceCorrectionSelection?

        public init() {
            self.ownership = .shared
        }

        init(ownership: VoiceInputRecordingOwnership) {
            self.ownership = ownership
        }

        public var isRecording: Bool {
            phase == .recording
        }

        private func beginRecording(
            context: String?,
            correctionSelection: VoiceCorrectionSelection?
        ) {
            guard phase == .idle else { return }
            errorMessage = nil
            guard let lease = ownership.acquire() else {
                errorMessage = "Voice input is already active in another window, or is still stopping."
                return
            }
            recordingLease = lease
            completedTranscript = nil
            recognitionContext = context
            contextualTerms = VoiceInputVocabulary.terms(for: context)
            self.correctionSelection = correctionSelection
            transcript = ""
            phase = .requestingPermission

            permissionTask = Task { [weak self] in
                guard !Task.isCancelled, let self else { return }
                let speechStatus = await authorization.speech()
                guard !Task.isCancelled else { return }
                guard speechStatus == .authorized else {
                    finishPermissionRequest(
                        message: "Allow Speech Recognition in Settings to use voice input."
                    )
                    return
                }

                let microphoneGranted = await authorization.microphone()
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

            if #available(iOS 26.0, macOS 26.0, *), let session = modernSession as? SpeechAnalyzerVoiceSession {
                finishModernRecognition(session)
            } else {
                finishLegacyRecognition()
            }
        }

        public func toggleRecording(
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

        public func cancel() {
            let preparation = permissionTask
            let finalization = finalizationTask
            preparation?.cancel()
            finalization?.cancel()
            permissionTask = nil
            let session = modernSession
            modernSession = nil
            stopAudio(cancelRecognition: true)
            recognitionContext = nil
            correctionSelection = nil
            completedTranscript = nil
            phase = .idle

            guard let lease = recordingLease else { return }
            recordingLease = nil
            if #available(iOS 26.0, macOS 26.0, *), let session = session as? SpeechAnalyzerVoiceSession {
                Task { [ownership] in
                    // Do not race cancel() against start()/finish() on the same analyzer.
                    await preparation?.value
                    await finalization?.value
                    await session.cancel()
                    ownership.release(lease)
                }
            } else {
                ownership.release(lease)
            }
        }

        private func finishPermissionRequest(message: String) {
            cancel()
            errorMessage = message
        }

        private func startRecognition() async throws {
            if #available(iOS 26.0, macOS 26.0, *) {
                try await startModernRecognition()
            } else {
                try startLegacyRecognition()
            }
        }

        @available(iOS 26.0, macOS 26.0, *)
        private func startModernRecognition() async throws {
            let session = SpeechAnalyzerVoiceSession(contextualTerms: contextualTerms)
            modernSession = session

            do {
                try await session.start { [weak self, weak session] updatedTranscript in
                    guard
                        let self, let session, modernSession === session,
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
            request.contextualStrings = contextualTerms
            recognitionRequest = request
            let recognitionID = UUID()
            activeRecognitionID = recognitionID

            #if os(iOS)
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                ownsAudioSession = true
            #endif

            let audioEngine = AVAudioEngine()
            self.audioEngine = audioEngine
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

        @available(iOS 26.0, macOS 26.0, *)
        private func finishModernRecognition(_ session: SpeechAnalyzerVoiceSession) {
            phase = .finalizing
            finalizationTask?.cancel()
            let terminalContext = recognitionContext
            let correctionSelection = correctionSelection
            let contextualTerms = contextualTerms
            finalizationTask = Task { [weak self, session, terminalContext, correctionSelection, contextualTerms] in
                do {
                    let recognition = try await session.finish()
                    guard !Task.isCancelled, let self else { return }
                    modernSession = nil
                    let correctedTranscript = await VoiceTranscriptCorrector.correct(
                        recognition,
                        contextualTerms: contextualTerms,
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
                        finishPermissionRequest(message: error.localizedDescription)
                    } else {
                        let correctedTranscript = await VoiceTranscriptCorrector.correct(
                            fallbackTranscript,
                            contextualTerms: contextualTerms,
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
            transcript = VoiceInputTextComposer.terminalTranscript(completedTranscript)
            self.completedTranscript = transcript
            if let lease = recordingLease {
                recordingLease = nil
                ownership.release(lease)
            }
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
                guard
                    !Task.isCancelled,
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
                finishPermissionRequest(message: errorMessage)
            }
        }

        private func completeRecognition(cancelRecognition: Bool) {
            let completedTranscript = transcript
            let terminalContext = recognitionContext
            let correctionSelection = correctionSelection
            let contextualTerms = contextualTerms
            stopAudio(cancelRecognition: cancelRecognition)
            phase = .finalizing
            finalizationTask = Task {
                [weak self, completedTranscript, terminalContext, correctionSelection, contextualTerms] in
                guard let self else { return }
                let correctedTranscript = await VoiceTranscriptCorrector.correct(
                    completedTranscript,
                    contextualTerms: contextualTerms,
                    terminalContext: terminalContext,
                    providerSelection: correctionSelection
                )
                guard !Task.isCancelled else { return }
                completeModernRecognition(correctedTranscript)
            }
        }

        private func stopAudioInput() {
            guard let audioEngine else { return }
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            if hasAudioTap {
                audioEngine.inputNode.removeTap(onBus: 0)
                hasAudioTap = false
            }
            self.audioEngine = nil
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

            #if os(iOS)
                if ownsAudioSession {
                    ownsAudioSession = false
                    let session = AVAudioSession.sharedInstance()
                    if session.category == .record, session.mode == .measurement {
                        try? session.setActive(false, options: .notifyOthersOnDeactivation)
                    }
                }
            #endif
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

#endif
