import CtrlxNetworking
import Dependencies
import os
import SwiftUI

@MainActor
struct AgentWorkflowMediaImportView: View {
    let endpoint: AgentWorkflowEndpoint
    let hostID: UUID
    let url: URL
    let mediaType: String
    let availableAttachments: Int
    let imported: (AgentWorkflowImportedMedia) -> Void
    @Environment(\.dismiss) private var dismiss
    @Dependency(AgentWorkflowMediaClient.self) private var media
    @State private var source: AgentWorkflowMediaSource?
    @State private var frames: [AgentWorkflowMediaFrame] = []
    @State private var frameCount = 8
    @State private var includeAudio = true
    @State private var language = VoiceInputLanguage.system
    @State private var transcript = ""
    @State private var error: String?
    @State private var operation: Operation?
    @State private var status = "Preparing media…"
    @State private var progress = 0.0
    @State private var preparing = true
    @State private var working = false
    @State private var closing = false

    private enum Operation: Equatable { case frames, transcribe, upload }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(url.lastPathComponent).font(.headline)
                    if let source {
                        Text("Duration: \(source.duration, specifier: "%.1f") seconds")
                            .foregroundStyle(.secondary)
                        Text("The original is retained. Agents receive only the samples and transcript you confirm here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let source {
                    if source.hasVideo {
                        Section("Video samples") {
                            Stepper("Frames: \(frameCount)", value: $frameCount, in: 1...max(1, min(16, availableAttachments - 1)))
                            Button(frames.isEmpty ? "Sample video" : "Resample video") { operation = .frames }
                            Text("Uniformly spaced samples may miss events between frames. Increase the count if needed. One additional attachment contains the sampling notes.")
                                .font(.caption).foregroundStyle(.secondary)
                            if frames.count != frameCount, !frames.isEmpty {
                                Text("Resample to apply the new frame count.").foregroundStyle(.orange)
                            }
                            ScrollView(.horizontal) {
                                HStack(alignment: .top) {
                                    ForEach(frames) { frame in
                                        VStack {
                                            thumbnail(frame.thumbnail)
                                                .frame(width: 160, height: 110)
                                                .accessibilityLabel("Video sample at \(frame.seconds, specifier: "%.3f") seconds")
                                            Text("\(frame.seconds, specifier: "%.3f") s").font(.caption).monospacedDigit()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if source.hasAudio {
                        Section("Audio transcript") {
                            if source.hasVideo {
                                Toggle("Include audio transcript", isOn: $includeAudio)
                            }
                            if includeAudio || !source.hasVideo {
                                Picker("Language", selection: $language) {
                                    ForEach(VoiceInputLanguage.allCases) { Text($0.label).tag($0) }
                                }
                                Button("Transcribe audio") { operation = .transcribe }
                                TextEditor(text: $transcript).frame(minHeight: 150)
                                    .accessibilityLabel("Reviewed transcript")
                                Text("Review and correct the transcript before importing. You can also enter it manually. System speech recognition may download a language model or use Apple's service.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Audio will be explicitly marked as excluded in the notes.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if preparing || working || operation != nil {
                    Section {
                        Text(working && operation == nil ? "Stopping…" : status)
                        if operation == .upload {
                            ProgressView(value: progress)
                        } else {
                            ProgressView()
                        }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
            .disabled(preparing || working || operation != nil || closing)
            .navigationTitle("Review media")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(working || operation != nil ? "Stop" : "Cancel") {
                        if operation != nil {
                            operation = nil
                        } else {
                            closing = true
                            dismiss()
                        }
                    }.disabled(closing || (working && operation == nil))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { operation = .upload }
                        .accessibilityLabel("Import reviewed media")
                        .disabled(!canImport || preparing || working || operation != nil || closing)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 500, idealHeight: 700)
        #endif
        .interactiveDismissDisabled()
        .task {
            defer { preparing = false }
            do {
                let value = try await media.prepare(url, mediaType)
                if Task.isCancelled {
                    await remove(value.id)
                    return
                }
                source = value
                frameCount = max(1, min(8, availableAttachments - 1))
                if value.hasVideo, availableAttachments < 2 {
                    error = "Video needs space for at least one frame and its notes. Remove other attachments first."
                }
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
        .task(id: operation) {
            guard let action = operation, let source else { return }
            working = true
            error = nil
            defer {
                working = false
                if operation == action {
                    operation = nil
                }
            }
            do {
                switch action {
                case .frames:
                    status = "Sampling video…"
                    frames = []
                    let values = try await media.frames(source.id, frameCount)
                    try Task.checkCancellation()
                    frames = values
                case .transcribe:
                    status = "Transcribing audio…"
                    let value = try await media.transcribe(source.id, language.localeIdentifier)
                    try Task.checkCancellation()
                    transcript = value
                case .upload:
                    let text = source.hasAudio && (includeAudio || !source.hasVideo) ? transcript : nil
                    let outputs = try await media.outputs(source.id, text)
                    guard outputs.count <= availableAttachments else { throw AgentWorkflowError("The converted media exceeds the workflow's attachment limit.") }
                    let result = try await endpoint.importMedia(source: source, outputs: outputs, hostID: hostID) { name, value in
                        status = "Importing \(name)…"
                        progress = value
                    }
                    // No await between taking ownership of imports and closing.
                    imported(result)
                    closing = true
                    dismiss()
                }
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
        .onDisappear {
            if let source {
                Task { await remove(source.id) }
            }
        }
        .accessibilityIdentifier("workflow-media-review")
    }

    private var canImport: Bool {
        guard let source else { return false }
        if source.hasVideo, frames.isEmpty || frames.count != frameCount || frames.count + 1 > availableAttachments {
            return false
        }
        if source.hasAudio, includeAudio || !source.hasVideo {
            return !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return availableAttachments > 0
    }

    @ViewBuilder
    private func thumbnail(_ data: Data) -> some View {
        #if os(macOS)
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            }
        #else
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            }
        #endif
    }

    private func remove(_ id: UUID) async {
        do { try await media.remove(id) }
        catch { Logger(subsystem: "com.jicezeng.ctrlx", category: "WorkflowMedia").error("Could not remove temporary media: \(error.localizedDescription)") }
    }
}
