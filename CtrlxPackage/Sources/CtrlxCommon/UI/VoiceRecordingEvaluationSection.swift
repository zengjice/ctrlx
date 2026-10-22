#if os(iOS) || os(macOS)
    import SwiftUI
    import UniformTypeIdentifiers

    struct VoiceRecordingEvaluationSection: View {
        let settings: VoiceCorrectionSettings
        let isModelTesting: Bool
        @Binding var isEvaluating: Bool
        @Environment(\.scenePhase) private var scenePhase
        @State private var file: URL?
        @State private var reference = ""
        @State private var context = ""
        @State private var includeCorrection = false
        @State private var request: UUID?
        @State private var isImporting = false
        @State private var isExporting = false
        @State private var progress = ""
        @State private var error: String?
        @State private var report: VoiceRecordingEvaluationReport?
        @State private var document: ReportDocument?

        var body: some View {
            Section {
                DisclosureGroup("Evaluate a Recording") {
                    Button(file?.lastPathComponent ?? "Choose Audio File") { isImporting = true }
                        .disabled(isEvaluating)
                    TextField("Reference transcript (what was actually spoken)", text: $reference, axis: .vertical)
                        .lineLimit(3...8)
                        .disabled(isEvaluating)
                    TextField("Optional topic context", text: $context, axis: .vertical)
                        .lineLimit(1...4)
                        .disabled(isEvaluating)
                    Toggle("Include Configured Correction", isOn: $includeCorrection)
                        .disabled(isEvaluating)
                    Text("Replays the same audio through both recognizers. Correction uses the current settings and may use API credits. Audio stays on this device; enabling provider correction sends transcripts and the optional context.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Evaluate Recording") { request = UUID() }
                        .disabled(file == nil || reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isEvaluating || isModelTesting || request != nil)
                    if isEvaluating {
                        ProgressView(progress)
                        Button("Cancel Evaluation", role: .cancel) { request = nil }
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if let report {
                        ForEach(report.stages) { stage in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(stage.name).font(.caption.bold())
                                Text(stage.transcript.isEmpty ? "(Empty)" : stage.transcript).textSelection(.enabled)
                                Text("Unmatched reference characters: \(stage.unmatchedReferenceCharacters); missing terms: \(stage.missingTerms.count)")
                                Text("Intent markers: \(stage.preservesIntentMarkers ? "preserved" : "changed"); literals: \(stage.preservesLiterals ? "preserved" : "changed")")
                                Text("Processing: \(stage.elapsedSeconds, format: .number.precision(.fractionLength(2))) s")
                            }
                            .font(.caption)
                        }
                        Text("Correction: \(report.correctionOutcome). File replay timings do not measure live microphone latency. Unmatched characters can include substitutions; check the transcripts.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Export Evaluation JSON") {
                            do {
                                document = try ReportDocument(data: report.json())
                                isExporting = true
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio]) { result in
                do { file = try result.get() } catch { self.error = error.localizedDescription }
            }
            .fileExporter(isPresented: $isExporting, document: document, contentType: .json, defaultFilename: "voice-recording-evaluation") { result in
                if case let .failure(error) = result {
                    self.error = error.localizedDescription
                }
            }
            .task(id: request) {
                guard let id = request, let file else { return }
                isEvaluating = true
                error = nil
                report = nil
                let scoped = file.startAccessingSecurityScopedResource()
                defer {
                    if scoped {
                        file.stopAccessingSecurityScopedResource()
                    }
                    isEvaluating = false
                    if request == id {
                        request = nil
                    }
                }
                do {
                    let result = try await VoiceRecordingEvaluation.run(
                        file: file,
                        reference: reference,
                        localeIdentifier: settings.language.localeIdentifier,
                        context: context.isEmpty ? nil : context,
                        includeCorrection: includeCorrection,
                        selection: settings.selection,
                        onStage: { progress = $0 }
                    )
                    guard !Task.isCancelled, request == id else { return }
                    report = result
                } catch {
                    if !Task.isCancelled {
                        self.error = error.localizedDescription
                    }
                }
            }
            .onChange(of: scenePhase) {
                if scenePhase == .background {
                    request = nil
                }
            }
            .onDisappear { request = nil }
        }

        private struct ReportDocument: FileDocument {
            static let readableContentTypes: [UTType] = [.json]
            let data: Data
            init(data: Data) {
                self.data = data
            }

            init(configuration: ReadConfiguration) throws {
                self.data = configuration.file.regularFileContents ?? Data()
            }

            func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
                FileWrapper(regularFileWithContents: data)
            }
        }
    }
#endif
