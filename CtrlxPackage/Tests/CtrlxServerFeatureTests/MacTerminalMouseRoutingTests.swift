#if os(macOS)
    import AppKit
    import ConcurrencyExtras
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import Testing
    @testable import CtrlxServerFeature

    /// The CLI test process has no foreground app; only window activation is supplied.
    @MainActor
    final private class TerminalMouseTestWindow: NSWindow {
        var keyForTesting = false
        override var isKeyWindow: Bool {
            keyForTesting
        }
    }

    @MainActor
    @Suite("Mac terminal mouse routing", .serialized)
    struct MacTerminalMouseRoutingTests {
        @Test("An enlarged terminal fits on a content click without changing focus")
        func resizedContentClick() async throws {
            let (window, panes) = makeTerminalWindow(key: true)
            defer { withExtendedLifetime(window) { } }
            let view = panes[0]
            let target = TerminalTabFit.Target(hostID: nil, sessionName: "dev", windowID: "@1")
            var fit = TerminalTabFit()
            var requests: [ResizeTmuxPane] = []
            func grid() -> ResizeTmuxPane {
                .init(width: Int(view.bounds.width / view.cellSize.width), height: Int(view.bounds.height / view.cellSize.height), userInitiated: true)
            }
            fit.recordFit(for: target, request: grid())
            view.onContentClick = {
                let request = grid()
                fit.requestAfterViewportChange(target, measuredRequest: request)
                if let request = fit.takeRequest(for: target, isAvailable: true, isPresentationReady: true, measuredRequest: request) {
                    requests.append(request)
                    fit.recordFit(for: target, request: request)
                }
            }
            view.focusTerminal()
            #expect(window.isKeyWindow)
            window.setContentSize(NSSize(width: 1_800, height: 800))
            view.frame.size = NSSize(width: 1_000, height: 800)
            view.layoutSubtreeIfNeeded()
            #expect(requests.isEmpty)
            for _ in 0..<2 {
                try gesture(in: view, steps: [(.leftMouseDown, 2), (.leftMouseUp, 2)], modifiers: [])
                try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
                #expect(requests == [grid()])
                #expect(window.firstResponder === view.terminalView)
            }
        }

        @Test("Selection, links and application mouse clicks never request content Fit", arguments: ["drag", "doubleClick", "tripleClick", "link", "mouse", "shift", "editor", "ime"])
        func contentClickExclusions(action: String) async throws {
            let (window, panes) = makeTerminalWindow(key: true)
            defer { withExtendedLifetime(window) { } }
            let view = panes[0]
            var clicks = 0
            var links = 0
            view.onContentClick = { clicks += 1 }
            view.onOpenURL = { _, _ in links += 1
                return true
            }
            if action == "link" {
                view.feed(byteArray: Array("\u{1b}[Hhttps://example.com".utf8)[...])
            }
            if action == "mouse" {
                enableMouseMode(1_002, in: view)
            }
            if action == "editor" {
                view.isEditorActive = true
            }
            if action == "ime" {
                view.terminalView.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            if action == "drag" {
                try drag(in: view)
            } else {
                try gesture(in: view, steps: [(.leftMouseDown, 2), (.leftMouseUp, 2)], modifiers: action == "shift" ? .shift : [])
                if action == "doubleClick" || action == "tripleClick" {
                    try gesture(in: view, steps: [(.leftMouseDown, 2), (.leftMouseUp, 2)], modifiers: [], clickCount: 2)
                    if action == "tripleClick" {
                        try gesture(in: view, steps: [(.leftMouseDown, 2), (.leftMouseUp, 2)], modifiers: [], clickCount: 3)
                    }
                }
            }
            try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
            #expect(clicks == 0)
            #expect(links == (action == "link" ? 1 : 0))
        }

        @Test("Delayed content clicks are cancelled by input or a stale presentation", arguments: ["key", "scroll", "focus", "hidden", "removed", "inactive", "stop"])
        func pendingContentClickCancellation(action: String) async throws {
            let (window, panes) = makeTerminalWindow(key: true)
            defer { withExtendedLifetime(window) { } }
            let view = panes[0]
            var clicks = 0
            view.onContentClick = { clicks += 1 }
            let recipient = try mouseRecipient(in: view)
            try gesture(in: view, steps: [(.leftMouseDown, 2), (.leftMouseUp, 2)], modifiers: [])
            switch action {
            case "key":
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "a",
                    charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
                ))
                _ = view.interceptTerminalKeyDown(event)
            case "scroll":
                recipient.scrollWheel(with: TerminalTestScrollEvent(
                    window: window, location: view.terminalView.convert(NSPoint(x: 20, y: 500), to: nil), modifiers: []
                ))
            case "focus": window.makeFirstResponder(panes[1].terminalView)
            case "hidden": view.isHidden = true
            case "inactive": (window as? TerminalMouseTestWindow)?.keyForTesting = false
            case "removed": view.removeFromSuperview()
            default: view.cancelVoiceInputPress()
            }
            try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
            #expect(clicks == 0)
        }

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

        @Test("Window copy dispatch targets only the focused Codex pane", arguments: [0, 1], [false, true])
        func codexCopy(paneIndex: Int, localSelection: Bool) throws {
            let clipboard = ClipboardClient.previewValue
            try withDependencies {
                $0[ClipboardClient.self] = clipboard
            } operation: {
                let (window, panes) = makeTerminalWindow(key: true)
                defer { withExtendedLifetime(window) { } }
                var rawInput = [[Data](), [Data]()]
                var keys: [TmuxKey] = []
                for (index, pane) in panes.enumerated() {
                    pane.scrollingAgentID = "codex"
                    pane.onRawInput = { rawInput[index].append($0) }
                    pane.onInput = { keys.append(contentsOf: $0) }
                }
                let view = panes[paneIndex]
                if localSelection {
                    try drag(in: view)
                } else {
                    // A TUI draws its own selection without a SwiftTerm selection.
                    view.feed(byteArray: Array("\u{1b}[H\u{1b}[7malpha\u{1b}[0m bravo".utf8)[...])
                    view.focusTerminal()
                    #expect(view.getSelectedTextTrimmed() == nil)
                }
                clipboard.setString("previous clipboard")

                #expect(try window.performKeyEquivalent(with: copyEvent(in: window)))

                #expect(rawInput[1 - paneIndex].isEmpty)
                #expect(keys.isEmpty)
                if localSelection {
                    #expect(rawInput[paneIndex].isEmpty)
                    #expect(clipboard.getString() == "pha br")
                    #expect(view.getSelectedTextTrimmed() == "pha br")
                } else {
                    #expect(rawInput[paneIndex] == [Data("\u{1b}[99;9u".utf8)])
                    #expect(clipboard.getString() == "previous clipboard")
                }
            }
        }

        @Test("Application copy leaves other agents, editors and modified shortcuts alone", arguments: ["shell", "otherAgent", "editor", "textField", "control", "option", "shift", "disconnected"])
        func codexCopyExclusions(action: String) throws {
            let (window, panes) = makeTerminalWindow(key: true)
            defer { withExtendedLifetime(window) { } }
            let view = panes[1]
            view.scrollingAgentID = "codex"
            view.focusTerminal()
            var rawInput: [Data] = []
            var keys: [TmuxKey] = []
            var modifiers: NSEvent.ModifierFlags = .command
            view.onRawInput = { rawInput.append($0) }
            view.onInput = { keys.append(contentsOf: $0) }
            switch action {
            case "shell": view.scrollingAgentID = nil
            case "otherAgent": view.scrollingAgentID = "claude-code"
            case "editor": view.isEditorActive = true
            case "textField":
                let editor = NSTextView(frame: .zero)
                window.contentView?.addSubview(editor)
                window.makeFirstResponder(editor)
            case "control": modifiers.insert(.control)
            case "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default: view.onRawInput = nil
            }

            #expect(try !view.performKeyEquivalent(with: copyEvent(in: window, modifiers: modifiers)))
            #expect(rawInput.isEmpty)
            #expect(keys.isEmpty)
        }

        private func copyEvent(in window: NSWindow, modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "c",
                charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
            ))
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

        @Test(
            "Web-link clicks retain their one-click destination through deferred activation",
            arguments: [NSEvent.ModifierFlags(), .command, .option, [.command, .option]], [false, true]
        )
        func webLinkClickDestination(modifiers: NSEvent.ModifierFlags, mouseReporting: Bool) async throws {
            for osc8 in [false, true] {
                let systemURLs = LockIsolated<[URL]>([])
                try await withDependencies {
                    $0[URLOpener.self] = URLOpener(openInDefaultBrowser: { url in systemURLs.withValue { $0.append(url) } })
                } operation: {
                    let (window, panes) = makeTerminalWindow()
                    defer { withExtendedLifetime(window) { } }
                    let view = panes[1]
                    let url = try #require(URL(string: "https://example.com/path"))
                    let text = osc8 ? "\u{1b}]8;;\(url.absoluteString)\u{7}website\u{1b}]8;;\u{7}" : url.absoluteString
                    view.feed(byteArray: Array("\u{1b}[H\u{1b}[2K\(text)".utf8)[...])
                    if mouseReporting {
                        enableMouseMode(1_002, in: view)
                    }
                    var urls: [URL] = []
                    var overrides: [BrowserLinkBehavior?] = []
                    var rawInput: [Data] = []
                    view.onRawInput = { rawInput.append($0) }
                    view.onOpenURL = { url, behavior in
                        urls.append(url)
                        overrides.append(behavior)
                        return behavior != .alwaysInDefaultBrowser
                    }

                    try gesture(in: view, steps: [(.leftMouseDown, 2), (.leftMouseUp, 2)], modifiers: modifiers)
                    #expect(urls.isEmpty)
                    try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))

                    let expected: BrowserLinkBehavior? = modifiers.contains(.command) ? .alwaysInApp
                        : modifiers.contains(.option) ? .alwaysInDefaultBrowser : nil
                    #expect(urls == [url])
                    #expect(overrides == [expected])
                    #expect(systemURLs.value == (expected == .alwaysInDefaultBrowser ? [url] : []))
                    #expect(rawInput.isEmpty)
                }
            }
        }

        @Test("An explicit Host click never falls back to this device's browser")
        func unhandledHostLinkDoesNotOpenLocally() async throws {
            let systemURLs = LockIsolated<[URL]>([])
            try await withDependencies {
                $0[URLOpener.self] = URLOpener(openInDefaultBrowser: { url in systemURLs.withValue { $0.append(url) } })
            } operation: {
                let (window, panes) = makeTerminalWindow()
                defer { withExtendedLifetime(window) { } }
                let view = panes[0]
                view.feed(byteArray: Array("\u{1b}[H\u{1b}[2Khttps://example.com".utf8)[...])
                var calls = 0
                view.onOpenURL = { _, behavior in
                    calls += 1
                    #expect(behavior == .alwaysInApp)
                    return false
                }

                try gesture(in: view, steps: [(.leftMouseDown, 2), (.leftMouseUp, 2)], modifiers: .command)
                try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))

                #expect(calls == 1)
                #expect(systemURLs.value.isEmpty)
            }
        }

        @Test(
            "Modified drag and multi-click selection never open web links",
            arguments: [NSEvent.ModifierFlags.command, .option], ["drag", "doubleClick", "tripleClick"]
        )
        func modifiedLinkSelection(modifiers: NSEvent.ModifierFlags, action: String) async throws {
            let (window, panes) = makeTerminalWindow()
            defer { withExtendedLifetime(window) { } }
            let view = panes[1]
            view.feed(byteArray: Array("\u{1b}[H\u{1b}[2Khttps://example.com".utf8)[...])
            var opened = 0
            view.onOpenURL = { _, _ in
                opened += 1
                return true
            }

            if action == "drag" {
                try drag(in: view, modifiers: modifiers)
            } else {
                try gesture(in: view, steps: [(.leftMouseDown, 2), (.leftMouseUp, 2)], modifiers: modifiers)
                try gesture(in: view, steps: [(.leftMouseDown, 2), (.leftMouseUp, 2)], modifiers: modifiers, clickCount: 2)
                if action == "tripleClick" {
                    try gesture(in: view, steps: [(.leftMouseDown, 2), (.leftMouseUp, 2)], modifiers: modifiers, clickCount: 3)
                }
            }
            try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))

            #expect(opened == 0)
            #expect(view.getSelectedTextTrimmed() != nil)
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

        private func makeTerminalWindow(key: Bool = false) -> (NSWindow, [InteractiveTerminalView]) {
            _ = NSApplication.shared
            let window = TerminalMouseTestWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_600, height: 600),
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
            window.keyForTesting = key
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
