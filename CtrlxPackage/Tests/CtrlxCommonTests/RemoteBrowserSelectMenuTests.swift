import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@Suite("Viewer select menus") @MainActor
struct RemoteBrowserSelectMenuTests {
    @MainActor
    final private class FrameFailure {
        var enabled = false
    }

    private func menu(generation: UInt64 = 1) -> RemoteBrowserSelectMenu {
        .init(id: UUID(), generation: generation, title: "跳到条目", options: [
            .init(index: 0, text: "First", selected: true),
            .init(index: 1, text: "Disabled", disabled: true),
            .init(index: 2, text: "Third"),
        ])
    }

    @Test
    func selectionUsesCapturedMenuAndConsumesItOnce() async throws {
        let host = RemoteBrowserSessionTests.Host(agent: false), menu = menu()
        let session = RemoteBrowserSession(tab: host.tab) { request in
            let result = try await host.send(request)
            if case let .pointer(pointer) = request.operation, pointer.kind == .down {
                #expect(request.selectMenus == true)
                return .init(controlID: result.controlID, selectMenu: menu)
            }
            return result
        }
        let watch = Task { await session.watch() }
        defer { session.stop()
            watch.cancel()
        }
        try await wait { session.controlID != nil }
        session.submit(.pointer(.init(.down, x: 10, y: 20, button: .left, buttons: 1)))
        session.submit(.pointer(.init(.up, x: 10, y: 20, button: .left)))
        try await wait { session.selectMenu != nil }
        session.submit(.pointer(.init(.move, x: 12, y: 20)))
        #expect(session.selectMenu == menu)
        session.chooseSelectOption(menuID: menu.id, index: 1)
        session.chooseSelectOption(menuID: UUID(), index: 2)
        #expect(session.selectMenu == menu)
        session.chooseSelectOption(menuID: menu.id, index: 2)
        session.chooseSelectOption(menuID: menu.id, index: 2)
        try await wait { host.operations.contains(.selectOption(menuID: menu.id, index: 2)) }
        #expect(host.operations.filter { $0 == .selectOption(menuID: menu.id, index: 2) }.count == 1)
        #expect(host.generations.last == 1)
        #expect(session.selectMenu == nil)
    }

    @Test(arguments: ["cancel", "control", "navigation", "stop"])
    func invalidationClosesMenu(reason: String) async throws {
        let host = RemoteBrowserSessionTests.Host(agent: false), menu = menu()
        let session = RemoteBrowserSession(tab: host.tab) { request in
            let response = try await host.send(request)
            if case .pointer = request.operation {
                return .init(controlID: response.controlID, selectMenu: menu)
            }
            return response
        }
        let watch = Task { await session.watch() }
        defer { session.stop()
            watch.cancel()
        }
        try await wait { session.controlID != nil }
        session.submit(.pointer(.init(.down, x: 10, y: 20, button: .left, buttons: 1)))
        try await wait { session.selectMenu != nil }
        switch reason {
        case "cancel": session.dismissSelectMenu()
        case "control": session.releaseControl()
        case "navigation": host.frameGeneration += 1
        default: session.stop()
        }
        try await wait { session.selectMenu == nil }
        session.chooseSelectOption(menuID: menu.id, index: 2)
        #expect(!host.operations.contains(.selectOption(menuID: menu.id, index: 2)))
        if reason == "cancel" {
            try await wait { host.operations.contains(.selectOption(menuID: menu.id, index: nil)) }
        }
    }

