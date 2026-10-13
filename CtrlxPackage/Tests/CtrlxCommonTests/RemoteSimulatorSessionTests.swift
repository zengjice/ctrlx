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
}
