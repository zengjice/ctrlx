import Foundation
import Observation

/// Uploads belong to the live Files tab, not its mounted directory or preview view.
@MainActor @Observable
final class FileBrowserUploadSession {
    enum Input {
        case files([URL])
        case image(WorkspaceClipboardContent)
    }

    private struct SourceKey: Equatable {
        let id: String
        let connectionID: UUID?
        let unavailable: String?
        let uploadUnavailable: String?
    }

    private(set) var upload = FileBrowserUpload()
    private(set) var directory: String?
    private var task: Task<Void, Never>?
    @ObservationIgnored private var sourceKey: SourceKey?

    var isRunning: Bool {
        task != nil
    }

    isolated deinit { task?.cancel() }

    func configure(source: FileBrowserSource) {
        let key = SourceKey(
            id: source.id,
            connectionID: source.connectionID,
            unavailable: source.unavailableReason,
            uploadUnavailable: source.uploadUnavailableReason
        )
        guard key != sourceKey else { return }
        cancel()
        sourceKey = key
    }

    func start(
        _ input: Input,
        directory: String,
        source: FileBrowserSource,
        onSaved: @escaping @MainActor () -> Void,
        onFileSaved: @escaping @MainActor (URL) -> Void = { _ in },
        onFinished: @escaping @MainActor () -> Void = { }
    ) {
        configure(source: source)
        guard !isRunning else { return }
        let upload = FileBrowserUpload()
        self.upload = upload
        self.directory = directory
        task = Task { [weak self] in
            let saved: @MainActor () -> Void = {
                if !Task.isCancelled {
                    onSaved()
                }
            }
            switch input {
            case let .files(urls): await upload.run(urls: urls, directory: directory, source: source, onSaved: saved, onFileSaved: onFileSaved)
            case let .image(content): await upload.run(image: content, directory: directory, source: source, onSaved: saved)
            }
            self?.task = nil
            onFinished()
        }
    }

    func cancel() {
        // Keep the slot occupied until the reader closes and Host cleanup completes.
        task?.cancel()
    }
}
