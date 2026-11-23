#if os(macOS) || os(iOS)
    import CtrlxNetworking
    import Observation
    import SwiftUI

    @MainActor @Observable
    final class FileBrowserMarkdownDraft {
        var text: String
        var saveRequest: UUID?
        private let originalData: Data
        private let byteOrderMark: Data

        init(data: Data) {
            self.originalData = data
            let bom = Data([0xEF, 0xBB, 0xBF])
            self.byteOrderMark = data.starts(with: bom) ? bom : Data()
            self.text = String(decoding: data.dropFirst(byteOrderMark.count), as: UTF8.self)
        }

        var isSaving: Bool {
            saveRequest != nil
        }

        var withinLimit: Bool {
            text.utf8.count + byteOrderMark.count <= FileBrowserLimits.maximumTextBytes
        }

        var hasChanges: Bool {
            !text.utf8.elementsEqual(originalData.dropFirst(byteOrderMark.count))
        }

        var canSave: Bool {
            withinLimit && hasChanges && !isSaving
        }

        var data: Data {
            byteOrderMark + Data(text.utf8)
        }

        func requestSave() {
            if canSave {
                saveRequest = UUID()
            }
        }
    }

    @MainActor
    struct FileBrowserMarkdownEditor: View {
        let file: FileBrowserEntry
        @Bindable private var draft: FileBrowserMarkdownDraft
        let sourceID: String
        let source: () -> FileBrowserSource
        let onSaved: () -> Void
        let onCancel: (() -> Void)?
        let onSavingChanged: ((Bool) -> Void)?
        @Environment(\.dismiss) private var dismiss
        @State private var error: String?

        init(
            file: FileBrowserEntry,
            draft: FileBrowserMarkdownDraft,
            sourceID: String,
            source: @escaping () -> FileBrowserSource,
            onSaved: @escaping () -> Void,
            onCancel: (() -> Void)? = nil,
            onSavingChanged: ((Bool) -> Void)? = nil
        ) {
            self.file = file
            self.draft = draft
            self.sourceID = sourceID
            self.source = source
            self.onSaved = onSaved
            self.onCancel = onCancel
            self.onSavingChanged = onSavingChanged
        }

        var body: some View {
            #if os(macOS)
                VStack(spacing: 0) {
                    editor
                    Divider()
                    HStack {
                        Spacer()
                        cancelButton
                        saveButton.buttonStyle(.borderedProminent)
                    }
                    .padding(12)
                }
            #else
                NavigationStack {
                    editor
                        .navigationTitle(file.name)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { cancelButton }
                            ToolbarItem(placement: .confirmationAction) { saveButton }
                        }
                }
                .interactiveDismissDisabled()
            #endif
        }

        private var editor: some View {
            VStack(spacing: 0) {
                TextEditor(text: $draft.text)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                    .padding(8)
                    .disabled(draft.isSaving)
                    .accessibilityLabel("Markdown source")
                    .accessibilityIdentifier("file-markdown-source")
                if let message = draft.withinLimit ? error : "Markdown files can be at most 512 KiB." {
                    Text(message).font(.callout).textSelection(.enabled).padding(12)
                }
            }
            .task(id: draft.saveRequest) { [request = draft.saveRequest] in
                guard request != nil, draft.saveRequest == request, !Task.isCancelled else { return }
                onSavingChanged?(true)
                defer {
                    draft.saveRequest = nil
                    onSavingChanged?(false)
                }
                error = nil
                do {
                    let source = source()
                    guard source.id == sourceID else {
                        throw FileBrowserError.message("This draft belongs to a different Host.")
                    }
                    let response = try await source.request(.saveMarkdown(path: file.path, revision: file.revision, data: draft.data))
                    try Task.checkCancellation()
                    guard case let .info(saved) = response, saved.path == file.path, saved.kind == .markdown else {
                        throw FileBrowserError.message("The Host did not confirm the save. Copy your edits before refreshing the preview.")
                    }
                    onSaved()
                } catch is CancellationError { }
                catch {
                    if !Task.isCancelled {
                        self.error = error.localizedDescription
                    }
                }
            }
        }

        private var cancelButton: some View {
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
                .disabled(draft.isSaving)
                .accessibilityIdentifier("file-markdown-cancel")
        }

        @ViewBuilder
        private var saveButton: some View {
            if draft.isSaving {
                ProgressView().controlSize(.small)
            } else {
                Button("Save", action: draft.requestSave)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!draft.canSave)
                    .accessibilityIdentifier("file-markdown-save")
            }
        }

        private func cancel() {
            if let onCancel {
                onCancel()
            } else {
                dismiss()
            }
        }
    }
#endif
