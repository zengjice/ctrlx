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
    func annotationFreezesDisplayedBytesWithoutRequestingANewFrame() async throws {
        let tab = tab()
        var dimensions: [Int] = []
        let session = RemoteSimulatorSession(tab: tab) { request in
            dimensions.append(request.frameMaxDimension)
            return .init(tab: tab, frame: .init(jpeg: Data([UInt8(dimensions.count)]), width: 320, height: 640))
        }
        let watch = Task { await session.watch() }
        try await wait { session.frame != nil }
        let displayed = try #require(session.preview)
        // The next network frame has arrived, but the view still displays the first.
        try await wait { dimensions.count == 2 }
        #expect(session.frame?.jpeg == Data([2]))
        #expect(try session.annotationScreenshot(from: displayed) == Data([1]))
        watch.cancel()
        await watch.value
        #expect(dimensions == [1_024, 1_024])
        #expect(session.frame == nil)
        try await Task.sleep(for: .milliseconds(220))
        #expect(dimensions.count == 2)

        let resumed = Task { await session.watch() }
        defer { session.stop()
            resumed.cancel()
        }
        try await wait { session.frame != nil }
        #expect(session.frame?.jpeg == Data([3]))
        #expect(dimensions == [1_024, 1_024, 1_024])
    }

    @Test(arguments: ["tab", "session", "window", "pane", "empty", "oversized"])
    func annotationRejectsChangedSourcesAndInvalidFrames(_ change: String) async throws {
        let tab = tab()
        let other = RemoteSimulatorTab(
            id: change == "tab" ? UUID() : tab.id,
            sessionName: change == "session" ? "other" : tab.sessionName,
            windowID: change == "window" ? "@other" : tab.windowID,
            sourcePaneID: change == "pane" ? "%other" : tab.sourcePaneID,
            title: tab.title, runtime: tab.runtime, isPrimary: tab.isPrimary
        )
        var requests = 0
        let session = RemoteSimulatorSession(tab: tab) { _ in
            requests += 1
            return .init(tab: tab, frame: .init(jpeg: Data([1]), width: 320, height: 640))
        }
        let watch = Task { await session.watch() }
        defer { session.stop()
            watch.cancel()
        }
        try await wait { session.preview != nil }
        let invalid = RemoteSimulatorResponse(tab: other, frame: .init(
            jpeg: change == "empty" ? Data() : Data([1]),
            width: change == "oversized" ? RemoteSimulatorFrame.maximumDimension + 1 : 320, height: 640
        ))
        #expect(throws: ViewerRelayClientError.self) { try session.annotationScreenshot(from: invalid) }
        #expect(session.preview?.tab == tab && requests == 1)
    }

    @Test
    func annotationRequiresALivePreviewAndNeverFetchesAFallback() throws {
        let tab = tab()
        let session = RemoteSimulatorSession(tab: tab) { _ in
            Issue.record("Annotation must not fetch a replacement frame")
            throw CancellationError()
        }
        let displayed = RemoteSimulatorResponse(tab: tab, frame: .init(jpeg: Data([1]), width: 320, height: 640))
        #expect(throws: ViewerRelayClientError.self) { try session.annotationScreenshot(from: displayed) }
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
        let oldPreview = try #require(session.preview)
        current = moved
        try await wait { previews >= 2 }
        #expect(session.frame == frame && session.error == nil)
        #expect(session.preview?.tab == moved)
        #expect(throws: ViewerRelayClientError.self) { try session.annotationScreenshot(from: oldPreview) }
        let displayed = try #require(session.preview)
        #expect(try session.annotationScreenshot(from: displayed) == frame.jpeg)
        watch.cancel()
        await watch.value

        // Cancelling annotation resumes the same image with the current route.
        let resumed = Task { await session.watch() }
        defer { session.stop()
            resumed.cancel()
        }
        try await wait { session.preview != nil }
        let next = try #require(session.preview)
        #expect(next.tab == moved && next.frame == frame)
        #expect(try session.annotationScreenshot(from: next) == frame.jpeg)
        #expect(previews == 3)
    }

    @Test
    func annotationDoesNotWaitForPendingPreviewAndResumeRestoresTheSameFrame() async throws {
        let tab = tab()
        let frame = RemoteSimulatorFrame(jpeg: Data([1]), width: 320, height: 640)
        var requests = 0
        var reply: CheckedContinuation<RemoteSimulatorResponse, any Error>?
        let session = RemoteSimulatorSession(tab: tab) { request in
            #expect(request.frameMaxDimension == 1_024)
            requests += 1
            if requests == 2 {
                return try await withCheckedThrowingContinuation { reply = $0 }
            }
            return .init(tab: tab, frame: frame)
        }
        let watch = Task { await session.watch() }
        defer { session.stop()
            watch.cancel()
        }
        try await wait { session.frame != nil }
        let displayed = try #require(session.preview)
        try await wait { reply != nil }
        // Capture completes synchronously while the network request remains blocked.
        let screenshot = try session.annotationScreenshot(from: displayed)
        #expect(screenshot == frame.jpeg && requests == 2 && session.preview == nil)
        reply?.resume(returning: .init(tab: tab, frame: .init(jpeg: Data([2]), width: 640, height: 320)))
        await watch.value
        #expect(session.preview == nil && screenshot == Data([1]) && requests == 2)
        #expect(throws: ViewerRelayClientError.self) { try session.annotationScreenshot(from: displayed) }
        let resumed = Task { await session.watch() }
        defer { session.stop()
            resumed.cancel()
        }
        try await wait { session.frame != nil }
        #expect(session.frame == frame && requests == 3)
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
        let session = RemoteSimulatorSession(tab: original) { _ in
            try await withCheckedThrowingContinuation { replies.append($0) }
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
        let displayed = try #require(session.preview)
        #expect(displayed.tab == moved)
        #expect(try session.annotationScreenshot(from: displayed) == frame.jpeg)
    }
}
