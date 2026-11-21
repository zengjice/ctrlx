import Foundation

/// A single provider read whose callback and task cancellation share one continuation.
@MainActor
final class AttachmentPhotoRead {
    private var continuation: CheckedContinuation<Data, any Error>?
    private var progress: Progress?

    func load(_ provider: NSItemProvider, type: String, missingData: any Error) async throws -> Data {
        let data: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                progress = provider.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, error in
                    let result = data.map(Result<Data, any Error>.success) ?? .failure(error ?? missingData)
                    Task { @MainActor in self?.finish(result) }
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.progress?.cancel()
                // A provider may report its result after the Swift task has returned.
                self.finish(.failure(CancellationError()))
            }
        }
        try Task.checkCancellation()
        return data
    }

    private func finish(_ result: Result<Data, any Error>) {
        let pending = continuation
        continuation = nil
        progress = nil
        pending?.resume(with: result)
    }
}
