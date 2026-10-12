import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct SharedTerminalLayoutSyncTests {
    @Test("A successful layout update has no error")
    func success() {
        #expect(MainView.sharedTerminalLayoutSyncError(.success(.success(for: UUID()))) == nil)
    }

    @Test("A cancellation response is normal control flow even before the caller's cancellation flag is set")
    func cancellationResponse() {
        #expect(!Task.isCancelled)
        #expect(MainView.sharedTerminalLayoutSyncError(.failure(CancellationError())) == nil)
    }

    @Test("Current requests still report disconnects, timeouts and Host rejection",
          arguments: [ViewerRelayClientError.notConnected, .timeout, .commandFailed("Left window no longer exists")])
    func genuineFailure(error: ViewerRelayClientError) {
        #expect(MainView.sharedTerminalLayoutSyncError(.failure(error)) == "Failed to update shared layout: \(error.localizedDescription)")
    }

    @Test("Cancelling during a remote request ignores any late response", arguments: ["cancelled", "timeout", "success"])
    func cancelledDuringSend(outcome: String) async throws {
        let reply = PendingReply()
        let task = Task {
            MainView.sharedTerminalLayoutSyncError(await reply.receive())
        }
        defer {
            task.cancel()
            reply.finish(.failure(CancellationError()))
        }
        try await reply.waitUntilPending()
        task.cancel()
        switch outcome {
        case "cancelled": reply.finish(.failure(CancellationError()))
        case "timeout": reply.finish(.failure(ViewerRelayClientError.timeout))
        default: reply.finish(.success(.success(for: UUID())))
        }
        #expect(await task.value == nil)
    }

    @Test("Rapid window switches preserve the newest update and ignore older failures", arguments: [false, true])
    func consecutiveSwitches(latestFails: Bool) async throws {
        let windowIDs = ["@review", "@intermediate", "@feature-bug"]
        let replies = windowIDs.map { _ in PendingReply() }
        var tasks: [Task<Void, Never>] = []
        var sentWindows: [String] = []
        var alert: String?
        defer {
            tasks.forEach { $0.cancel() }
            replies.forEach { $0.finish(.failure(CancellationError())) }
        }

        for (windowID, reply) in zip(windowIDs, replies) {
            tasks.last?.cancel()
            tasks.append(Task {
                sentWindows.append(windowID)
                let result = await reply.receive()
                if let message = MainView.sharedTerminalLayoutSyncError(result) {
                    alert = message
                }
            })
            try await reply.waitUntilPending()
        }

        let currentError = ViewerRelayClientError.timeout
        replies[2].finish(latestFails ? .failure(currentError) : .success(.success(for: UUID())))
        await tasks[2].value
        let expected = latestFails ? "Failed to update shared layout: \(currentError.localizedDescription)" : nil
        #expect(alert == expected)

        for index in 0..<2 {
            replies[index].finish(.failure(ViewerRelayClientError.commandFailed("Obsolete window \(windowIDs[index])")))
            await tasks[index].value
            #expect(alert == expected, "Old requests must not overwrite the latest window's error state")
        }
        #expect(sentWindows == windowIDs)
    }

    @MainActor
    private final class PendingReply {
        private var continuation: CheckedContinuation<Result<CommandResponseMessage, Error>, Never>?

        func receive() async -> Result<CommandResponseMessage, Error> {
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilPending() async throws {
            for _ in 0..<1_000 where continuation == nil { await Task.yield() }
            try #require(continuation != nil)
        }

        func finish(_ result: Result<CommandResponseMessage, Error>) {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: result)
        }
    }
}
