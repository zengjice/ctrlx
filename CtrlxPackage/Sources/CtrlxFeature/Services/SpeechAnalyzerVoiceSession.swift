#if os(iOS)
    import AVFoundation
    import Foundation
    import Speech

    @available(iOS 26.0, *)
    @MainActor
    final class SpeechAnalyzerVoiceSession {
        typealias UpdateHandler = @MainActor @Sendable (String) -> Void

        private let audioEngine = AVAudioEngine()
        private let contextualTerms: [String]
        private let diagnosticID = UUID().uuidString

        private var analyzer: SpeechAnalyzer?
        private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
        private var resultTask: Task<Void, Never>?
        private var resultError: Error?
        private var transcriptState = VoiceInputTranscriptState()
        private var stableTranscriptState = VoiceInputStableTranscriptState()
        private var isFinishing = false
        private var hasAudioTap = false
        private var ownsAudioSession = false
        private var audioRecorder: VoiceAudioRecorder?

        init(contextualTerms: [String]) {
            self.contextualTerms = contextualTerms
        }

        func start(onUpdate: @escaping UpdateHandler) async throws {
            let transcriber = try await ModernSpeechTranscriber.preferred(for: preferredLocale)
            try Task.checkCancellation()
            let modules = [transcriber.module]
            VoiceInputDiagnostics.recognizer(
                transcriber.diagnosticName,
                stage: "live",
                locale: transcriber.selectedLocale,
                id: diagnosticID
            )

            if let installationRequest = try await AssetInventory.assetInstallationRequest(
                supporting: modules
            ) {
                try Task.checkCancellation()
                try await installationRequest.downloadAndInstall()
            }
            try Task.checkCancellation()

            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: modules
            ) else {
                throw SpeechAnalyzerVoiceSessionError.compatibleAudioFormatUnavailable
            }

            try Task.checkCancellation()
            let options = SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: .lingering
            )
            let analyzer = SpeechAnalyzer(modules: modules, options: options)
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualTerms
            try await analyzer.setContext(context)
            try Task.checkCancellation()
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            try Task.checkCancellation()

            let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
            self.analyzer = analyzer
            self.inputContinuation = inputContinuation
            resultTask = makeResultTask(for: transcriber, onUpdate: onUpdate)

            do {
                try await analyzer.start(inputSequence: inputSequence)
                try Task.checkCancellation()
                try startAudioInput(
                    analyzerFormat: analyzerFormat,
                    inputContinuation: inputContinuation
                )
            } catch {
                await cancel()
                throw error
            }
        }

        func finish() async throws -> VoiceRecognitionResult {
            isFinishing = true
            stopAudioInput()
            let recordingURL = audioRecorder?.finish()
            inputContinuation?.finish()
            inputContinuation = nil

            do {
                if let analyzer {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                }
                if let resultTask {
                    await resultTask.value
                }

                let liveText = transcriptState.text
                let liveResultError = resultError
                analyzer = nil
                resultTask = nil
                resultError = nil

                var recognitionResult = VoiceRecognitionResult(
                    primaryTranscript: "",
                    liveTranscript: liveText,
                    diagnosticID: diagnosticID
                )
                var accurateResultError: Error?
                if let recordingURL {
                    do {
                        recognitionResult = try await transcribeRecordedAudio(
                            at: recordingURL,
                            liveTranscript: liveText
                        )
                    } catch {
                        accurateResultError = error
                        VoiceInputDiagnostics.recognitionFallback(error: error, id: diagnosticID)
                    }
                }

                if recognitionResult.bestAvailableTranscript.isEmpty,
                   let resultError = accurateResultError ?? liveResultError
                {
                    throw resultError
                }

                VoiceInputDiagnostics.recognitionResult(recognitionResult)
                cleanup()
                return recognitionResult
            } catch {
                await cancel()
                throw error
            }
        }

        func cancel() async {
            stopAudioInput()
            inputContinuation?.finish()
            inputContinuation = nil
            await analyzer?.cancelAndFinishNow()
            resultTask?.cancel()
            cleanup()
        }

        private var preferredLocale: Locale {
            let identifier = Locale.preferredLanguages.first ?? Locale.current.identifier
            return Locale(identifier: identifier)
        }

        private func makeResultTask(
            for transcriber: ModernSpeechTranscriber,
            onUpdate: @escaping UpdateHandler
        ) -> Task<Void, Never> {
            switch transcriber {
            case let .speech(transcriber):
                Task { @MainActor [weak self] in
                    do {
                        for try await result in transcriber.results {
                            self?.receive(
                                text: String(result.text.characters),
                                isFinal: result.isFinal,
                                onUpdate: onUpdate
                            )
                        }
                    } catch is CancellationError {
                    } catch {
                        self?.resultError = error
                    }
                }

            case let .dictation(transcriber):
                Task { @MainActor [weak self] in
                    do {
                        for try await result in transcriber.results {
                            self?.receive(
                                text: String(result.text.characters),
                                isFinal: result.isFinal,
                                onUpdate: onUpdate
                            )
                        }
                    } catch is CancellationError {
                    } catch {
                        self?.resultError = error
                    }
                }
            }
        }

        private func receive(
            text: String,
            isFinal: Bool,
            onUpdate: UpdateHandler
        ) {
            let candidate = transcriptState.receive(text, isFinal: isFinal)
            guard !isFinishing else { return }
            onUpdate(stableTranscriptState.receive(candidate))
        }

        private func startAudioInput(
            analyzerFormat: AVAudioFormat,
            inputContinuation: AsyncStream<AnalyzerInput>.Continuation
        ) throws {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .spokenAudio, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            ownsAudioSession = true

            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw SpeechAnalyzerVoiceSessionError.microphoneUnavailable
            }
            guard let converter = AnalyzerAudioBufferConverter(
                inputFormat: inputFormat,
                outputFormat: analyzerFormat
            ) else {
                throw SpeechAnalyzerVoiceSessionError.audioConverterUnavailable
            }
            let audioRecorder = try VoiceAudioRecorder(format: inputFormat)
            self.audioRecorder = audioRecorder

            inputNode.installTap(
                onBus: 0,
                bufferSize: 1_024,
                format: inputFormat
            ) { @Sendable buffer, _ in
                audioRecorder.append(buffer)
                guard let convertedBuffer = converter.convert(buffer) else { return }
                inputContinuation.yield(AnalyzerInput(buffer: convertedBuffer))
            }
            hasAudioTap = true

            audioEngine.prepare()
            try audioEngine.start()
        }

        private func stopAudioInput() {
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            if hasAudioTap {
                audioEngine.inputNode.removeTap(onBus: 0)
                hasAudioTap = false
            }
            // A cancelled preparation can finish after a new recording starts.
            // Only deactivate audio if this session actually activated it.
            if ownsAudioSession {
                ownsAudioSession = false
                try? AVAudioSession.sharedInstance().setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
            }
        }

        private func transcribeRecordedAudio(
            at url: URL,
            liveTranscript: String
        ) async throws -> VoiceRecognitionResult {
            let transcriber = try await ModernSpeechTranscriber.accurate(for: preferredLocale)
            let modules = [transcriber.module]
            VoiceInputDiagnostics.recognizer(
                transcriber.diagnosticName,
                stage: "final",
                locale: transcriber.selectedLocale,
                id: diagnosticID
            )

            if let installationRequest = try await AssetInventory.assetInstallationRequest(
                supporting: modules
            ) {
                try await installationRequest.downloadAndInstall()
            }

            let options = SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: .lingering
            )
            let analyzer = SpeechAnalyzer(modules: modules, options: options)
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualTerms
            try await analyzer.setContext(context)

            let audioFile = try AVAudioFile(forReading: url)
            let resultTask = Task {
                try await transcriber.collectedResult(
                    liveTranscript: liveTranscript,
                    diagnosticID: diagnosticID
                )
            }

            do {
                if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                return try await resultTask.value
            } catch {
                resultTask.cancel()
                await analyzer.cancelAndFinishNow()
                _ = try? await resultTask.value
                throw error
            }
        }

        private func cleanup() {
            audioRecorder?.discard()
            audioRecorder = nil
            analyzer = nil
            resultTask = nil
            resultError = nil
            transcriptState.reset()
            stableTranscriptState.reset()
            isFinishing = false
        }
    }

    @available(iOS 26.0, *)
    private extension ModernSpeechTranscriber {
        static func preferred(for locale: Locale) async throws -> Self {
            let speechLocale: Locale?
            if SpeechTranscriber.isAvailable {
                speechLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            } else {
                speechLocale = nil
            }
            let dictationLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale)

            if let speechLocale {
                return .speech(
                    SpeechTranscriber(
                        locale: speechLocale,
                        preset: .progressiveTranscription
                    )
                )
            }

            if let dictationLocale {
                return .dictation(
                    DictationTranscriber(
                        locale: dictationLocale,
                        preset: .progressiveLongDictation
                    )
                )
            }

            throw SpeechAnalyzerVoiceSessionError.unsupportedLanguage
        }

        static func accurate(for locale: Locale) async throws -> Self {
            if SpeechTranscriber.isAvailable,
               let speechLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            {
                return .speech(
                    SpeechTranscriber(
                        locale: speechLocale,
                        preset: .transcriptionWithAlternatives
                    )
                )
            }

            if let dictationLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
                var preset = DictationTranscriber.Preset.longDictation
                preset.reportingOptions.insert(.alternativeTranscriptions)
                return .dictation(
                    DictationTranscriber(
                        locale: dictationLocale,
                        preset: preset
                    )
                )
            }

            throw SpeechAnalyzerVoiceSessionError.unsupportedLanguage
        }

        func collectedResult(
            liveTranscript: String,
            diagnosticID: String
        ) async throws -> VoiceRecognitionResult {
            var accumulator = VoiceRecognitionCandidateAccumulator()

            switch self {
            case let .speech(transcriber):
                for try await result in transcriber.results {
                    accumulator.append(
                        primary: String(result.text.characters),
                        alternatives: result.alternatives.map { String($0.characters) }
                    )
                }
            case let .dictation(transcriber):
                for try await result in transcriber.results {
                    accumulator.append(
                        primary: String(result.text.characters),
                        alternatives: result.alternatives.map { String($0.characters) }
                    )
                }
            }

            return accumulator.makeResult(
                liveTranscript: liveTranscript,
                diagnosticID: diagnosticID
            )
        }
    }

    @available(iOS 26.0, *)
    private enum ModernSpeechTranscriber {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var module: any SpeechModule {
            switch self {
            case let .speech(transcriber):
                transcriber
            case let .dictation(transcriber):
                transcriber
            }
        }

        var diagnosticName: String {
            switch self {
            case .speech:
                "SpeechTranscriber"
            case .dictation:
                "DictationTranscriber"
            }
        }

        var selectedLocale: Locale {
            switch self {
            case let .speech(transcriber):
                transcriber.selectedLocales.first ?? .current
            case let .dictation(transcriber):
                transcriber.selectedLocales.first ?? .current
            }
        }
    }

    @available(iOS 26.0, *)
    private final class AnalyzerAudioBufferConverter: @unchecked Sendable {
        private let inputFormat: AVAudioFormat
        private let outputFormat: AVAudioFormat
        private let converter: AVAudioConverter?
        private let lock = NSLock()

        init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
            self.inputFormat = inputFormat
            self.outputFormat = outputFormat

            if inputFormat == outputFormat {
                converter = nil
            } else {
                guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                    return nil
                }
                self.converter = converter
            }
        }

        func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            lock.withLock {
                guard let converter else { return buffer }

                let sampleRateRatio = outputFormat.sampleRate / inputFormat.sampleRate
                let frameCapacity = AVAudioFrameCount(
                    ceil(Double(buffer.frameLength) * sampleRateRatio) + 1
                )
                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: frameCapacity
                ) else { return nil }

                var conversionError: NSError?
                var suppliedInput = false
                let status = converter.convert(
                    to: outputBuffer,
                    error: &conversionError
                ) { _, inputStatus in
                    guard !suppliedInput else {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    suppliedInput = true
                    inputStatus.pointee = .haveData
                    return buffer
                }

                guard
                    conversionError == nil,
                    status != .error,
                    outputBuffer.frameLength > 0
                else { return nil }

                return outputBuffer
            }
        }
    }

    @available(iOS 26.0, *)
    private final class VoiceAudioRecorder: @unchecked Sendable {
        private let url: URL
        private let lock = NSLock()
        private var audioFile: AVAudioFile?
        private var hasFailed = false

        init(format: AVAudioFormat) throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ctrlx-voice-\(UUID().uuidString).caf")
            audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.withLock {
                guard let audioFile, !hasFailed else { return }
                do {
                    try audioFile.write(from: buffer)
                } catch {
                    hasFailed = true
                    self.audioFile = nil
                }
            }
        }

        func finish() -> URL? {
            lock.withLock {
                audioFile = nil
                return hasFailed ? nil : url
            }
        }

        func discard() {
            let url = lock.withLock {
                audioFile = nil
                return self.url
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    @available(iOS 26.0, *)
    private enum SpeechAnalyzerVoiceSessionError: LocalizedError {
        case audioConverterUnavailable
        case compatibleAudioFormatUnavailable
        case microphoneUnavailable
        case unsupportedLanguage

        var errorDescription: String? {
            switch self {
            case .audioConverterUnavailable:
                "Unable to convert microphone audio for speech recognition."
            case .compatibleAudioFormatUnavailable:
                "No compatible speech recognition audio format is available."
            case .microphoneUnavailable:
                "The microphone is unavailable."
            case .unsupportedLanguage:
                "Speech recognition does not support the current language."
            }
        }
    }
#endif
