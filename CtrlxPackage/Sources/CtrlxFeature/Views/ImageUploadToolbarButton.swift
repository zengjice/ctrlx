#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import CtrlxShare
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
        var sharedContext: TerminalPhraseContext? = nil
        var shareReceiverID: UUID? = nil
        var onAttachmentPresentationChange: @MainActor (Bool) -> Void = { _ in }
        @Environment(IOSSettings.self) private var settings
        @Environment(IOSShareInbox.self) private var shareInbox

        @Dependency(ClipboardClient.self) private var clipboard

        @State private var targetPaneId: String?
        @State private var targetBinding = ViewerWorkspaceInputBinding.unavailable
        @State private var selectedPhotos: [PhotoSelection] = []
        @State private var isPhotoPickerPresented = false
        @State private var usesSystemPhotoPicker = false
        @State private var isFileImporterPresented = false
        @State private var isCameraPresented = false
        @State private var capturedPhoto: Data?
        @State private var attachmentSelectionIsActive = false
        @State private var isPreviewPresented = false
        @State private var previewCoversTerminal = false
        @State private var draftImages: [ImageUploadDraftItem] = []
        @State private var operationTask: Task<Void, Never>?
        @State private var operationID: UUID?
        @State private var sourceErrorMessage: String?
        @State private var uploadErrorMessage: String?
        @State private var sharedImport: SharedPhotoImport?

        private enum PhotoSelection {
            case library(PhotoLibraryPhoto)
            case provider(NSItemProvider)
        }

        var body: some View {
            Menu {
                Button(action: choosePhotos) {
                    Label("Photo Library…", symbol: .photoBadgePlus)
                }

                Button {
                    choosePhotos()
                    usesSystemPhotoPicker = isPhotoPickerPresented
                } label: {
                    Label("System Photo Picker…", symbol: .photo)
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
            .sheet(isPresented: $isPhotoPickerPresented, onDismiss: photoPickerDidDismiss) {
                if usesSystemPhotoPicker {
                    AttachmentPhotoPicker(selectionLimit: Self.maximumImages) { results in
                        selectedPhotos = results.map { .provider($0.itemProvider) }
                        isPhotoPickerPresented = false
                    }
                } else {
                    PhotoLibraryPicker(limit: Self.maximumImages) { photos in
                        selectedPhotos = photos.map(PhotoSelection.library)
                    }
                }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.image],
                allowsMultipleSelection: true,
                onCompletion: handleFileSelection,
                onCancellation: cancelAttachmentSelection
            )
            .fullScreenCover(isPresented: $isCameraPresented, onDismiss: cameraDidDismiss) {
                CameraImagePicker(
                    onCapture: { data in
                        capturedPhoto = data
                        isCameraPresented = false
                    },
                    onCancel: { isCameraPresented = false }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $isPreviewPresented, onDismiss: previewDidDismiss) {
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
            .onChange(of: clipboardPaste?.id) { _, _ in
                guard let request = clipboardPaste else { return }
                clipboardPaste = nil
                guard canStartInput, request.paneId == paneId, captureTargetPane() else { return }
                prepareClipboardImage(request.image)
            }
            .onAppear(perform: publishAttachmentPresentation)
            .onDisappear(perform: handleDisappear)
            .onChange(of: shareInbox.photoRequest?.id) { receiveSharedPhotos() }
            .onChange(of: canStartInput) {
                if canStartInput {
                    receiveSharedPhotos()
                }
            }
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
                        setSourceErrorMessage(nil)
                    }
                }
            )) {
                Button("OK") { setSourceErrorMessage(nil) }
            } message: {
                if let sourceErrorMessage {
                    Text(sourceErrorMessage)
                }
            }
        }

        private var canStartInput: Bool {
            relayClient.isHostConnected && paneId != nil && operationID == nil
                && !attachmentSelectionIsActive && !previewCoversTerminal
        }

        private func receiveSharedPhotos() {
            guard
                canStartInput, !isPreviewPresented, let sharedContext, let shareReceiverID,
                shareInbox.photoRequest?.target == sharedContext.target,
                shareInbox.photoRequest?.receiverID == shareReceiverID, captureTargetPane(),
                let items = shareInbox.takePhotos(for: sharedContext, receiverID: shareReceiverID), let id = beginOperation() else { return }
            sharedImport = SharedPhotoImport(inbox: shareInbox)
            operationTask = Task {
                do {
                    let sources = try await Task.detached(priority: .userInitiated) {
                        try items.map { item in
                            let data = try Data(contentsOf: item.url, options: .mappedIfSafe)
                            guard data.count <= ShareInboxStore.maximumPhotoBytes else { throw ImageUploadError.unreadable(item.name) }
                            return ImageUploadSource(displayName: item.name, data: data, sharedItemID: item.id)
                        }
                    }.value
                    try await prepareAndPresent(sources, operationID: id)
                } catch is CancellationError {
                    if operationID == id {
                        finishSharedImport()
                    }
                } catch { presentSourceError(error, operationID: id) }
                finishOperation(id)
            }
        }

        private func choosePhotos() {
            guard captureTargetPane() else { return }
            setAttachmentSelectionActive(true)
            isPhotoPickerPresented = true
        }

        private func chooseFiles() {
            guard captureTargetPane() else { return }
            setAttachmentSelectionActive(true)
            isFileImporterPresented = true
        }

        private func takePhoto() {
            guard
                UIImagePickerController.isSourceTypeAvailable(.camera),
                captureTargetPane()
            else { return }
            setAttachmentSelectionActive(true)
            isCameraPresented = true
        }

        private func cameraDidDismiss() {
            let photo = capturedPhoto
            capturedPhoto = nil
            guard let photo, targetPaneId != nil else {
                cancelAttachmentSelection()
                return
            }
            startPreparation([ImageUploadSource(displayName: "Camera Photo", data: photo)])
        }

        private func pasteImage() {
            guard captureTargetPane() else { return }
            prepareClipboardImage(clipboard.getImage())
        }

        private func prepareClipboardImage(_ image: ClipboardImage?) {
            guard let image else {
                targetPaneId = nil
                setSourceErrorMessage(ImageUploadError.noClipboardImage.localizedDescription)
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
            setSourceErrorMessage(nil)
            uploadErrorMessage = nil
            return true
        }

        private func photoPickerDidDismiss() {
            let items = selectedPhotos
            selectedPhotos = []
            usesSystemPhotoPicker = false
            guard !items.isEmpty, let currentOperationID = beginOperation() else {
                cancelAttachmentSelection()
                return
            }

            operationTask = Task { @MainActor in
                do {
                    var sources: [ImageUploadSource] = []
                    sources.reserveCapacity(items.count)
                    for (index, item) in items.enumerated() {
                        try Task.checkCancellation()
                        let name = "Photo \(index + 1)"
                        let data = switch item {
                        case let .library(photo): try await photo.load()
                        case let .provider(provider): try await loadPhoto(provider, name: name)
                        }
                        sources.append(ImageUploadSource(
                            displayName: name,
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

        private func loadPhoto(_ provider: NSItemProvider, name: String) async throws -> Data {
            guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
                throw ImageUploadError.unreadable(name)
            }
            return try await AttachmentPhotoRead().load(provider, type: type, missingData: ImageUploadError.unreadable(name))
        }

        private func handleFileSelection(_ result: Result<[URL], Error>) {
            switch result {
            case let .success(urls):
                loadFiles(urls)
            case let .failure(error):
                setSourceErrorMessage(error.localizedDescription)
            }
            if operationID == nil {
                cancelAttachmentSelection()
            }
        }

        private func cancelAttachmentSelection() {
            targetPaneId = nil
            targetBinding = .unavailable
            setAttachmentSelectionActive(false)
        }

        private func loadFiles(_ urls: [URL]) {
            guard !urls.isEmpty else {
                targetPaneId = nil
                return
            }
            guard urls.count <= Self.maximumImages else {
                targetPaneId = nil
                setSourceErrorMessage(ImageUploadError.tooManyImages.localizedDescription)
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
            try Task.checkCancellation()
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
                    image: image,
                    sharedItemID: source.sharedItemID
                )
            }
            if settings.confirmImageUploads {
                presentPreview()
            } else {
                setAttachmentSelectionActive(false)
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
                if let id = item.sharedItemID {
                    shareInbox.acknowledge(id)
                }
            }

            draftImages = []
            self.targetPaneId = nil
            targetBinding = .unavailable
            isPreviewPresented = false
            finishSharedImport()
        }

        private func presentUploadError(_ error: Error) {
            uploadErrorMessage = error.localizedDescription
            presentPreview()
        }

        private func presentPreview() {
            previewCoversTerminal = true
            publishAttachmentPresentation()
            isPreviewPresented = true
        }

        private func setAttachmentSelectionActive(_ active: Bool) {
            attachmentSelectionIsActive = active
            publishAttachmentPresentation()
        }

        private func setSourceErrorMessage(_ message: String?) {
            sourceErrorMessage = message
            publishAttachmentPresentation()
        }

        private func publishAttachmentPresentation() {
            onAttachmentPresentationChange(attachmentSelectionIsActive || previewCoversTerminal || sourceErrorMessage != nil)
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
            setAttachmentSelectionActive(false)
        }

        private func presentSourceError(_ error: Error, operationID: UUID) {
            guard self.operationID == operationID else { return }
            setSourceErrorMessage(error.localizedDescription)
            targetPaneId = nil
            finishSharedImport()
        }

        private func previewDidDismiss() {
            guard !isPreviewPresented else { return }
            previewCoversTerminal = false
            publishAttachmentPresentation()
            guard operationID == nil else { return }
            draftImages = []
            targetPaneId = nil
            targetBinding = .unavailable
            uploadErrorMessage = nil
            finishSharedImport()
        }

        private func handleDisappear() {
            clipboardPaste = nil
            guard
                !isPhotoPickerPresented,
                !isFileImporterPresented,
                !isCameraPresented,
                !previewCoversTerminal
            else { return }
            cancelOperation()
            setSourceErrorMessage(nil)
        }

        private func cancelOperation() {
            let wasPreparing = operationID != nil
            operationTask?.cancel()
            operationTask = nil
            operationID = nil
            draftImages = []
            targetPaneId = nil
            targetBinding = .unavailable
            finishSharedImport()
            if wasPreparing {
                setAttachmentSelectionActive(false)
            }
        }

        private func finishSharedImport() {
            sharedImport = nil
        }
    }

    /// Both confirmation and cancellation arrive through the same delegate callback.
    private struct AttachmentPhotoPicker: UIViewControllerRepresentable {
        let selectionLimit: Int
        let onSelection: @MainActor ([PHPickerResult]) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(onSelection: onSelection)
        }

        func makeUIViewController(context: Context) -> PHPickerViewController {
            var configuration = PHPickerConfiguration()
            configuration.filter = .images
            configuration.selectionLimit = selectionLimit
            configuration.preferredAssetRepresentationMode = .automatic
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_: PHPickerViewController, context _: Context) { }

        final class Coordinator: NSObject, PHPickerViewControllerDelegate {
            let onSelection: @MainActor ([PHPickerResult]) -> Void

            init(onSelection: @escaping @MainActor ([PHPickerResult]) -> Void) {
                self.onSelection = onSelection
            }

            func picker(_: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
                onSelection(results)
            }
        }
    }

    /// A discarded view/preview must release the inbox reservation even when
    /// no upload task remains to call its completion path.
    @MainActor
    final private class SharedPhotoImport {
        let inbox: IOSShareInbox
        init(inbox: IOSShareInbox) {
            self.inbox = inbox
        }

        isolated deinit { inbox.finishPhotos() }
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
        var sharedItemID: UUID? = nil
    }

    struct ImageUploadDraftItem: Identifiable, Sendable {
        let id = UUID()
        let displayName: String
        let image: ClipboardImage
        var sharedItemID: UUID? = nil
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
