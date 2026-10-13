import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct RemoteSimulatorSessionTests {
    private func tab(_ session: String = "work") -> RemoteSimulatorTab {
        .init(id: UUID(), sessionName: session, windowID: "@1", sourcePaneID: "%1", title: "iPhone", runtime: "iOS 27", isPrimary: true)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CancellationError()
    }

    @Test
    func stoppingDiscardsLateFramesAndCannotStartMoreRequests() async throws {
        let tab = tab()
        var reply: CheckedContinuation<RemoteSimulatorResponse, any Error>?
        var requests = 0
        let session = RemoteSimulatorSession(tab: tab) { request in
            #expect(request.tabID == tab.id && request.sessionName == "work")
            requests += 1
            return try await withCheckedThrowingContinuation { reply = $0 }
        }
        let watch = Task { await session.watch() }
        try await wait { reply != nil }
        session.stop()
        reply?.resume(returning: .init(tab: tab, frame: .init(jpeg: Data([1]), width: 320, height: 640)))
        await watch.value
        #expect(session.frame == nil && requests == 1)
    }

    @Test
    func restartingRequestsANewFrameWithoutRetainingTheOldImage() async throws {
        let tab = tab()
        var calls = 0
        let session = RemoteSimulatorSession(tab: tab) { _ in
            calls += 1
            return .init(tab: tab, frame: .init(jpeg: Data([UInt8(calls)]), width: 320, height: 640))
        }
        let first = Task { await session.watch() }
        try await wait { session.frame != nil }
        session.stop()
        first.cancel()
        await first.value
        #expect(session.frame == nil)
        let next = Task { await session.watch() }
        try await wait { session.frame != nil }
        #expect(session.frame?.jpeg == Data([2]))
        session.stop()
        next.cancel()
        await next.value
    }

    @Test
    func pollingIsSerialAndResolutionChangesDoNotRestartIt() async throws {
        let tab = tab()
        var dimensions: [Int] = [], inFlight = 0, maximumInFlight = 0
        let session = RemoteSimulatorSession(tab: tab) { request in
            dimensions.append(request.frameMaxDimension)
            inFlight += 1
            maximumInFlight = max(maximumInFlight, inFlight)
            defer { inFlight -= 1 }
            try await Task.sleep(for: .milliseconds(15))
            return .init(tab: tab, frame: .init(jpeg: Data([1]), width: 320, height: 640))
        }
        let watch = Task { await session.watch() }
        try await wait { session.frame != nil }
        session.frameMaxDimension = 1_280
        try await wait { dimensions.contains(1_280) }
        session.stop()
        watch.cancel()
        await watch.value
        #expect(maximumInFlight == 1 && session.frame == nil)
    }

    @Test
    func framesFromAnotherTabAreNeverDisplayed() async throws {
        let expected = tab(), other = tab()
        let session = RemoteSimulatorSession(tab: expected) { _ in
            .init(tab: other, frame: .init(jpeg: Data([1]), width: 320, height: 640))
        }
        let watch = Task { await session.watch() }
        try await wait { session.error != nil }
        session.stop()
        watch.cancel()
        await watch.value
        #expect(session.frame == nil)
    }

    @Test
    func annotationRequestsAFreshFullSizeFrameWithoutPublishingIt() async throws {
        let tab = tab()
        var dimensions: [Int] = []
        let session = RemoteSimulatorSession(tab: tab) { request in
            dimensions.append(request.frameMaxDimension)
            return .init(tab: tab, frame: .init(jpeg: Data([UInt8(dimensions.count)]), width: 320, height: 640))
        }
        let watch = Task { await session.watch() }
        try await wait { session.frame != nil }
        session.stop()
        watch.cancel()
        await watch.value

        #expect(try await session.annotationScreenshot() == Data([2]))
        #expect(dimensions == [1_024, RemoteSimulatorFrame.maximumDimension])
        #expect(session.frame == nil)
        try await Task.sleep(for: .milliseconds(220))
        #expect(dimensions.count == 2)

        let resumed = Task { await session.watch() }
        defer { session.stop()
            resumed.cancel()
        }
        try await wait { session.frame != nil }
        #expect(session.frame?.jpeg == Data([3]))
        #expect(dimensions == [1_024, RemoteSimulatorFrame.maximumDimension, 1_024])
    }

    @Test(arguments: ["tab", "session", "window", "pane", "empty", "oversized"])
    func annotationRejectsChangedSourcesAndInvalidFrames(_ change: String) async {
        let tab = tab()
        let other = RemoteSimulatorTab(
            id: change == "tab" ? UUID() : tab.id,
            sessionName: change == "session" ? "other" : tab.sessionName,
            windowID: change == "window" ? "@other" : tab.windowID,
            sourcePaneID: change == "pane" ? "%other" : tab.sourcePaneID,
            title: tab.title, runtime: tab.runtime, isPrimary: tab.isPrimary
        )
        let session = RemoteSimulatorSession(tab: tab) { _ in
            .init(tab: other, frame: .init(
                jpeg: change == "empty" ? Data() : Data([1]),
                width: change == "oversized" ? RemoteSimulatorFrame.maximumDimension + 1 : 320, height: 640
            ))
        }
        await #expect(throws: ViewerRelayClientError.self) { try await session.annotationScreenshot() }
        #expect(session.frame == nil)
    }

    @Test
    func completedWindowMoveAllowsRepeatedAnnotationsWithoutReopening() async throws {
        let original = tab()
        let moved = RemoteSimulatorTab(
            id: original.id, sessionName: original.sessionName, windowID: "@2", sourcePaneID: original.sourcePaneID,
            title: original.title, runtime: original.runtime, isPrimary: original.isPrimary
        )
        let frame = RemoteSimulatorFrame(jpeg: Data([1]), width: 320, height: 640)
        var current = original
        var previews = 0
        let session = RemoteSimulatorSession(tab: original) { _ in
            previews += 1
            return .init(tab: current, frame: frame)
        }
        let watch = Task { await session.watch() }
        defer { session.stop()
            watch.cancel()
        }
        try await wait { session.frame != nil }
        current = moved
        try await wait { previews >= 2 }
        #expect(session.frame == frame && session.error == nil)
        session.stop()
        watch.cancel()
        await watch.value

        // The image bytes did not change; the new route must still become current.
        for _ in 0..<2 {
            do {
                #expect(try await session.annotationScreenshot() == frame.jpeg)
            } catch {
                Issue.record("Capture after the completed window move failed: \(error)")
            }
        }
    }

    @Test
    func captureKeepsItsStartingRouteEvenIfPollingDiscoversAMove() async throws {
        let original = tab()
        let moved = RemoteSimulatorTab(
            id: original.id, sessionName: original.sessionName, windowID: "@2", sourcePaneID: original.sourcePaneID,
            title: original.title, runtime: original.runtime, isPrimary: original.isPrimary
        )
        let frame = RemoteSimulatorFrame(jpeg: Data([1]), width: 320, height: 640)
        var current = original
        var previews = 0
        var reply: CheckedContinuation<RemoteSimulatorResponse, any Error>?
        let session = RemoteSimulatorSession(tab: original) { request in
            if request.frameMaxDimension == RemoteSimulatorFrame.maximumDimension {
                return try await withCheckedThrowingContinuation { reply = $0 }
            }
            previews += 1
            return .init(tab: current, frame: frame)
        }
        let watch = Task { await session.watch() }
        defer { session.stop()
            watch.cancel()
        }
        try await wait { session.frame != nil }
        let capture = Task { try await session.annotationScreenshot() }
        try await wait { reply != nil }
        current = moved
        try await wait { previews >= 2 }
        session.stop()
        watch.cancel()
        await watch.value
        reply?.resume(returning: .init(tab: moved, frame: frame))
        await #expect(throws: ViewerRelayClientError.self) { try await capture.value }

        reply = nil
        let retry = Task { try await session.annotationScreenshot() }
        try await wait { reply != nil }
        reply?.resume(returning: .init(tab: moved, frame: frame))
        #expect(try await retry.value == frame.jpeg)
    }

    @Test
    func stoppedPollCannotRestoreAnOldCaptureRoute() async throws {
        let original = tab()
        let moved = RemoteSimulatorTab(
            id: original.id, sessionName: original.sessionName, windowID: "@2", sourcePaneID: original.sourcePaneID,
            title: original.title, runtime: original.runtime, isPrimary: original.isPrimary
        )
        let frame = RemoteSimulatorFrame(jpeg: Data([1]), width: 320, height: 640)
        var replies: [CheckedContinuation<RemoteSimulatorResponse, any Error>] = []
        let session = RemoteSimulatorSession(tab: original) { request in
            if request.frameMaxDimension == RemoteSimulatorFrame.maximumDimension {
                return .init(tab: moved, frame: frame)
            }
            return try await withCheckedThrowingContinuation { replies.append($0) }
        }
        let oldWatch = Task { await session.watch() }
        try await wait { replies.count == 1 }
        session.stop()
        let currentWatch = Task { await session.watch() }
        defer { session.stop()
            currentWatch.cancel()
        }
        try await wait { replies.count == 2 }
        replies[1].resume(returning: .init(tab: moved, frame: frame))
        try await wait { session.frame != nil }
        // The old request deliberately ignores cancellation, as a late network reply can.
        replies[0].resume(returning: .init(tab: original, frame: frame))
        await oldWatch.value
        #expect(try await session.annotationScreenshot() == frame.jpeg)
    }

    @Test
    func cancelledAnnotationRejectsALateResponse() async throws {
        let tab = tab()
        var reply: CheckedContinuation<RemoteSimulatorResponse, any Error>?
        let session = RemoteSimulatorSession(tab: tab) { _ in
            try await withCheckedThrowingContinuation { reply = $0 }
        }
        let capture = Task { try await session.annotationScreenshot() }
        try await wait { reply != nil }
        capture.cancel()
        reply?.resume(returning: .init(tab: tab, frame: .init(jpeg: Data([1]), width: 320, height: 640)))
        await #expect(throws: CancellationError.self) { try await capture.value }
        #expect(session.frame == nil)
    }

    @Test
    func annotationDoesNotReviveAnOldPollAndExitRestoresAnUnchangedFrame() async throws {
        let tab = tab()
        let frame = RemoteSimulatorFrame(jpeg: Data([1]), width: 320, height: 640)
        var replies: [CheckedContinuation<RemoteSimulatorResponse, any Error>] = []
        let session = RemoteSimulatorSession(tab: tab) { _ in
            try await withCheckedThrowingContinuation { replies.append($0) }
        }
        let oldWatch = Task { await session.watch() }
        try await wait { replies.count == 1 }
        session.stop()
        oldWatch.cancel()
        let capture = Task { try await session.annotationScreenshot() }
        try await wait { replies.count == 2 }
        replies[1].resume(returning: .init(tab: tab, frame: frame))
        #expect(try await capture.value == frame.jpeg)
        replies[0].resume(returning: .init(tab: tab, frame: frame))
        await oldWatch.value
        #expect(session.frame == nil)

        let resumed = Task { await session.watch() }
        defer { session.stop()
            resumed.cancel()
        }
        try await wait { replies.count == 3 }
        replies[2].resume(returning: .init(tab: tab, frame: frame))
        try await wait { session.frame != nil }
        #expect(session.frame == frame)
    }
}
