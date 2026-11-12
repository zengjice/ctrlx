#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    struct SharedItemsNotice: View {
        var showsPhotosHint = true
        var showsFilesHint = true
        @Environment(IOSShareInbox.self) private var inbox
        @State private var confirmsDiscard = false

        var body: some View {
            if (showsPhotosHint && !inbox.photos.isEmpty) || (showsFilesHint && !inbox.files.isEmpty) || inbox.error != nil {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        if showsPhotosHint, !inbox.photos.isEmpty {
                            Text("\(inbox.photos.count) shared photo(s) · open an Agent to attach")
                        }
                        if showsFilesHint, !inbox.files.isEmpty {
                            Text("\(inbox.files.count) shared file(s) · open Files to upload")
                        }
                        if let error = inbox.error {
                            Text(error).foregroundStyle(.red)
                        }
                    }
                    .font(.caption)
                    Spacer()
                    if !inbox.items.isEmpty {
                        Button("Discard") { confirmsDiscard = true }
                            .font(.caption)
                            .disabled(inbox.isDiscarding || inbox.photosBusy || inbox.photoRequest != nil || !inbox.filesBusy.isEmpty)
                    }
                }
                .padding(10)
                .background(.bar)
                .confirmationDialog("Discard Shared Items?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                    Button("Discard Shared Items", role: .destructive) { Task { await inbox.discard() } }
                } message: {
                    Text("Only the copies saved for CtrlX are removed. The originals stay in the source app.")
                }
                .accessibilityIdentifier("shared-items-notice")
            }
        }
    }

    struct SharedFilesImportBar: View {
        let tab: FileBrowserTab
        let source: FileBrowserSource
        @Environment(IOSShareInbox.self) private var inbox

        var body: some View {
            if !inbox.files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Button("Upload \(inbox.files.count) Shared File(s) Here") {
                        let items = inbox.claimFiles()
                        let ids = Set(items.map(\.id))
                        let accepted = tab.importFiles(items.map(\.url), source: source, onSaved: { url in
                            if let item = items.first(where: { $0.url == url }) {
                                inbox.acknowledge(item.id)
                            }
                        }, onFinished: { inbox.finishFiles(ids) })
                        if !accepted {
                            inbox.finishFiles(ids)
                        }
                    }
                    .disabled(inbox.isDiscarding || tab.path == nil || source.unavailableReason != nil || source.uploadUnavailableReason != nil)
                    .accessibilityIdentifier("upload-shared-files")
                    Text("To: \(tab.path ?? "Loading directory…")")
                        .font(.caption).foregroundStyle(.secondary)
                    if let reason = source.unavailableReason ?? source.uploadUnavailableReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.bar)
            }
        }
    }
#endif
