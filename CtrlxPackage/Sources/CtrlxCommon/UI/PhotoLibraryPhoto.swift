#if os(iOS) || os(macOS)
    import Foundation
    import Photos

    package struct PhotoLibraryPhoto: Identifiable, Hashable, Sendable {
        package let id: String
        private let modificationDate: Date?

        init(asset: PHAsset) {
            self.id = asset.localIdentifier
            self.modificationDate = asset.modificationDate
        }

        func currentAsset() throws -> PHAsset {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                throw PhotoLibraryReadError.unavailable
            }
            guard asset.modificationDate == modificationDate else {
                throw PhotoLibraryReadError.changed
            }
            return asset
        }

        @MainActor
        package func load() async throws -> Data {
            let asset = try currentAsset()
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            let data = try await PhotoLibraryImageRequest<Data>().read { manager, finish in
                manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                    guard info?[PHImageResultIsDegradedKey] as? Bool != true else { return }
                    finish(data, info?[PHImageErrorKey] as? Error)
                }
            }
            // An iCloud read can span a library edit.
            _ = try currentAsset()
            return data
        }
    }

    enum PhotoLibraryReadError: LocalizedError {
        case unavailable
        case changed

        var errorDescription: String? {
            switch self {
            case .unavailable: "This photo could not be read."
            case .changed: "A selected photo was edited. Review the updated photo and select it again."
            }
        }
    }

    /// PhotoKit is callback-based. Cancelling a view or a transfer also cancels its active request.
    @MainActor
    final class PhotoLibraryImageRequest<Value: Sendable> {
        private let manager = PHImageManager.default()
        private var requestID: PHImageRequestID?
        private var continuation: CheckedContinuation<Value, any Error>?

        func read(
            _ request: (PHImageManager, @escaping @Sendable (Value?, Error?) -> Void) -> PHImageRequestID
        ) async throws -> Value {
            let value: Value = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    requestID = request(manager) { [weak self] value, error in
                        let result = value.map(Result<Value, any Error>.success) ?? .failure(error ?? PhotoLibraryReadError.unavailable)
                        Task { @MainActor in self?.finish(result) }
                    }
                }
            } onCancel: {
                Task { @MainActor in
                    if let requestID = self.requestID {
                        self.manager.cancelImageRequest(requestID)
                    }
                    self.finish(.failure(CancellationError()))
                }
            }
            try Task.checkCancellation()
            return value
        }

        private func finish(_ result: Result<Value, any Error>) {
            let pending = continuation
            continuation = nil
            requestID = nil
            pending?.resume(with: result)
        }
    }
#endif
