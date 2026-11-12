#if os(iOS)
    import SwiftUI
    import UIKit
    import UniformTypeIdentifiers

    @MainActor
    open class ShareExtensionViewController: UIViewController {
        open override func viewDidLoad() {
            super.viewDidLoad()
            guard let context = extensionContext else { return }
            let providers = context.inputItems.compactMap { $0 as? NSExtensionItem }.flatMap { $0.attachments ?? [] }
            let host = UIHostingController(rootView: ReceiveSharedItemsView(providers: providers, context: context))
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            host.didMove(toParent: self)
        }
    }

    @MainActor
    private struct ReceiveSharedItemsView: View {
        let providers: [NSItemProvider]
        let context: NSExtensionContext
        @State private var saved = false
        @State private var error: String?
        @State private var completed = 0
        @State private var cancelled = false
        @State private var publishing = false

        var body: some View {
            NavigationStack {
                VStack(spacing: 20) {
                    if saved {
                        Text("Saved to CtrlX").font(.title2.bold())
                        Text("Open CtrlX to add shared photos to an Agent or upload shared files in Files.")
                            .multilineTextAlignment(.center)
                        Button("Done") { context.completeRequest(returningItems: nil) }
                            .buttonStyle(.borderedProminent)
                    } else if let error {
                        Text("Couldn't Save Shared Items").font(.headline)
                        Text(error).multilineTextAlignment(.center)
                        Button("Close") { context.cancelRequest(withError: ShareInboxError(error)) }
                    } else {
                        ProgressView(value: Double(completed), total: Double(max(1, providers.count)))
                        Text("Saving \(providers.count) item(s)…")
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("CtrlX")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !saved, !publishing {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                guard !publishing else { return }
                                cancelled = true
                                context.cancelRequest(withError: CancellationError())
                            }
                        }
                    }
                }
            }
            .task { await receive() }
        }

        private func receive() async {
            var store: ShareInboxStore?
            var batch: UUID?
            do {
                guard !providers.isEmpty, providers.count <= ShareInboxStore.maximumItems else {
                    throw ShareInboxError("Share between 1 and \(ShareInboxStore.maximumItems) photos or files at a time.")
                }
                let inbox = try ShareInboxStore.appGroupStore()
                store = inbox
                let id = try await inbox.begin()
                batch = id
                let directory = await inbox.stagingDirectory(id)
                var entries: [PreparedSharedItem] = []
                for provider in providers {
                    try Task.checkCancellation()
                    guard !cancelled else { throw CancellationError() }
                    try entries.append(await copy(provider, to: directory, maximumBytes: ShareInboxStore.maximumFileBytes - entries.reduce(0) { $0 + $1.size }))
                    completed += 1
                }
                try Task.checkCancellation()
                guard !cancelled else { throw CancellationError() }
                publishing = true
                try await inbox.commit(id, entries: entries)
                saved = true
            } catch {
                publishing = false
                if let store, let batch {
                    do { try await store.cancel(batch) }
                    catch { self.error = "The incomplete import could not be removed: \(error.localizedDescription)" }
                }
                if self.error == nil {
                    self.error = error.localizedDescription
                }
            }
        }

        private func copy(_ provider: NSItemProvider, to directory: URL, maximumBytes: Int) async throws -> PreparedSharedItem {
            let identifiers = provider.registeredTypeIdentifiers
            let image = identifiers.first { UTType($0)?.conforms(to: .image) == true }
            let type = image ?? identifiers.first { $0 != UTType.fileURL.identifier && UTType($0)?.conforms(to: .data) == true }
            let kind: SharedItemKind = image == nil ? .file : .photo
            let suggestedName = provider.suggestedName.flatMap { $0.isEmpty ? nil : $0 }
            if let type {
                return try await withCheckedThrowingContinuation { continuation in
                    provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                        do {
                            if let error {
                                throw error
                            }
                            guard let url else { throw ShareInboxError("The source app did not provide a file.") }
                            var name = suggestedName ?? url.lastPathComponent
                            if kind == .photo, (name as NSString).pathExtension.isEmpty, let ext = UTType(type)?.preferredFilenameExtension {
                                name += "." + ext
                            }
                            try continuation.resume(returning: PreparedSharedItem.copy(from: url, to: directory, name: name, kind: kind, maximumBytes: maximumBytes))
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                return try await withCheckedThrowingContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                        do {
                            if let error {
                                throw error
                            }
                            guard let url = item as? URL, url.isFileURL else { throw ShareInboxError("The source app did not provide a file URL.") }
                            let granted = url.startAccessingSecurityScopedResource()
                            defer {
                                if granted {
                                    url.stopAccessingSecurityScopedResource()
                                }
                            }
                            try ShareInboxStore.validateFile(url, maximumSize: maximumBytes)
                            var coordinationError: NSError?
                            var result: Result<PreparedSharedItem, any Error>?
                            NSFileCoordinator().coordinate(readingItemAt: url, options: .forUploading, error: &coordinationError) { snapshot in
                                result = Result {
                                    try PreparedSharedItem.copy(from: snapshot, to: directory, name: url.lastPathComponent, kind: .file, maximumBytes: maximumBytes)
                                }
                            }
                            if let coordinationError {
                                throw coordinationError
                            }
                            guard let result else { throw ShareInboxError("The shared file could not be read.") }
                            try continuation.resume(returning: result.get())
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            }
            throw ShareInboxError("Share photos or files. This item type isn't supported.")
        }
    }
#endif
