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

    @Test
    func copyAndPasteShortcutsRequireFocusedControlledCanvas() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        let view = BrowserCanvasNSView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        var copies = 0, pastes = 0
        view.onCopy = { copies += 1 }
        view.onPaste = { pastes += 1 }
        let copy = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8,
        ))
        let paste = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9,
        ))
        #expect(!view.performKeyEquivalent(with: copy))
        view.acceptsInput = true
        #expect(window.makeFirstResponder(view))
        #expect(view.performKeyEquivalent(with: copy))
        #expect(view.performKeyEquivalent(with: paste))
        #expect(copies == 1 && pastes == 1)
        view.acceptsInput = false
        #expect(!view.performKeyEquivalent(with: copy))
        #expect(copies == 1)
        window.close()
    }

    @Test
    func trackingAreaRegistersVisibleMouseMovementWithoutAccumulating() {
        let view = BrowserCanvasNSView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.updateTrackingAreas()
        view.updateTrackingAreas()
        #expect(view.trackingAreas.count == 1)
        #expect(view.trackingAreas.first?.options.contains([.mouseMoved, .activeInKeyWindow, .inVisibleRect]) == true)
        #expect((view.trackingAreas.first?.owner as? BrowserCanvasNSView) === view)
    }

    @Test
    func focusIsOnlyRestoredOnExplicitRequest() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        let canvas = BrowserCanvasNSView(frame: window.contentView!.bounds)
        let address = NSTextField(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView?.addSubview(canvas)
        window.contentView?.addSubview(address)
        #expect(window.makeFirstResponder(address))

        canvas.acceptsInput = true
        #expect(address.currentEditor() === window.firstResponder)
        canvas.acceptsInput = false
        canvas.acceptsInput = true
        #expect(address.currentEditor() === window.firstResponder)

        canvas.focusRequest = UUID()
        #expect(window.firstResponder === canvas)
        window.close()
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
