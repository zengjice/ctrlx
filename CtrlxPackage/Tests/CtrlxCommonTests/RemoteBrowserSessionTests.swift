import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@Suite("Remote browser surface") @MainActor
struct RemoteBrowserSessionTests {
    @MainActor final class Host {
        var control = UUID()
        var operations: [RemoteBrowserOperation] = []
        var generations: [UInt64?] = []
        var controlIDs: [UUID?] = []
        var owned = false
        var inFlight = 0
        var maximumFrames = 0
        var heldInput: CheckedContinuation<RemoteBrowserResponse, any Error>?
        var heldInputFinished = false
        let tab: RemoteBrowserTab
        init(agent: Bool) {
            tab = RemoteBrowserTab(id: UUID(), sessionName: "s", title: "page", url: "about:blank", isLoading: false, isAgentOwned: agent)
        }
        func send(_ request: BrowseBrowser) async throws -> RemoteBrowserResponse {
            operations.append(request.operation)
            generations.append(request.generation)
            controlIDs.append(request.controlID)
            switch request.operation {
            case .takeControl: control = UUID(); owned = true; return .init(tab: tab, controlID: control)
            case .releaseControl:
                if request.controlID == control { owned = false }
                return .init(tab: tab)
            case .frame:
                inFlight += 1
                maximumFrames = max(maximumFrames, inFlight)
                defer { inFlight -= 1 }
                try await Task.sleep(for: .milliseconds(2))
                return .init(tab: tab, frame: .init(jpeg: Data([1]), width: 1200, height: 700, generation: 1),
                             controlID: owned && request.controlID == control ? control : nil)
            case .text("hold"):
                defer { heldInputFinished = true }
                return try await withCheckedThrowingContinuation { heldInput = $0 }
            default: return .init(tab: tab, controlID: owned ? control : nil)
            }
        }
    }
    func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Timed out waiting for browser state")
    }
    @Test func coordinatesRespectLetterboxing() {
        let page = CGSize(width: 1000, height: 500), view = CGSize(width: 400, height: 800)
        #expect(RemoteBrowserGeometry.imageRect(viewSize: view, pageSize: page) == CGRect(x: 0, y: 300, width: 400, height: 200))
        #expect(RemoteBrowserGeometry.pagePoint(CGPoint(x: 200, y: 400), viewSize: view, pageSize: page) == CGPoint(x: 500, y: 250))
        #expect(RemoteBrowserGeometry.pagePoint(CGPoint(x: 200, y: 100), viewSize: view, pageSize: page) == nil)
        #expect(RemoteBrowserGeometry.pagePoint(CGPoint(x: 450, y: 100), viewSize: view, pageSize: page, clamped: true) == CGPoint(x: 999, y: 0))
    }
    @Test func manualPageAutoControlAndAgentReadOnly() async throws {
        for agent in [true, false] {
            let host = Host(agent: agent)
            let session = RemoteBrowserSession(tab: host.tab, send: host.send)
            let task = Task { await session.watch() }
            try await wait { session.frame != nil && (agent || session.controlID != nil) }
            #expect((session.controlID != nil) == !agent)
            #expect(host.maximumFrames == 1)
            #expect(!host.operations.contains { if case .fit = $0 { true } else { false } })
            session.stop(); task.cancel(); await task.value
            try await wait { !host.owned }
            #expect(session.frame == nil)
        }
    }
    @Test func boundedOrderedInputAndNoReplayAfterStop() async throws {
        let host = Host(agent: false)
        let session = RemoteBrowserSession(tab: host.tab, send: host.send)
        let task = Task { await session.watch() }
        try await wait { session.controlID != nil }
        session.submit(.text("hold"))
        try await wait { host.heldInput != nil }
        for i in 1...100 {
            session.submit(.pointer(.init(.move, x: Double(i), y: 10, button: .left, buttons: 1)))
        }
        session.submit(.text("queued"))
        #expect(session.error == nil)
        session.stop()
        host.heldInput?.resume(returning: .init())
        host.heldInput = nil
        task.cancel(); await task.value
        #expect(!host.operations.contains(.text("queued")))
        #expect(!host.operations.contains { if case .pointer = $0 { true } else { false } })
    }

    @Test func inputUsesDisplayedFrameGeneration() async throws {
        let host = Host(agent: false)
        let session = RemoteBrowserSession(tab: host.tab, send: host.send)
        let task = Task { await session.watch() }
        defer { session.stop(); task.cancel() }
        try await wait { session.controlID != nil }
        session.submit(.text("from old rendered image"), generation: 0)
        try await wait { host.operations.contains(.text("from old rendered image")) }
        let index = try #require(host.operations.firstIndex(of: .text("from old rendered image")))
        #expect(host.generations[index] == 0, "Do not upgrade input to a newer frame before it is displayed")
    }

    @Test(arguments: [false, true])
    func leaseLossDropsOldInputAcrossRetake(lateFailure: Bool) async throws {
        let host = Host(agent: false)
        let session = RemoteBrowserSession(tab: host.tab, send: host.send)
        let task = Task { await session.watch() }
        defer {
            host.heldInput?.resume(throwing: CancellationError())
            host.heldInput = nil
            session.stop(); task.cancel()
        }
        try await wait { session.controlID != nil }
        let oldControl = try #require(session.controlID)
        session.submit(.text("hold"))
        try await wait { host.heldInput != nil }
        session.submit(.text("stale text"))
        session.submit(.key(.init("Enter", keyCode: 13)))
        session.submit(.pointer(.init(.move, x: 20, y: 30)))

        host.owned = false
        try await wait { session.controlID == nil }
        await session.takeControl()
        let newControl = try #require(session.controlID)
        #expect(newControl != oldControl)
        session.submit(.text("fresh"))
        try await wait { host.operations.contains(.text("fresh")) }

        // The old transport callback can complete even after its Task is cancelled.
        if lateFailure { host.heldInput?.resume(throwing: URLError(.timedOut)) }
        else { host.heldInput?.resume(returning: .init(controlID: oldControl)) }
        host.heldInput = nil
        try await wait { host.heldInputFinished }
        session.submit(.text("after late response"))
        try await wait { host.operations.contains(.text("after late response")) }
        #expect(!host.operations.contains(.text("stale text")))
        #expect(!host.operations.contains(.key(.init("Enter", keyCode: 13))))
        #expect(!host.operations.contains { if case .pointer = $0 { true } else { false } })
        #expect(session.controlID == newControl)
        #expect(session.error == nil)
        for text in ["fresh", "after late response"] {
            let index = try #require(host.operations.firstIndex(of: .text(text)))
            #expect(host.controlIDs[index] == newControl)
        }
    }

    @Test func leaseLossDropsOldInputWithoutRetake() async throws {
        let host = Host(agent: false)
        let session = RemoteBrowserSession(tab: host.tab, send: host.send)
        let task = Task { await session.watch() }
        defer {
            host.heldInput?.resume(throwing: CancellationError())
            host.heldInput = nil
            session.stop(); task.cancel()
        }
        try await wait { session.controlID != nil }
        session.submit(.text("hold"))
        try await wait { host.heldInput != nil }
        session.submit(.text("stale"))
        host.owned = false
        try await wait { session.controlID == nil }
        host.heldInput?.resume(returning: .init())
        host.heldInput = nil
        try await wait { host.heldInputFinished }
        #expect(!host.operations.contains(.text("stale")))
        #expect(session.controlID == nil)
        #expect(session.frame != nil, "Losing control must not stop read-only viewing")
    }
}
