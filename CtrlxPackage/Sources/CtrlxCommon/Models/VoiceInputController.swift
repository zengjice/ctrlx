#if os(iOS) || os(macOS)
    import AVFoundation
    import Dependencies
    import Foundation
    import Observation
    import Speech

    @Observable
    @MainActor
    final public class VoiceInputController {
        typealias Correct = @MainActor (
            VoiceRecognitionResult, [String], VoiceInputContextSnapshot?, VoiceCorrectionSelection?,
            (VoiceInputStage) -> Void
        ) async -> VoiceCorrectionResult

        public private(set) var phase: VoiceInputPhase = .idle
        public private(set) var isAwaitingAuthorization = false
        public private(set) var stage: VoiceInputStage = .preparing
        public private(set) var transcript = ""
        /// Only successful finalization publishes a result for one-shot input surfaces.
        public private(set) var completedTranscript: String?
        public var errorMessage: String?
        public private(set) var correctionNotice: String?
        private(set) var reviewTranscripts: VoiceRecognitionResult?
        private(set) var debugReport: VoiceInputDebugReport?
        @ObservationIgnored private var pendingCorrectionNotice: String?
        @ObservationIgnored private var pendingDebugReport: VoiceInputDebugReport?

        @ObservationIgnored private var audioEngine: AVAudioEngine?
        @ObservationIgnored @Dependency(VoiceInputAuthorization.self) private var authorization
        @ObservationIgnored @Dependency(PreferencesService.self) private var preferences
        @ObservationIgnored private let audioMonitor = VoiceInputAudioMonitor()
        @ObservationIgnored private var canStartRecording: @MainActor @Sendable () -> Bool = { true }
        @ObservationIgnored private var localeIdentifier = VoiceInputLanguage.system.localeIdentifier
        @ObservationIgnored private let ownership: VoiceInputRecordingOwnership
        @ObservationIgnored private var recordingLease: UUID?
        @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
        @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
        @ObservationIgnored private var permissionTask: Task<Void, Never>?
        @ObservationIgnored private var finalizationTask: Task<Void, Never>?
        @ObservationIgnored private var hasAudioTap = false
        @ObservationIgnored private var ownsAudioSession = false
        @ObservationIgnored private var activeRecognitionID: UUID?
        @ObservationIgnored private var modernSession: (any VoiceInputRecognitionSession)?
        @ObservationIgnored private let makeSession: @MainActor ([String], String) throws -> any VoiceInputRecognitionSession
        @ObservationIgnored private let correct: Correct
        @ObservationIgnored private var recognitionContext: VoiceInputContextSnapshot?
        @ObservationIgnored private var timing: VoiceInputTiming?
        @ObservationIgnored private var diagnosticID = UUID().uuidString
        @ObservationIgnored private var contextualTerms = VoiceInputVocabulary.terms
        @ObservationIgnored private var correctionSelection: VoiceCorrectionSelection?

        public convenience init() {
            self.init(ownership: .shared)
        }

        init(
            ownership: VoiceInputRecordingOwnership,
            makeSession: @escaping @MainActor ([String], String) throws -> any VoiceInputRecognitionSession = { terms, id in
                if #available(iOS 26.0, macOS 26.0, *) {
                    return SpeechAnalyzerVoiceSession(contextualTerms: terms, diagnosticID: id)
                }
                throw VoiceInputError.recognizerUnavailable
            },
            correct: @escaping Correct = { recognition, terms, context, selection, onStage in
                await VoiceTranscriptCorrector.correct(
                    recognition, contextualTerms: terms, terminalContext: context,
                    providerSelection: selection, onStage: onStage
                )
            }
        ) {
            self.ownership = ownership
            self.makeSession = makeSession
            self.correct = correct
        }

        public var isRecording: Bool {
            phase == .recording
        }

        public var isFeedbackVisible: Bool {
            phase != .idle || correctionNotice != nil
        }

        func copyTranscript(_ text: String) {
            @Dependency(ClipboardClient.self) var clipboard
            clipboard.setString(text)
        }

        func copyDebugReport() {
            guard preferences.optionalBool("debugModeEnabled") == true, let debugReport else { return }
            do {
                try copyTranscript(debugReport.json())
            } catch {
                errorMessage = "Could not copy voice input debug details: \(error.localizedDescription)"
            }
        }

        public func dismissCorrectionNotice() {
            correctionNotice = nil
            reviewTranscripts = nil
            debugReport = nil
        }

        private func beginRecording(
            context: VoiceInputContextSnapshot?,
            correctionSelection: VoiceCorrectionSelection?,
            canStart: @escaping @MainActor @Sendable () -> Bool
        ) {
            guard phase == .idle else { return }
            errorMessage = nil
            correctionNotice = nil
            reviewTranscripts = nil
            debugReport = nil
            pendingCorrectionNotice = nil
            pendingDebugReport = nil
            guard let lease = ownership.acquire() else {
                errorMessage = "Voice input is already active in another window, or is still stopping."
                return
            }
            recordingLease = lease
            diagnosticID = lease.uuidString
            stage = .preparing
            timing = VoiceInputTiming(stage: .preparing)
            completedTranscript = nil
            recognitionContext = context
            contextualTerms = VoiceInputVocabulary.terms(for: context)
            self.correctionSelection = correctionSelection
            canStartRecording = canStart
            localeIdentifier = (VoiceInputLanguage(rawValue: preferences.string("voiceInputLanguage") ?? "") ?? .system).localeIdentifier
            transcript = ""
            isAwaitingAuthorization = true
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

                isAwaitingAuthorization = false
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
            updateStage(.finishingRecognition)

            if #available(iOS 26.0, macOS 26.0, *), let session = modernSession {
                finishModernRecognition(session)
            } else {
                finishLegacyRecognition()
            }
        }

        public func toggleRecording(
            context: VoiceInputContextSnapshot?,
            correctionSelection: VoiceCorrectionSelection?,
            canStart: @escaping @MainActor @Sendable () -> Bool = { true }
        ) {
            switch phase.tapAction {
            case .start:
                beginRecording(
                    context: context,
                    correctionSelection: correctionSelection,
                    canStart: canStart
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
            isAwaitingAuthorization = false
            canStartRecording = { true }
            correctionNotice = nil
            reviewTranscripts = nil
            debugReport = nil
            pendingCorrectionNotice = nil
            pendingDebugReport = nil
            finishTiming()
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
            if let session {
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

        /// Consume before enqueueing. Observers can never insert the same result twice.
        public func takeCompletedTranscript() -> String? {
            defer { completedTranscript = nil }
            return completedTranscript
        }

        public func recordDelivery(enqueued: Bool) {
            let showDiagnostics = enqueued && preferences.optionalBool("debugModeEnabled") == true
            correctionNotice = showDiagnostics ? pendingCorrectionNotice : nil
            debugReport = showDiagnostics ? pendingDebugReport : nil
            if !showDiagnostics {
                reviewTranscripts = nil
            }
            if showDiagnostics, correctionNotice == nil, debugReport != nil {
                correctionNotice = "Voice input inserted. Debug details are available to copy."
            }
            pendingCorrectionNotice = nil
            pendingDebugReport = nil
            finishTiming()
            VoiceInputDiagnostics.delivery(enqueued: enqueued, id: diagnosticID)
        }

        private func updateStage(_ next: VoiceInputStage) {
            guard next != stage else { return }
            if var timing {
                let previous = timing.stage
                let elapsed = timing.advance(to: next)
                VoiceInputDiagnostics.stageFinished(previous, elapsed: elapsed, id: diagnosticID)
                self.timing = timing
            }
            stage = next
        }

        private func finishTiming() {
            if var timing {
                let previous = timing.stage
                let elapsed = timing.advance(to: .ready)
                VoiceInputDiagnostics.stageFinished(previous, elapsed: elapsed, id: diagnosticID)
            }
            timing = nil
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
            let session = try makeSession(contextualTerms, diagnosticID)
            modernSession = session

            do {
                try await session.start(
                    localeIdentifier: localeIdentifier,
                    canStart: canStartRecording,
                    onFailure: { [weak self, weak session] message in
                        guard let self, let session, modernSession === session else { return }
                        finishPermissionRequest(message: message)
                    }
                ) { [weak self, weak session] updatedTranscript in
                    guard
                        let self, let session, modernSession === session,
                        phase == .requestingPermission || phase == .recording,
                        transcript != updatedTranscript
                    else { return }
                    transcript = updatedTranscript
                }
            } catch {
                if modernSession === session {
                    modernSession = nil
                }
                await session.cancel()
                throw error
            }

            guard !Task.isCancelled, modernSession === session else {
                await session.cancel()
                return
            }

            phase = .recording
            updateStage(.recording)
        }

        private func startLegacyRecognition() throws {
            guard canStartRecording() else { throw VoiceInputStartError.targetChanged }
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

            audioMonitor.start(engine: audioEngine) { [weak self] message in
                self?.finishPermissionRequest(message: message)
            }
            audioEngine.prepare()
            try audioEngine.start()
            phase = .recording
            updateStage(.recording)

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
        private func finishModernRecognition(_ session: any VoiceInputRecognitionSession) {
            phase = .finalizing
            finalizationTask?.cancel()
            let terminalContext = recognitionContext
            let correctionSelection = correctionSelection
            let contextualTerms = contextualTerms
            finalizationTask = Task { [weak self, session, terminalContext, correctionSelection, contextualTerms] in
                do {
                    let result = try await session.finish { [weak self] stage in
                        guard !Task.isCancelled else { return }
                        self?.updateStage(stage)
                    }
                    guard !Task.isCancelled, let self else { return }
                    let recognition = result.withLocale(localeIdentifier)
                    reviewTranscripts = recognition
                    modernSession = nil
                    let correctedTranscript = await correct(
                        recognition, contextualTerms, terminalContext, correctionSelection,
                        { [weak self] stage in
                            guard !Task.isCancelled else { return }
                            self?.updateStage(stage)
                        }
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
                        reviewTranscripts = VoiceRecognitionResult(primaryTranscript: fallbackTranscript, diagnosticID: diagnosticID, localeIdentifier: localeIdentifier)
                        let correctedTranscript = await correct(
                            VoiceRecognitionResult(primaryTranscript: fallbackTranscript, diagnosticID: diagnosticID, localeIdentifier: localeIdentifier),
                            contextualTerms, terminalContext, correctionSelection,
                            { [weak self] stage in
                                guard !Task.isCancelled else { return }
                                self?.updateStage(stage)
                            }
                        )
                        guard !Task.isCancelled else { return }
                        completeModernRecognition(correctedTranscript)
                    }
                }
            }
        }

        private func completeModernRecognition(_ result: VoiceCorrectionResult) {
            canStartRecording = { true }
            updateStage(.ready)
            finalizationTask = nil
            let insertedText = VoiceInputTextComposer.terminalTranscript(result.text)
            if !insertedText.isEmpty, let recognition = reviewTranscripts {
                pendingDebugReport = VoiceInputDebugReport(
                    recognition: recognition, context: recognitionContext,
                    contextualTerms: contextualTerms, correction: result, insertedText: insertedText
                )
            }
            recognitionContext = nil
            correctionSelection = nil
            transcript = insertedText
            if transcript.isEmpty {
                reviewTranscripts = nil
            } else if
                let reviewTranscripts, result.outcome != .rejected,
                !reviewTranscripts.prefersLiveTranscript,
                reviewTranscripts.bestAvailableTranscript == result.text {
                self.reviewTranscripts = nil
            }
            pendingCorrectionNotice = transcript.isEmpty ? nil : result.notice
            completedTranscript = transcript
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
            updateStage(.finishingRecognition)
            let completedTranscript = transcript
            let terminalContext = recognitionContext
            let correctionSelection = correctionSelection
            let contextualTerms = contextualTerms
            stopAudio(cancelRecognition: cancelRecognition)
            phase = .finalizing
            finalizationTask = Task {
                [weak self, completedTranscript, terminalContext, correctionSelection, contextualTerms] in
                guard let self else { return }
                let recognition = VoiceRecognitionResult(primaryTranscript: completedTranscript, diagnosticID: diagnosticID, localeIdentifier: localeIdentifier)
                reviewTranscripts = recognition
                let correctedTranscript = await correct(
                    recognition,
                    contextualTerms, terminalContext, correctionSelection,
                    { [weak self] stage in
                        guard !Task.isCancelled else { return }
                        self?.updateStage(stage)
                    }
                )
                guard !Task.isCancelled else { return }
                completeModernRecognition(correctedTranscript)
            }
        }

        private func stopAudioInput() {
            audioMonitor.stop()
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