    @Test
    func lateMenuCannotReopenAfterControlRelease() async throws {
        let host = RemoteBrowserSessionTests.Host(agent: false), menu = menu()
        var pending: CheckedContinuation<RemoteBrowserResponse, any Error>?
        var replied = false
        let session = RemoteBrowserSession(tab: host.tab) { request in
            if case .pointer = request.operation {
                let response = try await withCheckedThrowingContinuation { pending = $0 }
                replied = true
                return response
            }
            return try await host.send(request)
        }
        let watch = Task { await session.watch() }
        defer { session.stop()
            watch.cancel()
        }
        try await wait { session.controlID != nil }
        let control = session.controlID
        session.submit(.pointer(.init(.down, x: 10, y: 20, button: .left, buttons: 1)))
        try await wait { pending != nil }
        session.releaseControl()
        pending?.resume(returning: .init(controlID: control, selectMenu: menu))
        try await wait { replied }
        #expect(session.selectMenu == nil)
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        try await RemoteBrowserSessionTests().wait(condition)
    }

    @Test(arguments: [false, true])
    func menuResponseDiscardsAlreadyQueuedPageInput(releaseQueued: Bool) async throws {
        let host = RemoteBrowserSessionTests.Host(agent: false), menu = menu()
        let down = RemoteBrowserOperation.pointer(.init(.down, x: 10, y: 20, button: .left, buttons: 1))
        let laterDown = RemoteBrowserOperation.pointer(.init(.down, x: 80, y: 90, button: .left, buttons: 1))
        let laterText = RemoteBrowserOperation.text("queued page input")
        var pending: CheckedContinuation<RemoteBrowserResponse, any Error>?
        let session = RemoteBrowserSession(tab: host.tab) { request in
            let response = try await host.send(request)
            if request.operation == down {
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            return response
        }
        let watch = Task { await session.watch() }
        defer {
            pending?.resume(throwing: CancellationError())
            session.stop()
            watch.cancel()
        }
        try await wait { session.controlID != nil }
        let control = session.controlID
        session.submit(down)
        try await wait { pending != nil }
        if releaseQueued {
            session.submit(.pointer(.init(.up, x: 10, y: 20, button: .left)))
        }
        session.submit(laterDown)
        session.submit(.pointer(.init(.up, x: 80, y: 90, button: .left)))
        session.submit(laterText)
        let reply = try #require(pending)
        pending = nil
        reply.resume(returning: .init(controlID: control, selectMenu: menu))
        try await wait { session.selectMenu != nil }
        if !releaseQueued {
            session.submit(.pointer(.init(.up, x: 10, y: 20, button: .left)))
        }
        session.chooseSelectOption(menuID: menu.id, index: 2)
        try await wait { host.operations.contains(.selectOption(menuID: menu.id, index: 2)) }
        #expect(!host.operations.contains(laterDown))
        #expect(!host.operations.contains(laterText))
        #expect(session.controlID == control && session.error == nil)
    }

    @Test(arguments: [false, true])
    func frameFailureClosesMenu(stale: Bool) async throws {
        let host = RemoteBrowserSessionTests.Host(agent: false), menu = menu()
        let failure = FrameFailure()
        let session = RemoteBrowserSession(tab: host.tab) { request in
            if request.operation == .frame, failure.enabled {
                throw ViewerRelayClientError.commandFailed(stale ? "Page changed. Read a new frame before interacting." : "Frame unavailable")
            }
            let response = try await host.send(request)
            if case .pointer = request.operation {
                return .init(controlID: response.controlID, selectMenu: menu)
            }
            return response
        }
        let watch = Task { await session.watch() }
        defer { session.stop()
            watch.cancel()
        }
        try await wait { session.controlID != nil }
        let control = session.controlID
        session.submit(.pointer(.init(.down, x: 10, y: 20, button: .left, buttons: 1)))
        try await wait { session.selectMenu != nil }
        failure.enabled = true
        try await wait { session.selectMenu == nil }
        if stale {
            try await Task.sleep(for: .milliseconds(20))
            #expect(!host.operations.contains(.selectOption(menuID: menu.id, index: nil)))
            #expect(session.frameError == nil)
            #expect(session.error == nil)
            #expect(session.controlID == control)
        } else {
            try await wait { host.operations.contains(.selectOption(menuID: menu.id, index: nil)) }
            #expect(session.frameError != nil)
        }
    }
}
