#if os(macOS)
import AppKit
import CtrlxNetworking
import Testing
@testable import CtrlxCommon

@Suite("Remote browser Mac pointer") @MainActor
struct RemoteBrowserCanvasTests {
    private func event(_ type: NSEvent.EventType, at point: CGPoint, view: NSView) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [.shift],
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 1, clickCount: type == .mouseMoved ? 0 : 1, pressure: 0))
    }

    @Test func trackingAreaRegistersVisibleMouseMovementWithoutAccumulating() {
        let view = BrowserCanvasNSView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.updateTrackingAreas()
        view.updateTrackingAreas()
        #expect(view.trackingAreas.count == 1)
        #expect(view.trackingAreas.first?.options.contains([.mouseMoved, .activeInKeyWindow, .inVisibleRect]) == true)
        #expect((view.trackingAreas.first?.owner as? BrowserCanvasNSView) === view)
    }

    @Test func hoverUsesPageCoordinatesAndRespectsControlAndLetterboxing() throws {
        let view = BrowserCanvasNSView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.pageSize = CGSize(width: 1000, height: 500)
        var operations: [RemoteBrowserOperation] = []
        view.send = { operations.append($0) }
        let hover = try event(.mouseMoved, at: CGPoint(x: 200, y: 400), view: view)
        view.mouseMoved(with: hover)
        #expect(operations.isEmpty)
        view.acceptsInput = true
        view.mouseMoved(with: hover)
        #expect(operations == [.pointer(.init(.move, x: 500, y: 250, modifiers: 8, clickCount: 0))])
        view.mouseMoved(with: try event(.mouseMoved, at: CGPoint(x: 200, y: 100), view: view))
        #expect(operations.count == 1, "Hover in the letterbox must not move the Host pointer")
        view.acceptsInput = false
        view.mouseMoved(with: hover)
        #expect(operations.count == 1)
    }

    @Test func dragAndReleaseOutsidePageStillReachHost() throws {
        let view = BrowserCanvasNSView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.pageSize = CGSize(width: 1000, height: 500)
        view.acceptsInput = true
        var operations: [RemoteBrowserOperation] = []
        view.send = { operations.append($0) }
        let outside = CGPoint(x: 450, y: 100)
        view.mouseDragged(with: try event(.leftMouseDragged, at: outside, view: view))
        view.mouseUp(with: try event(.leftMouseUp, at: outside, view: view))
        #expect(operations == [
            .pointer(.init(.move, x: 999, y: 0, button: .left, buttons: 1, modifiers: 8, clickCount: 0)),
            .pointer(.init(.up, x: 999, y: 0, button: .left, modifiers: 8, clickCount: 1)),
        ])
    }
}
#endif
