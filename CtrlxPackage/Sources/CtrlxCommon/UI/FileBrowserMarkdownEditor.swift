#if os(macOS) || os(iOS)
    import CtrlxNetworking
    import SwiftUI

    @MainActor
    struct FileBrowserMarkdownEditor: View {
        let file: FileBrowserEntry
        let sourceID: String
        let source: FileBrowserSource
        let onSaved: () -> Void
        private let originalData: Data
        private let byteOrderMark: Data
        @Environment(\.dismiss) private var dismiss
        @State private var text: String
        @State private var saveRequest: UUID?
        @State private var error: String?

        init(file: FileBrowserEntry, data: Data, sourceID: String, source: FileBrowserSource, onSaved: @escaping () -> Void) {
            self.file = file
            self.sourceID = sourceID
            self.source = source
            self.onSaved = onSaved
            self.originalData = data
            let bom = Data([0xEF, 0xBB, 0xBF])
            let prefix = data.starts(with: bom) ? bom : Data()
            self.byteOrderMark = prefix
            _text = State(initialValue: String(decoding: data.dropFirst(prefix.count), as: UTF8.self))
        }

        private var withinLimit: Bool {
            text.utf8.count + byteOrderMark.count <= FileBrowserLimits.maximumTextBytes
        }

        private var canSave: Bool {
            withinLimit && !text.utf8.elementsEqual(originalData.dropFirst(byteOrderMark.count))
        }

        var body: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                        .padding(8)
                        .disabled(saveRequest != nil)
                        .accessibilityLabel("Markdown source")
                        .accessibilityIdentifier("file-markdown-source")
                    if let message = withinLimit ? error : "Markdown files can be at most 512 KiB." {
                        Text(message).font(.callout).textSelection(.enabled).padding(12)
                    }
                }
                .navigationTitle(file.name)
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                                .disabled(saveRequest != nil)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            if saveRequest != nil {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Save") { saveRequest = UUID() }
                                    .keyboardShortcut("s", modifiers: .command)
                                    .disabled(!canSave)
                                    .accessibilityIdentifier("file-markdown-save")
                            }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 640, minHeight: 440)
            #endif
            .interactiveDismissDisabled()
            .task(id: saveRequest) {
                guard saveRequest != nil else { return }
                defer { saveRequest = nil }
                error = nil
                do {
                    guard source.id == sourceID else {
                        throw FileBrowserError.message("This draft belongs to a different Host.")
                    }
                    let data = byteOrderMark + Data(text.utf8)
                    let response = try await source.request(.saveMarkdown(path: file.path, revision: file.revision, data: data))
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
    }
#endif
