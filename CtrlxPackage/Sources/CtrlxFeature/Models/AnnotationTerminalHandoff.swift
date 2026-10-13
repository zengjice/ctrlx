import Foundation
import Observation

enum TerminalPresentationStatus: Equatable {
    case preparing
    case ready
    case failed(String)
}

/// Keeps one destination mounted until the caller reveals it or cancels.
@MainActor @Observable
final class AnnotationTerminalHandoff {
    enum Source: Equatable {
        case browser(UUID)
        case file(UUID)
    }

    struct Request: Equatable {
        let id = UUID()
        let source: Source
        let windowID: String
        let paneIDs: Set<String>
    }

    private(set) var request: Request?
    @ObservationIgnored private var readyPanes: Set<String> = []
    @ObservationIgnored private var continuation: CheckedContinuation<Void, any Error>?

    func prepare(source: Source, windowID: String, paneIDs: Set<String>,
                 timeout: Duration = .seconds(15)) async throws -> UUID {
        try Task.checkCancellation()
        cancel()
        guard !paneIDs.isEmpty else { throw Failure("The Agent window has closed.") }
        let request = Request(source: source, windowID: windowID, paneIDs: paneIDs)
        self.request = request
        readyPanes = []
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.cancel(id: request.id, error: Failure("Opening the Agent terminal timed out. Try Open Agent again."))
        }
        defer {
            deadline.cancel()
            if Task.isCancelled { cancel(id: request.id) }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled { cancel(id: request.id) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: request.id) }
        }
        try Task.checkCancellation()
        guard self.request?.id == request.id else { throw CancellationError() }
        return request.id
    }

    func update(_ status: TerminalPresentationStatus, paneID: String, requestID: UUID) {
        guard let request, request.id == requestID, request.paneIDs.contains(paneID) else { return }
        switch status {
        case .preparing: readyPanes.remove(paneID)
        case .ready: readyPanes.insert(paneID)
        case let .failed(message):
            cancel(id: requestID, error: Failure(message))
            return
        }
        if readyPanes == request.paneIDs {
            // Do not remove the mounted destination before the caller selects it.
            let waiter = continuation
            continuation = nil
            waiter?.resume()
        }
    }

    func isReady(_ id: UUID) -> Bool {
        guard let request, request.id == id else { return false }
        return readyPanes == request.paneIDs
    }

    func finish(_ id: UUID) {
        guard request?.id == id, continuation == nil else { return }
        request = nil
        readyPanes = []
    }

    func cancel(id: UUID? = nil, error: any Error = CancellationError()) {
        if let id, request?.id != id { return }
        request = nil
        readyPanes = []
        let waiter = continuation
        continuation = nil
        waiter?.resume(throwing: error)
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
