#if os(macOS) || os(iOS)
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Observation

    #if os(macOS)
        import AppKit

        @DependencyClient
        struct FileBrowserOpener: Sendable {
            var open: @MainActor @Sendable (URL) throws -> Void
            var showInFinder: @MainActor @Sendable (URL) -> Void
        }

        extension FileBrowserOpener: DependencyKey {
            static let liveValue = Self(open: { url in
                guard NSWorkspace.shared.open(url) else {
                    throw FileBrowserError.message("No app could open this file. Install an app that supports its format.")
                }
            }, showInFinder: { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
        }
    #endif

    /// Explicit downloads belong to the Files tab, independently of its preview cache or mounted view.
    @MainActor @Observable
    final class FileBrowserOpenSession {
        enum Action {
            case open
            #if os(macOS)
                case showInFinder
            #endif
        }

        private struct SourceKey: Equatable {
            let id: String
            let connectionID: UUID?
            let unavailable: String?
            let downloadUnavailable: String?
        }

        private(set) var transfer = FileBrowserTransfer()
        var error: String?
        #if os(iOS)
            var previewURL: URL?
            private(set) var downloadedURL: URL?
        #else
            @ObservationIgnored @Dependency(FileBrowserOpener.self) private var opener
        #endif
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
                downloadUnavailable: source.downloadUnavailableReason
            )
            guard key != sourceKey else { return }
            cancel()
            sourceKey = key
        }

        func start(_ action: Action, path: String, source: FileBrowserSource) {
            configure(source: source)
            guard !isRunning else { return }
            error = nil
            task = Task { [weak self, transfer] in
                do {
                    let url = try await transfer.fileForOpening(path: path, source: source)
                    try Task.checkCancellation()
                    #if os(macOS)
                        switch action {
                        case .open: try self?.opener.open(url)
                        case .showInFinder: self?.opener.showInFinder(url)
                        }
                    #else
                        self?.downloadedURL = url
                        self?.previewURL = url
                    #endif
                } catch {
                    if !(error is CancellationError), !Task.isCancelled {
                        self?.error = error.localizedDescription
                    }
                }
                // A cancelled task may have been replaced by another explicit request.
                if !Task.isCancelled {
                    self?.task = nil
                }
            }
        }

        func cancel() {
            task?.cancel()
            task = nil
            transfer = FileBrowserTransfer()
            error = nil
            #if os(iOS)
                previewURL = nil
                downloadedURL = nil
            #endif
        }
    }
#endif
