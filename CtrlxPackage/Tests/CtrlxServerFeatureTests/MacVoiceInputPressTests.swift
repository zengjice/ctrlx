import AppKit
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite("Mac hold to talk", .serialized)
struct MacVoiceInputPressTests {
    @Test("Short clicks replay; movement hands the original down to selection")
    func ordinaryGestures() async throws {
        let press = MacVoiceInputPress()
        let down = try event(.leftMouseDown)
        var starts = 0
        var finishes: [Bool] = []
        press.mouseDown(down, begin: { starts += 1
            return true
        }, finish: { finishes.append($0) })
        #expect(press.mouseUp() === down)
        press.mouseDown(down, begin: { starts += 1
            return true
        }, finish: { finishes.append($0) })
        #expect(try press.mouseDragged(event(.leftMouseDragged, x: 2)) == nil)
        #expect(try press.mouseDragged(event(.leftMouseDragged, x: 10)) === down)
        try await Task.sleep(for: .milliseconds(450))
        #expect(starts == 0 && finishes.isEmpty && !press.isActive)
    }

    @Test("A stationary hold consumes the click and finishes once", arguments: [false, true])
    func heldGesture(cancel: Bool) async throws {
        let press = MacVoiceInputPress()
        var starts = 0
        var finishes: [Bool] = []
        try press.mouseDown(event(.leftMouseDown), begin: { starts += 1
            return true
        }, finish: { finishes.append($0) })
        try await Task.sleep(for: .milliseconds(450))
        #expect(starts == 1 && finishes.isEmpty)
        #expect(try press.mouseDragged(event(.leftMouseDragged, x: 50)) == nil)
        if cancel {
            press.cancel()
        }
        #expect(press.mouseUp() == nil)
        press.cancel()
        #expect(finishes == [cancel])
    }

    @Test("Unavailable targets preserve the original click")
    func rejectedHold() async throws {
        let press = MacVoiceInputPress()
        let down = try event(.leftMouseDown)
        var finished = false
        press.mouseDown(down, begin: { false }, finish: { _ in finished = true })
        try await Task.sleep(for: .milliseconds(450))
        #expect(press.mouseUp() === down)
        #expect(!finished)
    }

    @Test("Native placeholders remain text; only blank prompt cells and shaded padding qualify")
    func inputRegion() {
        let view = terminal()
        let input = view.getTerminal()
        // Includes Codex's own placeholder, blank rows above/below, and output
        // below the box. Leave the cursor at the empty prompt's insertion point.
        feed("output\r\n\u{1b}[48;5;236m\u{1b}[K\r\n› Ask Codex to do anything\u{1b}[K\r\n\u{1b}[K\r\n\u{1b}[0mfooter\u{1b}[3;3H", to: view)
        #expect(input.buffer.x == 2 && input.buffer.y == 2)
        #expect(MacTerminalVoiceInputRegion.contains(column: 35, row: 2, in: input))
        #expect(MacTerminalVoiceInputRegion.contains(column: 35, row: 1, in: input))
        #expect(MacTerminalVoiceInputRegion.contains(column: 35, row: 3, in: input))
        #expect(!MacTerminalVoiceInputRegion.contains(column: 35, row: 0, in: input))
        #expect(!MacTerminalVoiceInputRegion.contains(column: 35, row: 4, in: input))
        #expect(!MacTerminalVoiceInputRegion.contains(column: 7, row: 2, in: input))
        #expect(!MacTerminalVoiceInputRegion.contains(column: 0, row: 2, in: input))
        feed("\u{1b}[?25l", to: view)
        #expect(!MacTerminalVoiceInputRegion.contains(column: 35, row: 2, in: input))
    }

    @Test("An ordinary shell prompt qualifies; output, draft text and wide characters do not")
    func shellAndText() {
        let view = terminal()
        let input = view.getTerminal()
        feed("user@host % ", to: view)
        #expect(MacTerminalVoiceInputRegion.contains(column: 25, row: 0, in: input))
        #expect(!MacTerminalVoiceInputRegion.contains(column: 25, row: 1, in: input))
        feed("echo test", to: view)
        #expect(!MacTerminalVoiceInputRegion.contains(column: 25, row: 0, in: input))
        feed("\r\n› 中\u{1b}[2;3H", to: view)
        #expect(!MacTerminalVoiceInputRegion.contains(column: 3, row: 1, in: input))
        feed("\r\nrandom output", to: view)
        #expect(!MacTerminalVoiceInputRegion.contains(column: 25, row: 2, in: input))
    }

    @Test("Candidate clicks and drags preserve event order; cancellation consumes the rest", arguments: ["tap", "drag", "cancel"])
    func terminalMouseReplay(action: String) throws {
        let drag = action != "tap"
        let view = terminal()
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { withExtendedLifetime(window) { } }
        feed("› \u{1b}[?1002h\u{1b}[?1006h", to: view)
        let router = TerminalQuickActionRouter()
        let endpoint = TerminalQuickActionEndpoint(hostID: nil, paneID: "%1", isVisible: { true }, enqueue: { _ in })
        endpoint.isReady = true
        router.focus(endpoint)
        view.voiceInputRouter = router
        view.voiceInputEndpoint = endpoint
        var raw: [Data] = []
        view.onRawInput = { raw.append($0) }
        let point = NSPoint(x: view.cellSize.width * 20, y: view.terminalView.bounds.height - view.cellSize.height / 2)
        let recipient = try #require(view.hitTest(point))
        func mouse(_ type: NSEvent.EventType, offset: CGFloat = 0) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: view.terminalView.convert(NSPoint(x: point.x + offset, y: point.y), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        try recipient.mouseDown(with: mouse(.leftMouseDown))
        #expect(raw.isEmpty)
        if action == "cancel" {
            view.cancelVoiceInputPress()
        }
        if drag {
            try recipient.mouseDragged(with: mouse(.leftMouseDragged, offset: 20))
        }
        try recipient.mouseUp(with: mouse(.leftMouseUp, offset: drag ? 20 : 0))
        if action == "cancel" {
            #expect(raw.isEmpty)
            #expect(router.voiceInputHold == nil)
            return
        }
        #expect(raw.count == (drag ? 3 : 2))
        #expect(raw.first.map { String(decoding: $0, as: UTF8.self).hasPrefix("\u{1b}[<0;") } == true)
        #expect(raw.last.map { String(decoding: $0, as: UTF8.self).hasSuffix("m") } == true)
        #expect(router.voiceInputHold == nil)
    }

    private func event(_ type: NSEvent.EventType, x: CGFloat = 0) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: 0), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func terminal() -> InteractiveTerminalView {
        _ = NSApplication.shared
        let view = InteractiveTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.autoFocusEnabled = false
        return view
    }

    private func feed(_ text: String, to view: InteractiveTerminalView) {
        view.feed(byteArray: Array(text.utf8)[...])
    }
}
