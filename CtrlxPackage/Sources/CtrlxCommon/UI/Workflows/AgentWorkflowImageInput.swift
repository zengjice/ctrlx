import CtrlxNetworking
import os
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif
#if os(iOS)
    import PhotosUI
#endif

@MainActor
struct AgentWorkflowImageInput: View {
    let endpoint: AgentWorkflowEndpoint
    let hostID: UUID
    let title: String
    @Binding var text: String
    @Binding var ids: [UUID]
    @Binding var attachments: [UUID: AgentWorkflowAttachment]
    @Binding var importedIDs: Set<UUID>
    @Binding var importing: Bool
    @Binding var activeImport: AgentWorkflowImageImport?
    var totalImageCount: Int? = nil
    @State private var request: Import?
    @State private var queuedSources: [AgentWorkflowImageSource] = []
    @State private var pendingCount = 0
    @State private var retrySources: [AgentWorkflowImageSource] = []
    @State private var thumbnails: [UUID: Data] = [:]
    @State private var preview: Data?
    @State private var name = ""
    @State private var progress = 0.0
    @State private var error: String?
    @State private var showingFiles = false
    #if os(iOS)
        @State private var showingPhotos = false
        @State private var photos: [PhotosPickerItem] = []
    #endif

    private struct Import {
        let id = UUID()
        let sources: [AgentWorkflowImageSource]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentWorkflowTaskInput(
                title: title, text: $text, ids: ids, attachments: attachments,
                add: { showingFiles = true }, photos: photoAction,
                receive: receive, remove: { id in ids.removeAll { $0 == id } },
                progress: request == nil ? nil : (name, progress), error: error,
                thumbnails: thumbnails
            )
            if let preview {
                AgentWorkflowImageThumbnail(data: preview).frame(height: 80)
            }
            if request != nil {
                Button("Cancel upload") {
                    queuedSources = []
                    retrySources = []
                    activeImport = nil
                }
            } else if !retrySources.isEmpty {
                HStack {
                    Button("Retry image upload") {
                        let sources = retrySources
                        retrySources = []
                        importing = false
                        receive(sources)
                    }.accessibilityIdentifier("workflow-image-retry")
                    Button("Remove failed images") { importing = false }
                }
            }
        }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls): receive(urls.map(AgentWorkflowImageSource.file))
            case let .failure(failure): error = failure.localizedDescription
            }
        }
        #if os(iOS)
        .photosPicker(isPresented: $showingPhotos, selection: $photos, maxSelectionCount: max(1, AgentWorkflowWire.maximumAttachments - ids.count), matching: .images)
        .onChange(of: photos) {
            guard !photos.isEmpty else { return }
            receive(photos.map(AgentWorkflowImageSource.photo))
            photos = []
        }
        #endif
        .onChange(of: importing) {
            if !importing {
                request = nil
                queuedSources = []
                pendingCount = 0
                retrySources = []
                error = nil
                preview = nil
            }
        }
    }

    private var photoAction: (() -> Void)? {
        #if os(iOS)
            { showingPhotos = true }
        #else
            nil
        #endif
    }

    private func receive(_ sources: [AgentWorkflowImageSource]) {
        guard !sources.isEmpty else { return }
        guard max(ids.count, totalImageCount ?? ids.count) + pendingCount + queuedSources.count + sources.count <= AgentWorkflowWire.maximumAttachments else {
            error = "A workflow supports up to 32 images. Choose fewer images."
            return
        }
        if request != nil {
            queuedSources += sources
            return
        }
        guard !importing else {
            error = "Finish, retry or remove pending images before adding more."
            return
        }
        error = nil
        retrySources = []
        name = "Preparing image…"
        progress = 0
        importing = true
        pendingCount = sources.count
        let operation = Import(sources: sources)
        request = operation
        activeImport = .init(id: operation.id, perform: { await self.upload(operation) })
    }

    private func upload(_ operation: Import) async {
        defer {
            if request?.id == operation.id {
                request = nil
                activeImport = nil
                importing = !retrySources.isEmpty
                preview = nil
                pendingCount = 0
                if !queuedSources.isEmpty, !Task.isCancelled {
                    let next = queuedSources
                    queuedSources = []
                    receive(next)
                }
            }
        }
        for (index, source) in operation.sources.enumerated() {
            do {
                try Task.checkCancellation()
                name = "Preparing image…"
                progress = 0
                let image = try await source.load()
                try Task.checkCancellation()
                guard request?.id == operation.id else { return }
                preview = image.data
                name = image.name
                let attachment = try await endpoint.importImage(image, hostID: hostID) { sent, total in
                    guard request?.id == operation.id else { return }
                    progress = total > 0 ? Double(sent) / Double(total) : 0
                }
                // Keep acknowledged imports even if the sheet is cancelled at
                // this boundary; its owner can discard only unreferenced files.
                importedIDs.insert(attachment.id)
                guard request?.id == operation.id, !Task.isCancelled else { return }
                attachments[attachment.id] = attachment
                thumbnails[attachment.id] = image.data
                ids.append(attachment.id)
                pendingCount -= 1
            } catch {
                guard !Task.isCancelled, request?.id == operation.id else { return }
                self.error = error.localizedDescription
                retrySources = Array(operation.sources.dropFirst(index)) + queuedSources
                queuedSources = []
                return
            }
        }
    }
}

@MainActor
struct AgentWorkflowImageThumbnail: View {
    let data: Data
    var body: some View {
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
}

/// Owned by the whole editing page so scrolling a Form row does not cancel I/O.
@MainActor
struct AgentWorkflowImageImport {
    let id: UUID
    let perform: @MainActor () async -> Void
}
