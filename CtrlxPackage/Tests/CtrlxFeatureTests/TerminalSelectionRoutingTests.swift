#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import Testing
    import UIKit
    import XCTest
    @testable import CtrlxFeature
    @testable import SwiftTerm

    @MainActor
    @Suite("Terminal input-row selection routing", .serialized)
    struct TerminalSelectionRoutingTests {
        @Test("Plain terminal content toggles the keyboard with custom prompts and drafts")
        func plainTerminalKeyboard() async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            view.scrollingAgentID = nil
            feed(view, "output\r\n(base) Office ➜  project echo draft")
            var requests: [Bool] = []
            var keys: [TmuxKey] = []
            var raw: [Data] = []
            view.onInput = { keys += $0 }
            view.onRawInput = { raw.append($0) }
            view.onKeyboardRequest = { [weak view] value in
                requests.append(value)
                view?.updateInput(isEnabled: true, keyboardRequested: value)
            }
            for row in [0, 1, 3, 1] {
                view.handleContentTap(at: CGPoint(x: view.cellDimension.width * 4.5, y: view.cellDimension.height * (CGFloat(row) + 0.5)))
                await view.inputFocusUpdates.pendingTask?.value
            }
            #expect(requests == [true, false, true, false])
            #expect(keys.isEmpty && raw.isEmpty)
            feed(view, "\u{1b}[?1049hmenu\u{1b}[?1003h\u{1b}[?1006h")
            view.handleContentTap(at: CGPoint(x: view.cellDimension.width * 4.5, y: view.cellDimension.height * 3.5))
            #expect(requests == [true, false, true, false])
            #expect(!raw.isEmpty)
        }

        @Test("Empty input taps toggle keyboard intent without emitting input", arguments: [false, true])
        func emptyInputKeyboard(mouseMode: Bool) async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            feed(view, "body\r\n\u{1b}[48;5;236m› Ask Codex to do anything\u{1b}[K\u{1b}[2;3H")
            if mouseMode {
                feed(view, "\u{1b}[?1003h\u{1b}[?1006h")
            }
            let proxy = try inputProxy(in: window)
            var requested = false
            var raw: [Data] = []
            var keys: [TmuxKey] = []
            view.onRawInput = { raw.append($0) }
            view.onInput = { keys += $0 }
            view.onKeyboardRequest = { [weak view] value in
                requested = value
                view?.updateInput(isEnabled: true, keyboardRequested: requested)
            }
            for expected in [true, false] {
                view.handleContentTap(at: CGPoint(x: view.cellDimension.width * 10.5, y: view.cellDimension.height * 1.5))
                await view.inputFocusUpdates.pendingTask?.value
                #expect(requested == expected)
                #expect(proxy.isFirstResponder)
                #expect(keys.isEmpty && raw.isEmpty)
            }
        }

        @Test("Draft taps reopen the keyboard while retaining cursor navigation", arguments: [false, true])
        func draftKeyboardRouting(mouseMode: Bool) async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            feed(view, "body\r\n\u{1b}[48;5;236m› hello world\u{1b}[K")
            if mouseMode {
                feed(view, "\u{1b}[?1003h\u{1b}[?1006h")
            }
            let proxy = try inputProxy(in: window)
            var requests: [Bool] = []
            var keys: [TmuxKey] = []
            var raw: [Data] = []
            view.onKeyboardRequest = { [weak view] value in
                requests.append(value)
                view?.updateInput(isEnabled: true, keyboardRequested: value)
            }
            view.onInput = { keys += $0 }
            view.onRawInput = { raw.append($0) }
            // Tapping output must not reveal the keyboard, including mouse mode.
            view.handleContentTap(at: CGPoint(x: view.cellDimension.width * 1.5, y: view.cellDimension.height * 0.5))
            #expect(requests.isEmpty)
            raw = []
            let point = CGPoint(x: view.cellDimension.width * 4.5, y: view.cellDimension.height * 1.5)
            view.handleContentTap(at: point)
            await view.inputFocusUpdates.pendingTask?.value
            #expect(requests == [true])
            #expect(mouseMode ? !raw.isEmpty : !keys.isEmpty)
            #expect(proxy.isFirstResponder && proxy.inputView == nil)
            // Repeated cursor taps keep an open keyboard open.
            view.handleContentTap(at: point)
            await view.inputFocusUpdates.pendingTask?.value
            #expect(requests == [true])
            view.updateInput(isEnabled: true, keyboardRequested: false)
            await view.inputFocusUpdates.pendingTask?.value
            view.handleContentTap(at: point)
            await view.inputFocusUpdates.pendingTask?.value
            #expect(requests == [true, true])
            #expect(proxy.isFirstResponder && proxy.inputView == nil)
            keys = []
            proxy.insertText("X")
            #expect(keys == [.text("X")])
            if !mouseMode {
                keys = []
                tap(view, count: 2, column: 4, row: 1)
                #expect(requests == [true, true] && keys.isEmpty && !view.selectionActive)
                #expect(proxy.isFirstResponder)
            }
        }

        @Test("Empty-input taps respect IME, inactive and selection guards")
        func emptyInputGuards() async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            feed(view, "body\r\n> ")
            let proxy = try inputProxy(in: window)
            var toggles = 0
            view.onKeyboardRequest = { _ in toggles += 1 }
            let point = CGPoint(x: view.cellDimension.width * 5.5, y: view.cellDimension.height * 1.5)
            proxy.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
            view.handleContentTap(at: point)
            #expect(toggles == 0)
            proxy.unmarkText()
            view.updateInput(isEnabled: false, keyboardRequested: false)
            await view.inputFocusUpdates.pendingTask?.value
            view.handleContentTap(at: point)
            #expect(toggles == 0)
            view.updateInput(isEnabled: true, keyboardRequested: false)
            await view.inputFocusUpdates.pendingTask?.value
            tap(view, count: 2, column: 1, row: 0)
            view.handleContentTap(at: point)
            #expect(toggles == 0)
        }

        @Test("Questions padding and multiline answers open and keep the keyboard open", arguments: [false, true])
        func questionAnswerKeyboard(mouseMode: Bool) async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            let proxy = try inputProxy(in: window)
            var requests: [Bool] = []
            var keys: [TmuxKey] = []
            view.onInput = { keys += $0 }
            view.onRawInput = { _ in }
            view.onKeyboardRequest = { [weak view] value in
                requests.append(value)
                view?.updateInput(isEnabled: true, keyboardRequested: value)
            }
            for draft in ["", "Type your answer (optional)", "first line"] {
                paintQuestionAnswer(view, draft: draft, multiline: draft == "first line")
                if mouseMode {
                    feed(view, "\u{1b}[?1003h\u{1b}[?1006h")
                }
                view.updateInput(isEnabled: true, keyboardRequested: false)
                await view.inputFocusUpdates.pendingTask?.value
                requests = []
                for row in [4, 5, 6, 7] {
                    view.handleContentTap(at: CGPoint(
                        x: 20.5 * view.cellDimension.width, y: (CGFloat(row) + 0.5) * view.cellDimension.height
                    ))
                    await view.inputFocusUpdates.pendingTask?.value
                }
                #expect(requests == [true])
                #expect(proxy.isFirstResponder && proxy.inputView == nil)
                keys = []
                proxy.insertText("中")
                #expect(keys == [.text("中")])
            }
        }

        @Test("Highlighted options preserve notes keyboard handling", arguments: [false, true], [false, true])
        func questionNotesKeyboard(inverse: Bool, mouseMode: Bool) async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            let proxy = try inputProxy(in: window)
            var requests: [Bool] = []
            var keys: [TmuxKey] = []
            view.onInput = { keys += $0 }
            view.onRawInput = { _ in }
            view.onKeyboardRequest = { [weak view] value in
                requests.append(value)
                view?.updateInput(isEnabled: true, keyboardRequested: value)
            }
            for multiline in [false, true] {
                let style = inverse ? "\u{1b}[0;7m" : "\u{1b}[48;2;190;210;255m"
                paintQuestionAnswer(view, draft: multiline ? "first line" : "Add notes", multiline: multiline, optionStyle: style)
                if mouseMode {
                    feed(view, "\u{1b}[?1003h\u{1b}[?1006h")
                }
                view.updateInput(isEnabled: true, keyboardRequested: false)
                await view.inputFocusUpdates.pendingTask?.value
                requests = []
                for row in [2, 5, 6, 11, 12] {
                    view.handleContentTap(at: CGPoint(x: 20.5 * view.cellDimension.width, y: (CGFloat(row) + 0.5) * view.cellDimension.height))
                }
                #expect(requests.isEmpty)
                for row in 7...10 {
                    view.handleContentTap(at: CGPoint(x: 20.5 * view.cellDimension.width, y: (CGFloat(row) + 0.5) * view.cellDimension.height))
                    await view.inputFocusUpdates.pendingTask?.value
                }
                #expect(requests == [true])
                #expect(proxy.isFirstResponder && proxy.inputView == nil)
                keys = []
                proxy.insertText("中")
                #expect(keys == [.text("中")])
            }
        }

        @Test("Promptless async Questions open and keep the keyboard open", arguments: [false, true])
        func asyncQuestionKeyboard(mouseMode: Bool) async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            let proxy = try inputProxy(in: window)
            var requests: [Bool] = []
            view.onRawInput = { _ in }
            view.onKeyboardRequest = { [weak view] value in
                requests.append(value)
                view?.updateInput(isEnabled: true, keyboardRequested: value)
            }
            for draft in ["", "Type your answer", "first line"] {
                paintAsyncQuestionAnswer(view, draft: draft, multiline: draft == "first line")
                if mouseMode {
                    feed(view, "\u{1b}[?1003h\u{1b}[?1006h")
                }
                view.updateInput(isEnabled: true, keyboardRequested: false)
                await view.inputFocusUpdates.pendingTask?.value
                requests = []
                for row in [2, 7, 8] {
                    view.handleContentTap(at: CGPoint(x: 20.5 * view.cellDimension.width, y: (CGFloat(row) + 0.5) * view.cellDimension.height))
                }
                #expect(requests.isEmpty)
                for row in 3...6 {
                    view.handleContentTap(at: CGPoint(x: 20.5 * view.cellDimension.width, y: (CGFloat(row) + 0.5) * view.cellDimension.height))
                    await view.inputFocusUpdates.pendingTask?.value
                }
                #expect(requests == [true])
                #expect(proxy.isFirstResponder && proxy.inputView == nil)
            }
        }

        @Test("Questions keyboard requests retain cursor, redraw, IME and input guards", arguments: [false, true])
        func questionKeyboardGuards(asyncLayout: Bool) async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            if asyncLayout {
                paintAsyncQuestionAnswer(view)
            } else {
                paintQuestionAnswer(view)
            }
            feed(view, "\u{1b}[?1003h\u{1b}[?1006h")
            let proxy = try inputProxy(in: window)
            var requests: [Bool] = []
            view.onRawInput = { _ in }
            view.onKeyboardRequest = { requests.append($0) }
            let point = CGPoint(x: 20.5 * view.cellDimension.width, y: (asyncLayout ? 6.5 : 7.5) * view.cellDimension.height)
            feed(view, "\u{1b}[?25l")
            view.handleContentTap(at: point)
            feed(view, "\u{1b}[?25h\u{1b}[?2026h")
            view.handleContentTap(at: point)
            feed(view, "\u{1b}[?2026l")
            proxy.setMarkedText("zhong", selectedRange: .init(location: 5, length: 0))
            view.handleContentTap(at: point)
            proxy.unmarkText()
            view.updateInput(isEnabled: false, keyboardRequested: false)
            await view.inputFocusUpdates.pendingTask?.value
            view.handleContentTap(at: point)
            view.updateInput(isEnabled: true, keyboardRequested: false)
            await view.inputFocusUpdates.pendingTask?.value
            view.scrollingAgentID = "claude-code"
            view.handleContentTap(at: point)
            view.scrollingAgentID = "codex"
            // Header, question and footer remain outside the answer.
            for row in asyncLayout ? [2, 7, 8, 9] : [2, 3, 8, 9] {
                view.handleContentTap(at: CGPoint(x: point.x, y: (CGFloat(row) + 0.5) * view.cellDimension.height))
            }
            tap(view, count: 2, column: 2, row: 0)
            #expect(view.selectionActive)
            view.handleContentTap(at: point)
            #expect(requests.isEmpty)
        }

        @Test("Links inside Questions keep their local action instead of opening the keyboard", arguments: [false, true])
        func questionAnswerLink(asyncLayout: Bool) async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            if asyncLayout {
                paintAsyncQuestionAnswer(view, draft: "https://example.com")
            } else {
                paintQuestionAnswer(view, draft: "https://example.com")
            }
            let url = try #require(URL(string: "https://example.com"))
            var opened: [URL] = []
            var requests: [Bool] = []
            view.onOpenURL = { opened.append($0) }
            view.onKeyboardRequest = { requests.append($0) }
            view.handleContentTap(at: CGPoint(x: 8.5 * view.cellDimension.width, y: (asyncLayout ? 4.5 : 5.5) * view.cellDimension.height))
            #expect(opened == [url])
            #expect(requests.isEmpty)
        }

        @Test("The whole current input row opts out, including blank cells and wide glyphs")
        func inputRow() async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            view.feed(text: "正文\r\n> 中🙂 input")
            view.scroll(toPosition: 1)
            let terminal = view.getTerminal()
            let row = terminal.buffer.y + terminal.buffer.yDisp
            let proxy = try #require(window.rootViewController?.view.subviews
                .compactMap { $0 as? UIScrollView }.first?.subviews
                .compactMap { $0 as? TerminalInputProxyView }.first)
            #expect(proxy.isFirstResponder)

            var sentKeys = 0
            var sentBytes = 0
            view.onInput = { sentKeys += $0.count }
            view.onRawInput = { sentBytes += $0.count }
            for column in [0, 2, 3, terminal.buffer.x, terminal.cols - 1] {
                #expect(!view.shouldBeginSelection(at: Position(col: column, row: row)))
            }
            #expect(view.shouldBeginSelection(at: Position(col: 0, row: row - 1)))
            #expect(view.shouldBeginSelection(at: Position(col: 0, row: row + 1)))
            #expect(sentKeys == 0)
            #expect(sentBytes == 0)
            #expect(!view.selectionActive)
        }

        @Test("History, inactive input and mouse-mode TUIs retain selection")
        func selectionFallbacks() async {
            let (window, view) = await makeView()
            defer { close(window, view) }
            for line in 0..<100 {
                view.feed(text: "history \(line)\r\n")
            }
            view.scroll(toPosition: 1)
            let terminal = view.getTerminal()
            let input = Position(col: 0, row: terminal.buffer.y + terminal.buffer.yDisp)
            #expect(!view.shouldBeginSelection(at: input))

            view.updateInput(isEnabled: false, keyboardRequested: false)
            #expect(view.shouldBeginSelection(at: input))
            view.updateInput(isEnabled: true, keyboardRequested: false)

            view.feed(text: "\u{1b}[?1000h")
            #expect(view.shouldBeginSelection(at: input))
            view.feed(text: "\u{1b}[?1000l")
            #expect(!view.shouldBeginSelection(at: input))

            view.scroll(toPosition: 0)
            #expect(view.shouldBeginSelection(at: Position(col: 0, row: terminal.buffer.y + terminal.buffer.yDisp)))
        }

        @Test("Input multi-taps open the menu, and explicit Select/Copy act on the terminal", arguments: [2, 3])
        func inputMenuActions(tapCount: Int) async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            let proxy = try inputProxy(in: window)
            proxy.insertText("shadow editor only")
            let shadowText = proxy.text
            let shadowSelection = proxy.selectedRange
            view.feed(text: "body\r\n> hello world")
            view.scroll(toPosition: 1)
            let row = view.getTerminal().buffer.y + view.getTerminal().buffer.yDisp
            var sentKeys = 0
            var sentBytes = 0
            view.onInput = { sentKeys += $0.count }
            view.onRawInput = { sentBytes += $0.count }

            tap(view, count: tapCount, column: 3, row: row)
            await Task.yield()

            let menu = UIMenuController.shared
            #expect(view.lastLongSelect == Position(col: 3, row: row))
            #expect(!view.selectionActive)
            #expect(view.panSelectionGesture == nil)
            #expect(proxy.isFirstResponder)
            #expect(proxy.target(forAction: #selector(view.copy(_:)), withSender: menu) == nil)
            #expect(proxy.target(forAction: #selector(view.select(_:)), withSender: menu) as? UIResponder === view)
            #expect(proxy.target(forAction: #selector(view.selectAll(_:)), withSender: menu) as? UIResponder === view)
            #expect(proxy.target(forAction: #selector(view.paste(_:)), withSender: menu) as? UIResponder === view)

            try sendMenuAction(#selector(view.select(_:)), from: proxy)
            await Task.yield()
            #expect(view.selection.getSelectedText() == "hello")
            #expect(view.panSelectionGesture?.isEnabled == true)
            #expect(proxy.target(forAction: #selector(view.copy(_:)), withSender: menu) as? UIResponder === view)
            #expect(proxy.target(forAction: #selector(view.select(_:)), withSender: menu) == nil)

            try sendMenuAction(#selector(view.copy(_:)), from: proxy)
            #expect(!view.selectionActive)
            #expect(view.panSelectionGesture?.isEnabled == false)
            #expect(proxy.text == shadowText)
            #expect(proxy.selectedRange == shadowSelection)
            #expect(sentKeys == 0)
            #expect(sentBytes == 0)
        }

        @Test("System paste stays one semantic operation regardless of mirrored bracketed mode", arguments: [false, true])
        func systemPaste(bracketed: Bool) async throws {
            let text = "first\r\n中🙂\nlast\n"
            let (window, view) = await withDependencies {
                $0[ClipboardClient.self].getString = { text }
            } operation: {
                await makeView()
            }
            defer { close(window, view) }
            let proxy = try inputProxy(in: window)
            view.feed(text: bracketed ? "\u{1b}[?2004h> input" : "\u{1b}[?2004l> input")
            var pastes: [String] = []
            var keys: [TmuxKey] = []
            var raw: [Data] = []
            view.onPasteText = { pastes.append($0) }
            view.onInput = { keys += $0 }
            view.onRawInput = { raw.append($0) }
            try sendMenuAction(#selector(view.paste(_:)), from: proxy)
            #expect(pastes == [text])
            #expect(keys.isEmpty)
            #expect(raw.isEmpty)
            #expect(proxy.isFirstResponder)
            #expect(!view.selectionActive)
            view.updateInput(isEnabled: false, keyboardRequested: false)
            view.paste(nil)
            #expect(pastes.count == 1)
            view.invalidateInput()
            view.paste(nil)
            #expect(pastes.count == 1)
        }

        @Test("System image paste takes priority over text and keeps one captured payload", arguments: [false, true])
        func systemImagePaste(readable: Bool) async throws {
            let image = readable ? ClipboardImage(data: Data([1, 2, 3]), format: .png) : nil
            try await withDependencies {
                $0[ClipboardClient.self].hasImage = { true }
                $0[ClipboardClient.self].getImage = { image }
                $0[ClipboardClient.self].getString = { "image text fallback" }
            } operation: {
                let (window, view) = await makeView()
                defer { close(window, view) }
                let proxy = try inputProxy(in: window)
                var images: [ClipboardImage?] = []
                var text: [String] = []
                var keys: [TmuxKey] = []
                var raw: [Data] = []
                view.onPasteImage = { images.append($0) }
                view.onPasteText = { text.append($0) }
                view.onInput = { keys += $0 }
                view.onRawInput = { raw.append($0) }

                try sendMenuAction(#selector(view.paste(_:)), from: proxy)
                #expect(images == [image])
                try sendMenuAction(#selector(view.paste(_:)), from: proxy)
                #expect(images == [image, image])
                #expect(text.isEmpty)
                #expect(keys.isEmpty)
                #expect(raw.isEmpty)
                #expect(!view.selectionActive)

                view.updateInput(isEnabled: false, keyboardRequested: false)
                view.paste(nil)
                #expect(images.count == 2)
                view.invalidateInput()
                #expect(view.onPasteImage == nil)
                view.paste(nil)
                #expect(images.count == 2)
            }
        }

        @Test("An image-enabled terminal still pastes plain text once")
        func plainTextWithImageHandler() async throws {
            let text = "first\r\n中🙂\nlast\n"
            try await withDependencies {
                $0[ClipboardClient.self].hasImage = { false }
                $0[ClipboardClient.self].getString = { text }
            } operation: {
                let (window, view) = await makeView()
                defer { close(window, view) }
                let proxy = try inputProxy(in: window)
                var pastes: [String] = []
                var imageCount = 0
                view.onPasteText = { pastes.append($0) }
                view.onPasteImage = { _ in imageCount += 1 }
                try sendMenuAction(#selector(view.paste(_:)), from: proxy)
                #expect(pastes == [text])
                #expect(imageCount == 0)
            }
        }

        @Test("Body double-tap Copy ignores the native shadow editor")
        func bodyCopyAction() async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            let proxy = try inputProxy(in: window)
            proxy.insertText("not the visible text")
            view.feed(text: "hello world\r\n> prompt")

            tap(view, count: 2, column: 1, row: 0)

            #expect(view.selection.getSelectedText() == "hello")
            #expect(proxy.target(forAction: #selector(view.copy(_:)), withSender: UIMenuController.shared) as? UIResponder === view)
            try sendMenuAction(#selector(view.copy(_:)), from: proxy)
            #expect(!view.selectionActive)
        }

        @Test("Select All from an input menu selects the terminal, not the shadow document")
        func selectAllAction() async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            let proxy = try inputProxy(in: window)
            proxy.insertText("shadow editor only")
            let shadowSelection = proxy.selectedRange
            view.feed(text: "body text\r\n> input")
            tap(view, count: 2, column: 25, row: 1)

            try sendMenuAction(#selector(view.selectAll(_:)), from: proxy)

            #expect(view.selectionActive)
            #expect(view.selection.getSelectedText().contains("body text"))
            #expect(view.selection.getSelectedText().contains("> input"))
            #expect(view.panSelectionGesture?.isEnabled == true)
            #expect(proxy.selectedRange == shadowSelection)
            #expect(proxy.isFirstResponder)
        }

        @Test("Typing and IME commits still use the shadow editor after opening an input menu")
        func typingAndIMEAfterMenu() async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            let proxy = try inputProxy(in: window)
            view.feed(text: "> input")
            tap(view, count: 2, column: 25, row: 0)
            var inserted: [String] = []
            var deleted = 0
            proxy.onInsertText = { inserted.append($0) }
            proxy.onDeleteBackward = { deleted += 1 }

            proxy.insertText("hello")
            proxy.textViewDidChange(proxy)
            #expect(inserted == ["hello"])

            proxy.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
            proxy.textViewDidChange(proxy)
            #expect(inserted == ["hello"])
            proxy.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0))
            proxy.unmarkText()
            proxy.textViewDidChange(proxy)

            #expect(inserted == ["hello", "中"])
            #expect(deleted == 0)
            #expect(proxy.isFirstResponder)
            #expect(!view.selectionActive)
        }

        private func inputProxy(in window: UIWindow) throws -> TerminalInputProxyView {
            try #require(window.rootViewController?.view.subviews
                .compactMap { $0 as? UIScrollView }.first?.subviews
                .compactMap { $0 as? TerminalInputProxyView }.first)
        }

        @Test("Native paired quotes forward caret-only changes and typing outside")
        func pairedQuoteCaret() async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            let proxy = try inputProxy(in: window)
            var sent: [TmuxKey] = []
            view.onInput = { sent += $0 }
            proxy.insertText("“”")
            proxy.selectedRange = NSRange(location: 2, length: 0) // anchor + opening quote
            proxy.textViewDidChangeSelection(proxy)
            proxy.insertText("你好")
            proxy.selectedRange = NSRange(location: 5, length: 0)
            proxy.textViewDidChangeSelection(proxy)
            proxy.insertText("之后")
            #expect(sent == [.text("“”"), .left, .text("你好"), .right, .text("之后")])
        }

        @Test("Toolbar navigation and accessory input forget stale native context")
        func externalInputContext() async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            let proxy = try inputProxy(in: window)
            proxy.insertText("“”")
            proxy.selectedRange = NSRange(location: 2, length: 0)
            proxy.textViewDidChangeSelection(proxy)
            var sent: [TmuxKey] = []
            view.onInput = { sent += $0 }
            view.prepareForExternalInput()
            view.onInput?([.right])
            proxy.insertText("outside")
            #expect(sent == [.right, .text("outside")])

            sent = []
            view.send(source: view, data: Array("\u{1b}[D".utf8)[...])
            proxy.insertText("X")
            #expect(sent == [.left, .text("X")])
            #expect(proxy.text == "\u{200B}X")
        }

        @Test("The native caret cannot edit the anchor, but boundary backspace reaches the terminal")
        func contextStartBoundary() async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            let proxy = try inputProxy(in: window)
            proxy.insertText("suffix")
            proxy.selectedRange = NSRange(location: 0, length: 0)
            proxy.textViewDidChangeSelection(proxy)
            #expect(proxy.selectedRange == NSRange(location: 1, length: 0))
            var sent: [TmuxKey] = []
            view.onInput = { sent += $0 }
            proxy.deleteBackward()
            proxy.insertText("X")
            #expect(sent == [.backspace, .text("X")])
            #expect(proxy.text == "\u{200B}Xsuffix")
        }

        @Test("IME candidates inside paired quotes stay local until committed")
        func pairedQuoteComposition() async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            let proxy = try inputProxy(in: window)
            proxy.insertText("“”")
            proxy.selectedRange = NSRange(location: 2, length: 0)
            proxy.textViewDidChangeSelection(proxy)
            var sent: [TmuxKey] = []
            view.onInput = { sent += $0 }
            proxy.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
            proxy.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0))
            #expect(sent.isEmpty)
            proxy.unmarkText()
            proxy.textViewDidChange(proxy)
            proxy.textViewDidChangeSelection(proxy)
            #expect(sent == [.text("你")])
            #expect(proxy.text == "\u{200B}“你”")
            #expect(proxy.selectedRange.location == 3)
        }

        @Test("External navigation commits a pending candidate before resetting context")
        func compositionBeforeExternalInput() async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            let proxy = try inputProxy(in: window)
            var sent: [TmuxKey] = []
            view.onInput = { sent += $0 }
            proxy.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0))
            view.prepareForExternalInput()
            view.onInput?([.right])
            proxy.insertText("好")
            #expect(sent == [.text("你"), .right, .text("好")])
            #expect(proxy.text == "\u{200B}好")
        }

        @Test("A cross-row tap starts a fresh keyboard context without changing selection routing")
        func contextAfterCrossRowTap() async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            let proxy = try inputProxy(in: window)
            proxy.insertText("“”")
            proxy.selectedRange = NSRange(location: 2, length: 0)
            proxy.textViewDidChangeSelection(proxy)
            paintMultilineDraft(view)
            var sent: [TmuxKey] = []
            view.onInput = { sent += $0 }
            view.moveInputCursor(to: (8, 1))
            proxy.insertText("new")
            #expect(sent == [.up, .text("new")])
            #expect(proxy.text == "\u{200B}new")
            #expect(!view.selectionActive)
        }

        @Test("Cross-row taps wait for visible cursor feedback and correct the actual column once")
        func multilineCursorFeedback() async {
            let (window, view) = await makeView()
            defer { close(window, view) }
            paintMultilineDraft(view)
            var sent: [[TmuxKey]] = []
            view.onInput = { [weak view] in
                // The shared send queue cancels other input, not this move.
                view?.cancelCursorNavigation()
                sent.append($0)
            }
            view.moveInputCursor(to: (8, 1))
            #expect(sent == [[.up]])
            feed(view, "\u{1b}[?2026h\u{1b}[?25l\u{1b}[2;3H")
            #expect(sent == [[.up]])
            feed(view, "\u{1b}[?25h\u{1b}[?2026l")
            #expect(sent == [[.up], Array(repeating: .right, count: 6)])
            feed(view, "\u{1b}[2;9H")
            #expect(sent.count == 2)
        }

        @Test("The last valid tap is retained during remote cursor feedback")
        func latestTapWins() async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            paintMultilineDraft(view)
            var sent: [[TmuxKey]] = []
            view.onInput = { sent.append($0) }
            view.moveInputCursor(to: (8, 1))
            let contentTap = try #require(view.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }
                .last(where: { $0.numberOfTapsRequired == 1 }))
            #expect(view.gestureRecognizerShouldBegin(contentTap))
            view.moveInputCursor(to: (3, 3))
            view.moveInputCursor(to: (2, 3))
            view.moveInputCursor(to: (3, 0)) // body must not replace the valid tap
            #expect(sent == [[.up]])
            feed(view, "\u{1b}[?2026h\u{1b}[?25l\u{1b}[2;3H")
            #expect(sent == [[.up]])
            feed(view, "\u{1b}[?25h\u{1b}[?2026l")
            #expect(sent == [[.up], [.down, .down]])
            feed(view, "\u{1b}[4;3H")
            #expect(sent.count == 2)
        }

        @Test("A first tap during redraw survives a hidden cursor visiting body output")
        func tapDuringRedraw() async {
            let (window, view) = await makeView()
            defer { close(window, view) }
            paintMultilineDraft(view)
            var sent: [[TmuxKey]] = []
            view.onInput = { sent.append($0) }
            feed(view, "\u{1b}[?2026h\u{1b}[?25l\u{1b}[1;1H")
            view.moveInputCursor(to: (8, 1))
            #expect(sent.isEmpty)
            feed(view, "\u{1b}[3;5H\u{1b}[?25h\u{1b}[?2026l")
            #expect(sent == [[.up]])
            feed(view, "\u{1b}[2;3H")
            #expect(sent == [[.up], Array(repeating: .right, count: 6)])
        }

        @Test("Same-row repeat taps cannot calculate from a stale remote column")
        func sameRowSerialFeedback() async {
            let (window, view) = await makeView()
            defer { close(window, view) }
            paintMultilineDraft(view)
            var sent: [[TmuxKey]] = []
            view.onInput = { sent.append($0) }
            view.moveInputCursor(to: (7, 2))
            view.moveInputCursor(to: (2, 2))
            #expect(sent == [Array(repeating: .right, count: 3)])
            feed(view, "\u{1b}[3;8H")
            #expect(sent == [Array(repeating: .right, count: 3), Array(repeating: .left, count: 5)])
            feed(view, "\u{1b}[3;3H")
            #expect(sent.count == 2)
        }

        @Test("Ordinary typing or parent controls cancel a pending column correction", arguments: [false, true])
        func typingCancelsMove(parentControl: Bool) async {
            let (window, view) = await makeView()
            defer { close(window, view) }
            paintMultilineDraft(view)
            var sent: [[TmuxKey]] = []
            view.onInput = { sent.append($0) }
            view.moveInputCursor(to: (8, 1))
            view.moveInputCursor(to: (2, 3))
            if parentControl {
                view.cancelCursorNavigation()
            } else {
                view.send(source: view, data: Array("x".utf8)[...])
            }
            let count = sent.count
            feed(view, "\u{1b}[2;3H")
            #expect(sent.count == count)
        }

        @Test("Copy routing stays independent on every line of a multiline draft")
        func multilineSelectionUnchanged() async {
            let (window, view) = await makeView()
            defer { close(window, view) }
            paintMultilineDraft(view)
            var sent: [[TmuxKey]] = []
            view.onInput = { sent.append($0) }
            #expect(!view.shouldBeginSelection(at: .init(col: 3, row: 2)))
            #expect(view.shouldBeginSelection(at: .init(col: 3, row: 1)))
            view.moveInputCursor(to: (8, 1))
            view.moveInputCursor(to: (2, 3))
            tap(view, count: 2, column: 3, row: 1)
            #expect(view.selectionActive)
            feed(view, "\u{1b}[2;3H")
            view.moveInputCursor(to: (4, 2))
            #expect(sent == [[.up]])
        }

        @Test("Abandoned IME composition cancels queued navigation before any output arrives")
        func compositionCancelsWithoutFeed() async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            paintMultilineDraft(view)
            var sent: [[TmuxKey]] = []
            view.onInput = { sent.append($0) }
            view.moveInputCursor(to: (8, 1))
            view.moveInputCursor(to: (2, 3))
            let proxy = try inputProxy(in: window)
            proxy.setMarkedText("zhong", selectedRange: .init(location: 5, length: 0))
            proxy.setMarkedText("", selectedRange: .init(location: 0, length: 0))
            proxy.unmarkText()
            let count = sent.count
            feed(view, "\u{1b}[2;3H")
            #expect(sent.count == count)
        }

        @Test("IME composition invalidates pending dictation before committing terminal text")
        func compositionInvalidatesVoice() async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            let proxy = try inputProxy(in: window)
            var invalidations = 0
            var keys: [TmuxKey] = []
            view.onCompositionStart = { invalidations += 1 }
            view.onInput = { keys += $0 }
            proxy.setMarkedText("zhong", selectedRange: .init(location: 5, length: 0))
            #expect(invalidations == 1)
            #expect(keys.isEmpty)
        }

        @Test("Cross-row taps never send keys for body, padding, mouse mode, IME or inactive input")
        func multilineInputGates() async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            paintMultilineDraft(view)
            var sent: [[TmuxKey]] = []
            view.onInput = { sent.append($0) }
            view.moveInputCursor(to: (3, 0))
            view.moveInputCursor(to: (3, 4))
            feed(view, "\u{1b}[?1000h")
            view.moveInputCursor(to: (3, 1))
            feed(view, "\u{1b}[?1000l")
            let proxy = try inputProxy(in: window)
            proxy.setMarkedText("zhong", selectedRange: .init(location: 5, length: 0))
            view.moveInputCursor(to: (3, 1))
            #expect(sent.isEmpty)
            proxy.unmarkText()
            sent = []
            view.updateInput(isEnabled: false, keyboardRequested: false)
            view.moveInputCursor(to: (3, 1))
            #expect(sent.isEmpty)
        }

        @Test("Mouse-mode single tap sends one raw press/release batch, not arrow keys", arguments: [false, true])
        func mouseSingleTap(scrollback: Bool) async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            if scrollback {
                for _ in 0..<100 {
                    feed(view, "history\r\n")
                }
            }
            paintMultilineDraft(view)
            feed(view, "\u{1b}[?1003h\u{1b}[?1006h")
            let proxy = try inputProxy(in: window)
            proxy.insertText("old keyboard context")
            var keys: [[TmuxKey]] = []
            var raw: [Data] = []
            view.onInput = { keys.append($0) }
            view.onRawInput = { raw.append($0) }
            let row = view.getTerminal().buffer.yDisp + 1
            view.handleContentTap(at: CGPoint(
                x: 5.5 * view.cellDimension.width,
                y: (CGFloat(row) + 0.5) * view.cellDimension.height
            ))
            #expect(raw == [Data("\u{1b}[<0;6;2M\u{1b}[<0;6;2m".utf8)])
            #expect(keys.isEmpty)
            // Starting a fresh keyboard context must not delete the old draft.
            proxy.insertText("new")
            #expect(keys == [[.text("new")]])
        }

        @Test("Mouse-mode double/triple taps still select locally without clicking", arguments: [2, 3])
        func mouseMultiTap(count: Int) async {
            let (window, view) = await makeView()
            defer { close(window, view) }
            feed(view, "hello world\r\n> draft\u{1b}[?1003h\u{1b}[?1006h")
            var raw: [Data] = []
            var keys: [TmuxKey] = []
            view.onRawInput = { raw.append($0) }
            view.onInput = { keys += $0 }
            tap(view, count: count, column: 1, row: 0)
            #expect(view.selectionActive)
            // A tap that leaves selection must not click through to the TUI.
            view.handleContentTap(at: CGPoint(x: 30, y: 20))
            #expect(raw.isEmpty)
            #expect(keys.isEmpty)
        }

        @Test("Mouse clicks cannot bypass IME, focus, inactive-pane or history gates")
        func mouseClickGates() async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            for _ in 0..<100 {
                feed(view, "history\r\n")
            }
            paintMultilineDraft(view)
            feed(view, "\u{1b}[?1003h\u{1b}[?1006h")
            let proxy = try inputProxy(in: window)
            var raw: [Data] = []
            view.onRawInput = { raw.append($0) }
            let point = CGPoint(x: 30, y: CGFloat(view.getTerminal().buffer.yDisp + 1) * view.cellDimension.height)
            proxy.setMarkedText("zhong", selectedRange: .init(location: 5, length: 0))
            view.handleContentTap(at: point)
            proxy.unmarkText()
            view.scroll(toPosition: 0)
            view.handleContentTap(at: point)
            view.scroll(toPosition: 1)
            _ = proxy.resignFirstResponder()
            view.handleContentTap(at: point)
            view.updateInput(isEnabled: false, keyboardRequested: false)
            view.handleContentTap(at: point)
            #expect(raw.isEmpty)
        }

        @Test("Mouse-off single taps keep the existing arrow navigation path")
        func plainSingleTap() async {
            let (window, view) = await makeView()
            defer { close(window, view) }
            paintMultilineDraft(view)
            var keys: [[TmuxKey]] = []
            var raw: [Data] = []
            view.onInput = { keys.append($0) }
            view.onRawInput = { raw.append($0) }
            view.handleContentTap(at: CGPoint(
                x: 7.5 * view.cellDimension.width,
                y: 2.5 * view.cellDimension.height
            ))
            #expect(keys == [[.right, .right, .right]])
            #expect(raw.isEmpty)
        }

        @Test("URL taps and delegate opens ask SwiftUI for a destination without presenting native alerts")
        func linkPresentationRouting() async throws {
            let (window, view) = await makeView()
            defer { close(window, view) }
            let url = try #require(URL(string: "https://example.com/page"))
            var requested: [URL] = []
            var sentKeys: [TmuxKey] = []
            var sentBytes: [Data] = []
            view.onOpenURL = { requested.append($0) }
            view.onInput = { sentKeys += $0 }
            view.onRawInput = { sentBytes.append($0) }
            feed(view, url.absoluteString + "\r\n> input")
            view.handleContentTap(at: CGPoint(x: 2.5 * view.cellDimension.width, y: 0.5 * view.cellDimension.height))
            view.requestOpenLink(source: view, link: url.absoluteString, params: [:])
            view.requestOpenLink(source: view, link: "file:///tmp/report.txt", params: [:])
            #expect(requested == [url, url])
            #expect(sentKeys.isEmpty && sentBytes.isEmpty)
            #expect(window.rootViewController?.presentedViewController == nil)
        }

        private func feed(_ view: InteractiveTerminalView, _ text: String) {
            view.feedTerminalData(Array(text.utf8)[...])
        }

        private func paintAsyncQuestionAnswer(_ view: InteractiveTerminalView, draft: String = "Type your answer", multiline: Bool = false) {
            feed(view, "\u{1b}[0m\u{1b}[2J\u{1b}[1;1H• Queued follow-up inputs")
            let rows = [
                "", "  Share details.", "", "  " + draft, multiline ? "  second line" : "", "",
                "  enter submit   ⌃] skip   ⇧→ main prompt", "",
            ]
            for (index, text) in rows.enumerated() {
                feed(view, "\u{1b}[\(index + 2);1H\u{1b}[0;48;2;57;57;57m\u{1b}[2K\(text)")
            }
            feed(view, "\u{1b}[0m\u{1b}[\(multiline ? 6 : 5);3H\u{1b}[?25h")
            view.scroll(toPosition: 1)
        }

        private func paintQuestionAnswer(_ view: InteractiveTerminalView, draft: String = "Type your answer (optional)", multiline: Bool = false, optionStyle: String? = nil) {
            feed(view, "\u{1b}[0m\u{1b}[2J\u{1b}[1;1Houtput")
            var rows = [
                "",
                "  Question 1/1 (1 unanswered)",
                "  Share details.",
                "",
                "  › " + draft,
                multiline ? "    second line" : "",
                "",
                "  enter to submit answer",
                "  esc to interrupt",
                "",
            ]
            if optionStyle != nil {
                rows.insert(contentsOf: ["", "  › 1. Selected option", "    2. Another option"], at: 3)
            }
            for (index, text) in rows.enumerated() {
                var content = text
                if index == 4, let optionStyle {
                    content = "  " + optionStyle + String(text.dropFirst(2)).padding(toLength: view.getTerminal().cols - 4, withPad: " ", startingAt: 0)
                        + "\u{1b}[0;48;5;236m  "
                }
                feed(view, "\u{1b}[\(index + 2);1H\u{1b}[48;5;236m\u{1b}[2K\(content)")
            }
            let cursorRow = (multiline ? 7 : 6) + (optionStyle == nil ? 0 : 3)
            feed(view, "\u{1b}[0m\u{1b}[\(cursorRow);5H\u{1b}[?25h")
            view.scroll(toPosition: 1)
        }

        private func paintMultilineDraft(_ view: InteractiveTerminalView) {
            feed(view, "\u{1b}[0m\u{1b}[2J\u{1b}[1;1Hbody")
            for (row, text) in [(2, "› first line"), (3, "  second"), (4, "  中🙂 end"), (5, "")] {
                feed(view, "\u{1b}[\(row);1H\u{1b}[48;5;236m\u{1b}[2K\(text)")
            }
            feed(view, "\u{1b}[0m\u{1b}[6;1Hfooter\u{1b}[3;5H\u{1b}[?25h")
            view.scroll(toPosition: 1)
        }

        private func sendMenuAction(_ action: Selector, from proxy: TerminalInputProxyView) throws {
            let menu = UIMenuController.shared
            let target = try #require(proxy.target(forAction: action, withSender: menu) as? UIResponder)
            // Unhosted package tests have no UIApplication event dispatcher.
            // Resolve the same responder target and invoke its selector. The
            // hosted XCTest below verifies UIKit dispatch and clipboard data.
            #expect(target.responds(to: action))
            target.perform(action, with: menu)
        }

        func close(_ window: UIWindow, _ view: InteractiveTerminalView) {
            UIMenuController.shared.hideMenu()
            view.invalidateInput()
            view.updateUiClosed()
            window.isHidden = true
        }

        fileprivate func tap(_ view: InteractiveTerminalView, count: Int, column: Int, row: Int) {
            let gesture = CompletedTerminalMenuTap()
            gesture.numberOfTapsRequired = count
            gesture.point = CGPoint(
                x: (CGFloat(column) + 0.5) * view.cellDimension.width,
                y: (CGFloat(row) + 0.5) * view.cellDimension.height
            )
            view.addGestureRecognizer(gesture)
            if count == 2 {
                view.doubleTap(gesture)
            } else {
                view.tripleTap(gesture)
            }
        }

        func makeView() async -> (UIWindow, InteractiveTerminalView) {
            let frame = CGRect(x: 0, y: 0, width: 400, height: 700)
            let window: UIWindow
            let application = UIApplication.perform(#selector(getter: UIApplication.shared))?.takeUnretainedValue() as? UIApplication
            if let scene = application?.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                window = UIWindow(windowScene: scene)
                window.frame = frame
            } else {
                window = UIWindow(frame: frame)
            }
            let controller = UIViewController()
            window.rootViewController = controller
            let viewport = UIScrollView(frame: window.bounds)
            controller.view.addSubview(viewport)
            let terminal = InteractiveTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), font: nil)
            terminal.scrollingAgentID = "codex"
            viewport.addSubview(terminal)
            terminal.attachInputProxy(to: viewport)
            window.makeKeyAndVisible()
            terminal.updateInput(isEnabled: true, keyboardRequested: false)
            controller.view.layoutIfNeeded()
            await terminal.inputFocusUpdates.pendingTask?.value
            return (window, terminal)
        }
    }

    /// Run with an application test host and CTRLX_MENU_UI_TESTS=1 to verify
    /// the real UIKit popover and nil-target responder dispatch. Ordinary
    /// package tests exercise the same handlers without an application host.
    @MainActor
    final class TerminalMenuHostTests: XCTestCase {
        func testInputMenuPresentationAndActions() async throws {
            try XCTSkipUnless(ProcessInfo.processInfo.environment["CTRLX_MENU_UI_TESTS"] == "1")
            let fixture = TerminalSelectionRoutingTests()
            for tapCount in [2, 3] {
                let (window, view) = await withDependencies {
                    $0[ClipboardClient.self] = .liveValue
                } operation: {
                    await fixture.makeView()
                }
                defer { fixture.close(window, view) }
                view.feed(text: "body\r\n> hello world")
                let proxy = try XCTUnwrap(window.rootViewController?.view.subviews
                    .compactMap { $0 as? UIScrollView }.first?.subviews
                    .compactMap { $0 as? TerminalInputProxyView }.first)
                proxy.insertText("not the visible text")
                let shadowText = proxy.text
                let shadowSelection = proxy.selectedRange
                var sentKeys: [TmuxKey] = []
                var pastedText: [String] = []
                view.onInput = { sentKeys += $0 }
                view.onPasteText = { pastedText.append($0) }
                fixture.tap(view, count: tapCount, column: 3, row: 1)
                try await Task.sleep(for: .milliseconds(300))

                let menu = UIMenuController.shared
                XCTAssertEqual(window.windowScene?.activationState, .foregroundActive)
                XCTAssertTrue(menu.isMenuVisible)
                XCTAssertFalse(view.selectionActive)
                XCTAssertNil(view.panSelectionGesture)
                XCTAssertTrue(proxy.isFirstResponder)
                XCTAssertNil(proxy.target(forAction: #selector(view.copy(_:)), withSender: menu))
                XCTAssertTrue(UIApplication.shared.sendAction(#selector(view.select(_:)), to: nil, from: menu, for: nil))
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(view.selection.getSelectedText(), "hello")
                XCTAssertTrue(UIApplication.shared.sendAction(#selector(view.copy(_:)), to: nil, from: menu, for: nil))
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertEqual(UIPasteboard.general.string, "hello")
                XCTAssertFalse(view.selectionActive)
                XCTAssertEqual(proxy.text, shadowText)
                XCTAssertEqual(proxy.selectedRange, shadowSelection)
                XCTAssertTrue(sentKeys.isEmpty)

                UIPasteboard.general.string = "paste once"
                try await Task.sleep(for: .milliseconds(50))
                fixture.tap(view, count: tapCount, column: 25, row: 1)
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertTrue(menu.isMenuVisible)
                XCTAssertTrue(UIApplication.shared.sendAction(#selector(view.paste(_:)), to: nil, from: menu, for: nil))
                XCTAssertEqual(pastedText, ["paste once"])
                XCTAssertTrue(sentKeys.isEmpty)
                XCTAssertTrue(proxy.isFirstResponder)
            }
        }
    }

    @MainActor
    final private class CompletedTerminalMenuTap: UITapGestureRecognizer {
        var point = CGPoint.zero

        override var state: UIGestureRecognizer.State {
            get { .ended }
            set { }
        }

        override func location(in view: UIView?) -> CGPoint {
            point
        }
    }
#endif
