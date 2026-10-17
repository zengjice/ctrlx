#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import PhotosUI
    import SwiftUI
    import UniformTypeIdentifiers

    /// Collects images from native iOS sources and forwards the prepared batch
    /// to the remote tmux pane through the existing encrypted file-drop command.
    struct ImageUploadToolbarButton: View {
        fileprivate static let maximumImages = 5

        let paneId: String?
        let relayClient: ViewerRelayClient
        @Binding var clipboardPaste: TerminalImagePasteRequest?
        @Environment(IOSSettings.self) private var settings

        @Dependency(ClipboardClient.self) private var clipboard

        @State private var targetPaneId: String?
        @State private var targetBinding = ViewerWorkspaceInputBinding.unavailable
        @State private var selectedPhotos: [PhotosPickerItem] = []
        @State private var isPhotoPickerPresented = false
        @State private var isFileImporterPresented = false
        @State private var isCameraPresented = false
        @State private var isPreviewPresented = false
        @State private var draftImages: [ImageUploadDraftItem] = []
        @State private var operationTask: Task<Void, Never>?
        @State private var operationID: UUID?
        @State private var sourceErrorMessage: String?
        @State private var uploadErrorMessage: String?

        var body: some View {
            Menu {
                Button(action: choosePhotos) {
                    Label("Photo Library", symbol: .photoBadgePlus)
                }

                Button(action: chooseFiles) {
                    Label("Choose Image Files", symbol: .folder)
                }

                Button(action: takePhoto) {
                    Label("Take Photo", symbol: .camera)
                }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                Button(action: pasteImage) {
                    Label("Paste Image", symbol: .docOnClipboard)
                }
            } label: {
                Group {
                    if operationID != nil {
                        ProgressView()
                            .accessibilityLabel(draftImages.isEmpty ? "Preparing Images" : "Sending Images")
                    } else {
                        Label("Attachments", symbol: .plus).labelStyle(.iconOnly)
                    }
                }
                .terminalInputControlStyle()
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canStartInput)
            .opacity(canStartInput ? 1 : 0.4)
            .accessibilityLabel("Attachments")
            .accessibilityIdentifier("terminal-attachment-control")
            .photosPicker(
                isPresented: $isPhotoPickerPresented,
                selection: $selectedPhotos,
                maxSelectionCount: Self.maximumImages,
                matching: .images,
                preferredItemEncoding: .automatic
            )
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.image],
                allowsMultipleSelection: true,
                onCompletion: handleFileSelection
            )
            .fullScreenCover(isPresented: $isCameraPresented) {
                CameraImagePicker(
                    onCapture: { data in
                        isCameraPresented = false
                        startPreparation([
                            ImageUploadSource(displayName: "Camera Photo", data: data),
                        ])
                    },
                    onCancel: {
                        isCameraPresented = false
                        targetPaneId = nil
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $isPreviewPresented, onDismiss: clearDraft) {
                ImageUploadPreviewSheet(
                    images: $draftImages,
                    isUploading: operationID != nil,
                    isConnected: relayClient.isHostConnected,
                    uploadErrorMessage: $uploadErrorMessage,
                    onCancel: { isPreviewPresented = false },
                    onSend: sendDraft
                )
                .interactiveDismissDisabled(operationID != nil)
            }
            .onChange(of: selectedPhotos) { _, items in
                guard !items.isEmpty else { return }
                selectedPhotos = []
                loadPhotos(items)
            }
            .onChange(of: clipboardPaste?.id) { _, _ in
                guard let request = clipboardPaste else { return }
                clipboardPaste = nil
                guard canStartInput, request.paneId == paneId, captureTargetPane() else { return }
                prepareClipboardImage(request.image)
            }
            .onDisappear(perform: handleDisappear)
            .onChange(of: paneId) { _, paneID in
                if let paneID, let targetPaneId, targetPaneId != paneID {
                    cancelOperation()
                    isPreviewPresented = false
                }
            }
            .alert("Image Input Failed", isPresented: .init(
                get: { sourceErrorMessage != nil },
                set: {
                    if !$0 {
                        sourceErrorMessage = nil
                    }
                }
            )) {
                Button("OK") { sourceErrorMessage = nil }
            } message: {
                if let sourceErrorMessage {
                    Text(sourceErrorMessage)
                }
            }
        }

        private var canStartInput: Bool {
            relayClient.isHostConnected && paneId != nil && operationID == nil
        }

        private func choosePhotos() {
            guard captureTargetPane() else { return }
            isPhotoPickerPresented = true
        }

        private func chooseFiles() {
            guard captureTargetPane() else { return }
            isFileImporterPresented = true
        }

        private func takePhoto() {
            guard
                captureTargetPane(),
                UIImagePickerController.isSourceTypeAvailable(.camera)
            else { return }
            isCameraPresented = true
        }

        private func pasteImage() {
            guard captureTargetPane() else { return }
            prepareClipboardImage(clipboard.getImage())
        }

        private func prepareClipboardImage(_ image: ClipboardImage?) {
            guard let image else {
                targetPaneId = nil
                sourceErrorMessage = ImageUploadError.noClipboardImage.localizedDescription
                return
            }
            startPreparation([
                ImageUploadSource(displayName: "Clipboard Image", data: image.data),
            ])
        }

        @discardableResult
        private func captureTargetPane() -> Bool {
            guard relayClient.isHostConnected, let paneId else { return false }
            targetPaneId = paneId
            targetBinding = relayClient.workspaceInputState.binding(paneID: paneId)
            sourceErrorMessage = nil
            uploadErrorMessage = nil
            return true
        }

        private func loadPhotos(_ items: [PhotosPickerItem]) {
            guard let currentOperationID = beginOperation() else { return }

            operationTask = Task { @MainActor in
                do {
                    var sources: [ImageUploadSource] = []
                    sources.reserveCapacity(items.count)
                    for (index, item) in items.enumerated() {
                        try Task.checkCancellation()
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw ImageUploadError.unreadable("Photo \(index + 1)")
                        }
                        sources.append(ImageUploadSource(
                            displayName: "Photo \(index + 1)",
                            data: data
                        ))
                    }
                    try await prepareAndPresent(sources, operationID: currentOperationID)
                } catch is CancellationError {
                    // Leaving the window cancels silently.
                } catch {
                    presentSourceError(error, operationID: currentOperationID)
                }
                finishOperation(currentOperationID)
            }
        }

        private func handleFileSelection(_ result: Result<[URL], Error>) {
            switch result {
            case let .success(urls):
                loadFiles(urls)
            case let .failure(error):
                targetPaneId = nil
                sourceErrorMessage = error.localizedDescription
            }
        }

        private func loadFiles(_ urls: [URL]) {
            guard !urls.isEmpty else {
                targetPaneId = nil
                return
            }
            guard urls.count <= Self.maximumImages else {
                targetPaneId = nil
                sourceErrorMessage = ImageUploadError.tooManyImages.localizedDescription
                return
            }
            guard let currentOperationID = beginOperation() else { return }

            operationTask = Task { @MainActor in
                do {
                    let sources = try await Task.detached(priority: .userInitiated) {
                        try urls.map { url in
                            let hasAccess = url.startAccessingSecurityScopedResource()
                            defer {
                                if hasAccess {
                                    url.stopAccessingSecurityScopedResource()
                                }
                            }
                            let data = try Data(contentsOf: url)
                            return ImageUploadSource(
                                displayName: url.lastPathComponent,
                                data: data
                            )
                        }
                    }.value
                    try Task.checkCancellation()
                    try await prepareAndPresent(sources, operationID: currentOperationID)
                } catch is CancellationError {
                    // Leaving the window cancels silently.
                } catch {
                    presentSourceError(error, operationID: currentOperationID)
                }
                finishOperation(currentOperationID)
            }
        }

        private func startPreparation(_ sources: [ImageUploadSource]) {
            guard let currentOperationID = beginOperation() else { return }

            operationTask = Task { @MainActor in
                do {
                    try await prepareAndPresent(sources, operationID: currentOperationID)
                } catch is CancellationError {
                    // Leaving the window cancels silently.
                } catch {
                    presentSourceError(error, operationID: currentOperationID)
                }
                finishOperation(currentOperationID)
            }
        }

        private func prepareAndPresent(
            _ sources: [ImageUploadSource],
            operationID: UUID
        ) async throws {
            guard !sources.isEmpty, sources.count <= Self.maximumImages else {
                throw ImageUploadError.tooManyImages
            }

            let prepared = await Task.detached(priority: .userInitiated) {
                RelayImagePreparer.prepareBatch(
                    sources.map(\.data),
                    maxTotalBytes: SendDroppedFiles.maxRawBytes
                )
            }.value
            try Task.checkCancellation()

            guard self.operationID == operationID else {
                throw CancellationError()
            }
            guard let prepared else {
                throw ImageUploadError.cannotFitRelayLimit
            }

            draftImages = zip(sources, prepared).map { source, image in
                ImageUploadDraftItem(
                    displayName: source.displayName,
                    image: image
                )
            }
            if settings.confirmImageUploads {
                isPreviewPresented = true
            } else {
                await uploadDraft(operationID: operationID)
            }
        }

        private func sendDraft() {
            guard
                operationID == nil,
                relayClient.isHostConnected,
                targetPaneId != nil,
                !draftImages.isEmpty
            else {
                presentUploadError(ImageUploadError.disconnected)
                return
            }
            guard let currentOperationID = beginOperation() else { return }

            operationTask = Task { @MainActor in
                await uploadDraft(operationID: currentOperationID)
                finishOperation(currentOperationID)
            }
        }

        private func uploadDraft(operationID: UUID) async {
            guard self.operationID == operationID, !Task.isCancelled else { return }
            guard relayClient.isHostConnected, let targetPaneId else {
                presentUploadError(ImageUploadError.disconnected)
                return
            }
            let binding = targetBinding
            let pendingImages = draftImages
            for (index, item) in pendingImages.enumerated() {
                guard self.operationID == operationID, !Task.isCancelled else { return }
                if index > 0 {
                    let separatorResult = await relayClient.sendCommand(
                        SendRawInput(data: Data(" ".utf8)),
                        paneId: targetPaneId,
                        timeout: 30,
                        inputBinding: binding
                    )
                    guard self.operationID == operationID, !Task.isCancelled else { return }
                    if case let .failure(error) = separatorResult {
                        draftImages = Array(pendingImages.dropFirst(index))
                        presentUploadError(error)
                        return
                    }
                }

                let file = DroppedFile(
                    name: "image-\(index + 1).\(item.image.format.fileExtension)",
                    data: item.image.data
                )
                let result = await relayClient.sendCommand(
                    SendDroppedFiles(files: [file]),
                    paneId: targetPaneId,
                    timeout: 30,
                    inputBinding: binding
                )
                guard self.operationID == operationID, !Task.isCancelled else { return }
                if case let .failure(error) = result {
                    draftImages = Array(pendingImages.dropFirst(index))
                    presentUploadError(error)
                    return
                }
            }

            draftImages = []
            self.targetPaneId = nil
            targetBinding = .unavailable
            isPreviewPresented = false
        }

        private func presentUploadError(_ error: Error) {
            uploadErrorMessage = error.localizedDescription
            isPreviewPresented = true
        }

        private func beginOperation() -> UUID? {
            guard operationID == nil, targetPaneId != nil else { return nil }
            let id = UUID()
            operationID = id
            return id
        }

        private func finishOperation(_ id: UUID) {
            guard operationID == id else { return }
            operationTask = nil
            operationID = nil
        }

        private func presentSourceError(_ error: Error, operationID: UUID) {
            guard self.operationID == operationID else { return }
            sourceErrorMessage = error.localizedDescription
            targetPaneId = nil
        }

        private func clearDraft() {
            guard operationID == nil else { return }
            draftImages = []
            targetPaneId = nil
            targetBinding = .unavailable
            uploadErrorMessage = nil
        }

        private func handleDisappear() {
            clipboardPaste = nil
            guard
                !isPhotoPickerPresented,
                !isFileImporterPresented,
                !isCameraPresented,
                !isPreviewPresented
            else { return }
            cancelOperation()
        }

        private func cancelOperation() {
            operationTask?.cancel()
            operationTask = nil
            operationID = nil
            draftImages = []
            targetPaneId = nil
            targetBinding = .unavailable
        }
    }

    /// Captures the clipboard at the explicit paste action, before presenting UI.
    /// A nil image lets the existing source-error alert report an unreadable paste.
    struct TerminalImagePasteRequest: Identifiable {
        let id = UUID()
        let paneId: String
        let image: ClipboardImage?
    }

    private struct ImageUploadSource: Sendable {
        let displayName: String
        let data: Data
    }

    struct ImageUploadDraftItem: Identifiable, Sendable {
        let id = UUID()
        let displayName: String
        let image: ClipboardImage
    }

    private enum ImageUploadError: LocalizedError {
        case unreadable(String)
        case tooManyImages
        case cannotFitRelayLimit
        case disconnected
        case noClipboardImage

        var errorDescription: String? {
            switch self {
            case let .unreadable(name):
                "\(name) could not be read as an image."
            case .tooManyImages:
                "Choose no more than \(ImageUploadToolbarButton.maximumImages) images at once."
            case .cannotFitRelayLimit:
                "The images could not be compressed to the relay's \(SendDroppedFiles.maxRawBytes / 1_024) KB limit."
            case .disconnected:
                "The remote Mac is not connected."
            case .noClipboardImage:
                "The clipboard does not contain an image."
            }
        }
    }
#endif
