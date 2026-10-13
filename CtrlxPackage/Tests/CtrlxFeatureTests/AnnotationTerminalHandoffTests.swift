import Foundation
import Testing
@testable import CtrlxFeature

@MainActor @Suite("Annotation to terminal handoff")
struct AnnotationTerminalHandoffTests {
    @Test(arguments: [AnnotationTerminalHandoff.Source.browser(UUID()), .file(UUID()), .simulator(UUID())])
    func waitsForEveryPaneAndKeepsDestinationMountedUntilReveal(source: AnnotationTerminalHandoff.Source) async throws {
        let handoff = AnnotationTerminalHandoff()
        let task = Task { try await handoff.prepare(source: source, windowID: "@2", paneIDs: ["%1", "%2"]) }
        defer { task.cancel(); handoff.cancel() }
        let request = try await pendingRequest(handoff)
        #expect(request.source == source)
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

    @Test(arguments: [AnnotationTerminalHandoff.Source.file(UUID()), .simulator(UUID())])
    func cancellationReleasesDestination(source: AnnotationTerminalHandoff.Source) async throws {
        let handoff = AnnotationTerminalHandoff()
        let task = Task { try await handoff.prepare(source: source, windowID: "@2", paneIDs: ["%1"]) }
        defer { task.cancel(); handoff.cancel() }
        _ = try await pendingRequest(handoff)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(handoff.request == nil)
    }

    @Test func disconnectOrStreamFailureReleasesWaiterAndCanRetry() async throws {
        let handoff = AnnotationTerminalHandoff()
        let task = Task { try await handoff.prepare(source: .file(UUID()), windowID: "@2", paneIDs: ["%1"]) }
        defer { task.cancel(); handoff.cancel() }
        let old = try await pendingRequest(handoff)
        handoff.update(.failed("Disconnected"), paneID: "%1", requestID: old.id)
        await #expect(throws: AnnotationTerminalHandoff.Failure.self) { try await task.value }
        #expect(handoff.request == nil)
        let retry = Task { try await handoff.prepare(source: .file(UUID()), windowID: "@2", paneIDs: ["%1"]) }
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
        let handoff = AnnotationTerminalHandoff()
        await #expect(throws: AnnotationTerminalHandoff.Failure.self) {
            try await handoff.prepare(source: .file(UUID()), windowID: "@2", paneIDs: ["%1"], timeout: .milliseconds(10))
        }
        #expect(handoff.request == nil)
    }

    @Test func emptyDestinationFailsImmediately() async {
        let handoff = AnnotationTerminalHandoff()
        await #expect(throws: AnnotationTerminalHandoff.Failure.self) {
            try await handoff.prepare(source: .file(UUID()), windowID: "@2", paneIDs: [])
        }
        #expect(handoff.request == nil)
    }

    @Test func cancellationAfterReadyPreventsDelayedReveal() async throws {
        let handoff = AnnotationTerminalHandoff()
        let task = Task { try await handoff.prepare(source: .file(UUID()), windowID: "@2", paneIDs: ["%1"]) }
        defer { task.cancel(); handoff.cancel() }
        let request = try await pendingRequest(handoff)
        handoff.update(.ready, paneID: "%1", requestID: request.id)
        handoff.cancel(id: request.id)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!handoff.isReady(request.id))
    }

    @Test func replacingARequestIgnoresOldCancellation() async throws {
        let handoff = AnnotationTerminalHandoff()
        let sourceID = UUID()
        let first = Task { try await handoff.prepare(source: .browser(sourceID), windowID: "@1", paneIDs: ["%1"]) }
        defer { first.cancel(); handoff.cancel() }
        let old = try await pendingRequest(handoff)
        let second = Task { try await handoff.prepare(source: .simulator(sourceID), windowID: "@2", paneIDs: ["%2"]) }
        defer { second.cancel() }
        await #expect(throws: CancellationError.self) { try await first.value }
        let current = try #require(handoff.request)
        #expect(current.source == .simulator(sourceID))
        first.cancel()
        handoff.cancel(id: old.id)
        handoff.update(.ready, paneID: "%1", requestID: old.id)
        #expect(handoff.request == current)
        handoff.update(.ready, paneID: "%2", requestID: current.id)
        #expect(try await second.value == current.id)
    }

    private func pendingRequest(_ handoff: AnnotationTerminalHandoff) async throws -> AnnotationTerminalHandoff.Request {
        let deadline = ContinuousClock.now + .seconds(1)
        while handoff.request == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        return try #require(handoff.request)
    }
}
