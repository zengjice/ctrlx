import Foundation
import Testing
@testable import CtrlxFeature

@MainActor @Suite("Browser to terminal handoff")
struct BrowserTerminalHandoffTests {
    @Test func waitsForEveryPaneAndKeepsDestinationMountedUntilReveal() async throws {
        let handoff = BrowserTerminalHandoff()
        let task = Task { try await handoff.prepare(browserID: UUID(), windowID: "@2", paneIDs: ["%1", "%2"]) }
        defer { task.cancel(); handoff.cancel() }
        let request = try await pendingRequest(handoff)
        handoff.update(.ready, paneID: "%1", requestID: request.id)
        handoff.update(.ready, paneID: "%1", requestID: request.id)
        handoff.update(.ready, paneID: "%other", requestID: request.id)
        handoff.update(.ready, paneID: "%2", requestID: UUID())
        #expect(!handoff.isReady(request.id))
        handoff.update(.preparing, paneID: "%1", requestID: request.id)
        handoff.update(.ready, paneID: "%2", requestID: request.id)
        #expect(!handoff.isReady(request.id))
        handoff.update(.ready, paneID: "%1", requestID: request.id)
        #expect(try await task.value == request.id)
        #expect(handoff.request == request)
        #expect(handoff.isReady(request.id))
        handoff.finish(request.id)
        #expect(handoff.request == nil)
    }

    @Test func cancellationReleasesDestination() async throws {
        let handoff = BrowserTerminalHandoff()
        let task = Task { try await handoff.prepare(browserID: UUID(), windowID: "@2", paneIDs: ["%1"]) }
        defer { task.cancel(); handoff.cancel() }
        _ = try await pendingRequest(handoff)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(handoff.request == nil)
    }

    @Test func disconnectOrStreamFailureReleasesWaiterAndCanRetry() async throws {
        let handoff = BrowserTerminalHandoff()
        let task = Task { try await handoff.prepare(browserID: UUID(), windowID: "@2", paneIDs: ["%1"]) }
        defer { task.cancel(); handoff.cancel() }
        let old = try await pendingRequest(handoff)
        handoff.update(.failed("Disconnected"), paneID: "%1", requestID: old.id)
        await #expect(throws: BrowserTerminalHandoff.Failure.self) { try await task.value }
        #expect(handoff.request == nil)
        let retry = Task { try await handoff.prepare(browserID: UUID(), windowID: "@2", paneIDs: ["%1"]) }
        defer { retry.cancel() }
        let current = try await pendingRequest(handoff)
        handoff.cancel(id: old.id)
        handoff.update(.ready, paneID: "%1", requestID: old.id)
        #expect(handoff.request == current)
        #expect(!handoff.isReady(current.id))
        handoff.update(.ready, paneID: "%1", requestID: current.id)
        #expect(try await retry.value == current.id)
    }

    @Test func deadlineReleasesDestination() async {
        let handoff = BrowserTerminalHandoff()
        await #expect(throws: BrowserTerminalHandoff.Failure.self) {
            try await handoff.prepare(browserID: UUID(), windowID: "@2", paneIDs: ["%1"], timeout: .milliseconds(10))
        }
        #expect(handoff.request == nil)
    }

    @Test func emptyDestinationFailsImmediately() async {
        let handoff = BrowserTerminalHandoff()
        await #expect(throws: BrowserTerminalHandoff.Failure.self) {
            try await handoff.prepare(browserID: UUID(), windowID: "@2", paneIDs: [])
        }
        #expect(handoff.request == nil)
    }

    @Test func cancellationAfterReadyPreventsDelayedReveal() async throws {
        let handoff = BrowserTerminalHandoff()
        let task = Task { try await handoff.prepare(browserID: UUID(), windowID: "@2", paneIDs: ["%1"]) }
        defer { task.cancel(); handoff.cancel() }
        let request = try await pendingRequest(handoff)
        handoff.update(.ready, paneID: "%1", requestID: request.id)
        handoff.cancel(id: request.id)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!handoff.isReady(request.id))
    }

    @Test func replacingARequestIgnoresOldCancellation() async throws {
        let handoff = BrowserTerminalHandoff()
        let first = Task { try await handoff.prepare(browserID: UUID(), windowID: "@1", paneIDs: ["%1"]) }
        defer { first.cancel(); handoff.cancel() }
        let old = try await pendingRequest(handoff)
        let second = Task { try await handoff.prepare(browserID: UUID(), windowID: "@2", paneIDs: ["%2"]) }
        defer { second.cancel() }
        await #expect(throws: CancellationError.self) { try await first.value }
        let current = try #require(handoff.request)
        first.cancel()
        handoff.cancel(id: old.id)
        handoff.update(.ready, paneID: "%1", requestID: old.id)
        #expect(handoff.request == current)
        handoff.update(.ready, paneID: "%2", requestID: current.id)
        #expect(try await second.value == current.id)
    }

    private func pendingRequest(_ handoff: BrowserTerminalHandoff) async throws -> BrowserTerminalHandoff.Request {
        let deadline = ContinuousClock.now + .seconds(1)
        while handoff.request == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        return try #require(handoff.request)
    }
}
