#if os(macOS)
    import AppKit
    import CtrlxCommon
    import Dependencies
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite("Mac terminal mouse routing", .serialized)
    struct MacTerminalMouseRoutingTests {
        @Test("Plain drag selects in both original and split panes", arguments: [0, 1])
        func plainSelection(paneIndex: Int) throws {
            let (window, panes) = makeTerminalWindow()
            defer { withExtendedLifetime(window) { } }
            let view = panes[paneIndex]
            var rawInput: [Data] = []
            view.onRawInput = { rawInput.append($0) }

            try drag(in: view)

            #expect(view.getSelectedTextTrimmed() == "pha br")
            #expect(rawInput.isEmpty)
            #expect(window.firstResponder === view.terminalView)
        }

        @Test("Shift drag selects locally in every tracking mode", arguments: [1000, 1002, 1003])
        func shiftSelection(mode: Int) throws {
            let (window, panes) = makeTerminalWindow()
            defer { withExtendedLifetime(window) { } }
            let view = panes[1]
            enableMouseMode(mode, in: view)
            var rawInput: [Data] = []
            view.onRawInput = { rawInput.append($0) }

            try drag(in: view, modifiers: .shift)

            #expect(view.getSelectedTextTrimmed() == "pha br")
            #expect(rawInput.isEmpty)
        }

        @Test("Streaming output preserves ordinary and Shift selection in both panes", arguments: [0, 1], [false, true])
        func selectionDuringOutput(paneIndex: Int, holdShift: Bool) throws {
            try assertSelectionDuringOutput(paneIndex: paneIndex, modifiers: holdShift ? .shift : [])
        }

        @Test("Shift selection survives output while the app tracks the mouse", arguments: [1000, 1002, 1003])
        func shiftSelectionDuringMouseTracking(mode: Int) throws {
            try assertSelectionDuringOutput(paneIndex: 1, modifiers: .shift, mouseMode: mode)
        }

        private func assertSelectionDuringOutput(
            paneIndex: Int,
            modifiers: NSEvent.ModifierFlags,
            mouseMode: Int? = nil
        ) throws {
            let clipboard = ClipboardClient.previewValue
            try withDependencies {
                $0[ClipboardClient.self] = clipboard
            } operation: {
                let (window, panes) = makeTerminalWindow()
                defer { withExtendedLifetime(window) { } }
                let view = panes[paneIndex]
                if let mouseMode { enableMouseMode(mouseMode, in: view) }
                var rawInput: [Data] = []
                view.onRawInput = { rawInput.append($0) }
                view.autoCopyOnSelect = true
                view.preserveUserScroll = true

                try gesture(
                    in: view,
                    steps: [(.leftMouseDown, 1), (.leftMouseDragged, 2), (.leftMouseDragged, 8), (.leftMouseUp, 8)],
                    modifiers: modifiers,
                    afterStep: { step in
                        guard step == 1 || step == 2 else { return }
                        // Both shared Mac Host/Viewer feed entry points must
                        // keep the drag alive, including split control sequences.
                        view.feed(byteArray: Array("\u{1b}[?25h".utf8)[...])
                        let output = "\u{1b}[4;1Hstatus update\r\n"
                        for byte in output.utf8 { view.feedPreservingScroll([byte][...]) }
                        #expect(view.getTerminal().getLine(row: 3)?.translateToString(trimRight: true) == "status update")
                    }
                )

                #expect(view.getSelectedTextTrimmed() == "pha br")
                #expect(clipboard.getString() == "pha br")
                #expect(rawInput.isEmpty)
                #expect(view.terminalView.allowMouseReporting)
            }
        }

        @Test("Ordinary app drag still reports press, motion and release", arguments: [1002, 1003])
        func applicationDrag(mode: Int) throws {
            let (window, panes) = makeTerminalWindow()
            defer { withExtendedLifetime(window) { } }
            let view = panes[1]
            enableMouseMode(mode, in: view)
            var rawInput: [Data] = []
            view.onRawInput = { rawInput.append($0) }

            try drag(in: view)

            #expect(view.getSelectedTextTrimmed() == nil)
            #expect(mouseButtons(rawInput) == [0, 32, 32, 0])
            #expect(rawInput.last.map { String(decoding: $0, as: UTF8.self).hasSuffix("m") } == true)
        }

        @Test("Copy preserves selection; paste and direct shortcuts end it", arguments: ["copy", "paste", "control", "shiftEnter"])
        func explicitInputSelectionLifecycle(action: String) throws {
            let clipboard = ClipboardClient.previewValue
            try withDependencies {
                $0[ClipboardClient.self] = clipboard
            } operation: {
                let (window, panes) = makeTerminalWindow()
                defer { withExtendedLifetime(window) { } }
                let view = panes[1]
                try drag(in: view)
                var input: [TmuxKey] = []
                view.onInput = { input.append(contentsOf: $0) }
                clipboard.setString("pasted")
                let character = action == "copy" ? "c" : action == "paste" ? "v" : action == "control" ? "t" : "\r"
                let modifiers: NSEvent.ModifierFlags = action == "control" ? .control : action == "shiftEnter" ? .shift : .command
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: character,
                    charactersIgnoringModifiers: character, isARepeat: false,
                    keyCode: action == "shiftEnter" ? 36 : 17
                ))

                if action == "copy" || action == "paste" {
                    #expect(view.performKeyEquivalent(with: event))
                } else {
                    #expect(view.interceptTerminalKeyDown(event))
                }

                if action == "copy" {
                    #expect(view.getSelectedTextTrimmed() == "pha br")
                    #expect(clipboard.getString() == "pha br")
                    #expect(input.isEmpty)
                } else {
                    #expect(view.getSelectedTextTrimmed() == nil)
                    #expect(input == (action == "paste" ? [.text("pasted")] : action == "control" ? [.ctrl("t")] : [.shiftEnter]))
                }
            }
        }

        @Test("An app can explicitly capture Shift mouse input")
        func applicationShiftCapture() throws {
            let (window, panes) = makeTerminalWindow()
            defer { withExtendedLifetime(window) { } }
            let view = panes[1]
            enableMouseMode(1002, in: view)
            view.feed(byteArray: Array("\u{1b}[>1s".utf8)[...])
            var rawInput: [Data] = []
            view.onRawInput = { rawInput.append($0) }

            try drag(in: view, modifiers: .shift)

            #expect(view.getSelectedTextTrimmed() == nil)
            #expect(mouseButtons(rawInput) == [4, 36, 36, 4])
        }

        @Test("Disabling reporting keeps the whole drag local", arguments: [false, true])
        func disabledReporting(holdShift: Bool) throws {
            let (window, panes) = makeTerminalWindow()
            defer { withExtendedLifetime(window) { } }
            let view = panes[1]
            enableMouseMode(1002, in: view)
            view.terminalView.allowMouseReporting = false
            var rawInput: [Data] = []
            view.onRawInput = { rawInput.append($0) }

            try drag(in: view, modifiers: holdShift ? .shift : [])

            #expect(view.getSelectedTextTrimmed() == "pha br")
            #expect(rawInput.isEmpty)
        }

        @Test("Local selection still auto-copies on mouse-up", arguments: [false, true])
        func localSelectionAutoCopy(reportingEnabled: Bool) throws {
            let clipboard = ClipboardClient.previewValue
            try withDependencies {
                $0[ClipboardClient.self] = clipboard
            } operation: {
                let (window, panes) = makeTerminalWindow()
                defer { withExtendedLifetime(window) { } }
                let view = panes[1]
                enableMouseMode(1002, in: view)
                view.terminalView.allowMouseReporting = reportingEnabled
                view.autoCopyOnSelect = true

                try drag(in: view, modifiers: reportingEnabled ? .shift : [])

                #expect(clipboard.getString() == "pha br")
            }
        }

        @Test("Shift multi-click retains word and row selection", arguments: [2, 3])
        func shiftMultiClick(clickCount: Int) throws {
            let (window, panes) = makeTerminalWindow()
            defer { withExtendedLifetime(window) { } }
            let view = panes[1]
            enableMouseMode(1002, in: view)
            var rawInput: [Data] = []
            view.onRawInput = { rawInput.append($0) }

            try gesture(
                in: view,
                steps: [(.leftMouseDown, 2), (.leftMouseUp, 2)],
                modifiers: .shift,
                clickCount: clickCount
            )

            #expect(view.getSelectedTextTrimmed() == (clickCount == 2 ? "alpha" : "alpha bravo charlie"))
            #expect(rawInput.isEmpty)
        }

        @Test("A Shift drag over a URL remains a selection")
        func shiftDragOverURL() throws {
            let (window, panes) = makeTerminalWindow()
            defer { withExtendedLifetime(window) { } }
            let view = panes[1]
            view.feed(byteArray: Array("\u{1b}[Hhttps://example.com".utf8)[...])
            enableMouseMode(1002, in: view)
            var rawInput: [Data] = []
            view.onRawInput = { rawInput.append($0) }

            try drag(in: view, modifiers: .shift)

            #expect(view.getSelectedTextTrimmed() == "tps://")
            #expect(rawInput.isEmpty)
        }

        @Test("Wheel reporting follows the same Shift and reporting policy", arguments: [false, true], [false, true])
        func wheelRouting(holdShift: Bool, captureShift: Bool) throws {
            let (window, panes) = makeTerminalWindow()
            defer { withExtendedLifetime(window) { } }
            let view = panes[1]
            enableMouseMode(1002, in: view)
            if captureShift {
                view.feed(byteArray: Array("\u{1b}[>1s".utf8)[...])
            }
            var rawInput: [Data] = []
            view.onRawInput = { rawInput.append($0) }
            let recipient = try mouseRecipient(in: view)
            let event = TerminalTestScrollEvent(
                window: window,
                location: view.terminalView.convert(NSPoint(x: 20, y: 500), to: nil),
                modifiers: holdShift ? .shift : []
            )

            recipient.scrollWheel(with: event)
            let expectedButtons = holdShift && !captureShift ? [] : [holdShift ? 68 : 64]
            #expect(mouseButtons(rawInput) == expectedButtons)

            rawInput.removeAll()
            view.terminalView.allowMouseReporting = false
            recipient.scrollWheel(with: event)
            #expect(rawInput.isEmpty)
        }

        @Test("Codex fullscreen trackpad distance is compensated, physical wheel is unchanged", arguments: [false, true])
        func codexWheelDistance(precise: Bool) throws {
            let (window, panes) = makeTerminalWindow()
            defer { withExtendedLifetime(window) { } }
            let view = panes[1]
            view.scrollingAgentID = "codex"
            view.feed(byteArray: Array("\u{1b}[?1049h".utf8)[...])
            enableMouseMode(1002, in: view)
            var raw = Data()
            var keys: [TmuxKey] = []
            view.onRawInput = { raw.append($0) }
            view.onInput = { keys += $0 }
            let recipient = try mouseRecipient(in: view)
            recipient.scrollWheel(with: TerminalTestScrollEvent(
                window: window, location: view.terminalView.convert(NSPoint(x: 20, y: 500), to: nil), modifiers: [],
                delta: precise ? view.cellSize.height * 12 : 4, precise: precise
            ))
            #expect(view.isMouseModeActive)
            #expect(String(decoding: raw, as: UTF8.self).components(separatedBy: "\u{1b}[<64;").count - 1 == 4)
            #expect(keys.isEmpty)
        }

        @Test("Inline Codex and other fullscreen TUIs keep their sensitivity", arguments: ["codex", "claude-code"])
        func uncompensatedModes(agent: String) throws {
            let (window, panes) = makeTerminalWindow()
            defer { withExtendedLifetime(window) { } }
            let view = panes[1]
            view.scrollingAgentID = agent
            if agent != "codex" { view.feed(byteArray: Array("\u{1b}[?1049h".utf8)[...]) }
            enableMouseMode(1002, in: view)
            var raw = Data()
            view.onRawInput = { raw.append($0) }
            try mouseRecipient(in: view).scrollWheel(with: TerminalTestScrollEvent(
                window: window, location: view.terminalView.convert(NSPoint(x: 20, y: 500), to: nil), modifiers: [], delta: view.cellSize.height * 3, precise: true
            ))
            #expect(String(decoding: raw, as: UTF8.self).components(separatedBy: "\u{1b}[<64;").count - 1 == 3)
        }

        @Test("Trackpad start forgets the last gesture but native momentum retains its remainder")
        func trackpadPhases() throws {
            let (window, panes) = makeTerminalWindow()
            defer { withExtendedLifetime(window) { } }
            let view = panes[1]
            view.scrollingAgentID = "codex"
            view.feed(byteArray: Array("\u{1b}[?1049h".utf8)[...])
            enableMouseMode(1002, in: view)
            var raw: [Data] = []
            view.onRawInput = { raw.append($0) }
            let recipient = try mouseRecipient(in: view)
            func wheel(rows: CGFloat, phase: NSEvent.Phase = [], momentum: NSEvent.Phase = []) {
                recipient.scrollWheel(with: TerminalTestScrollEvent(
                    window: window, location: view.terminalView.convert(NSPoint(x: 20, y: 500), to: nil), modifiers: [], delta: view.cellSize.height * rows,
                    precise: true, phase: phase, momentum: momentum
                ))
            }
            wheel(rows: 2, phase: .began)
            wheel(rows: 1, phase: .began)
            #expect(raw.isEmpty)
            wheel(rows: 0, phase: .ended)
            wheel(rows: 2, momentum: .began)
            #expect(raw.count == 1)
            wheel(rows: 2, momentum: .changed)
            wheel(rows: 0, momentum: .ended)
            wheel(rows: 1, phase: .began)
            #expect(raw.count == 1)
        }

        private func makeTerminalWindow() -> (NSWindow, [InteractiveTerminalView]) {
            _ = NSApplication.shared
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1600, height: 600),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 600))
            window.contentView = root
            let panes = [0, 1].map { index in
                let view = InteractiveTerminalView(
                    frame: NSRect(x: CGFloat(index) * 800, y: 0, width: 800, height: 600)
                )
                view.autoFocusEnabled = false
                view.showsFocusIndicator = true
                root.addSubview(view)
                view.feed(byteArray: Array("alpha bravo charlie\r\nsecond row\r\n".utf8)[...])
                return view
            }
            return (window, panes)
        }

        private func enableMouseMode(_ mode: Int, in view: InteractiveTerminalView) {
            view.feed(byteArray: Array("\u{1b}[?\(mode)h\u{1b}[?1006h".utf8)[...])
        }

        private func mouseRecipient(in view: InteractiveTerminalView) throws -> NSView {
            let root = try #require(view.window?.contentView)
            let point = view.terminalView.convert(
                NSPoint(x: view.cellSize.width, y: view.terminalView.frame.height - view.cellSize.height / 2),
                to: root
            )
            return try #require(root.hitTest(point))
        }

        private func drag(in view: InteractiveTerminalView, modifiers: NSEvent.ModifierFlags = []) throws {
            try gesture(
                in: view,
                steps: [(.leftMouseDown, 1), (.leftMouseDragged, 2), (.leftMouseDragged, 8), (.leftMouseUp, 8)],
                modifiers: modifiers
            )
        }

        private func gesture(
            in view: InteractiveTerminalView,
            steps: [(NSEvent.EventType, CGFloat)],
            modifiers: NSEvent.ModifierFlags,
            clickCount: Int = 1,
            afterStep: (Int) -> Void = { _ in }
        ) throws {
            let window = try #require(view.window)
            let recipient = try mouseRecipient(in: view)
            for (index, step) in steps.enumerated() {
                let point = view.terminalView.convert(
                    NSPoint(
                        x: step.1 * view.cellSize.width,
                        y: view.terminalView.frame.height - view.cellSize.height / 2
                    ),
                    to: nil
                )
                let event = try #require(NSEvent.mouseEvent(
                    with: step.0, location: point, modifierFlags: modifiers,
                    timestamp: Double(index), windowNumber: window.windowNumber,
                    context: nil, eventNumber: index, clickCount: clickCount, pressure: 1
                ))
                switch step.0 {
                case .leftMouseDown: recipient.mouseDown(with: event)
                case .leftMouseDragged: recipient.mouseDragged(with: event)
                default: recipient.mouseUp(with: event)
                }
                afterStep(index)
            }
        }

        private func mouseButtons(_ packets: [Data]) -> [Int] {
            packets.compactMap { packet in
                let text = String(decoding: packet, as: UTF8.self)
                guard
                    text.hasPrefix("\u{1b}[<"),
                    let button = text.dropFirst(3).split(separator: ";").first
                else { return nil }
                return Int(button)
            }
        }
    }

    /// CGEvent-based wheel events have no window, so AppKit cannot route them
    /// through the hit-tested decoration to the terminal's event overlay.
    final private class TerminalTestScrollEvent: NSEvent {
        private let targetWindow: NSWindow
        private let targetWindowNumber: Int
        private let point: NSPoint
        private let flags: NSEvent.ModifierFlags
        private let delta: CGFloat
        private let precise: Bool
        private let eventPhase: NSEvent.Phase
        private let momentum: NSEvent.Phase

        @MainActor
        init(
            window: NSWindow, location: NSPoint, modifiers: NSEvent.ModifierFlags,
            delta: CGFloat = 1, precise: Bool = false,
            phase: NSEvent.Phase = [], momentum: NSEvent.Phase = []
        ) {
            targetWindow = window
            targetWindowNumber = window.windowNumber
            point = location
            flags = modifiers
            self.delta = delta
            self.precise = precise
            eventPhase = phase
            self.momentum = momentum
            super.init()
        }

        required init?(coder: NSCoder) { nil }

        override var type: NSEvent.EventType { .scrollWheel }
        override var window: NSWindow? { targetWindow }
        override var windowNumber: Int { targetWindowNumber }
        override var locationInWindow: NSPoint { point }
        override var modifierFlags: NSEvent.ModifierFlags { flags }
        override var scrollingDeltaY: CGFloat { delta }
        override var scrollingDeltaX: CGFloat { 0 }
        override var hasPreciseScrollingDeltas: Bool { precise }
        override var phase: NSEvent.Phase { eventPhase }
        override var momentumPhase: NSEvent.Phase { momentum }
    }
#endif
