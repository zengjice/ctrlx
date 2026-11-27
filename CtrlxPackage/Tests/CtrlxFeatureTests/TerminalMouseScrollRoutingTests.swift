#if os(iOS)
    import Foundation
    import Testing
    import UIKit
    @testable import CtrlxFeature
    @testable import SwiftTerm

    @MainActor
    @Suite("iOS fullscreen mouse scrolling", .serialized)
    struct TerminalMouseScrollRoutingTests {
        @Test("A retained selection follows the active buffer's scrolling route, independent of Agent name", arguments: ["codex", "traex"], [false, true])
        func selectedDragUsesTheActiveBuffer(agent: String, alternate: Bool) async throws {
            let fixture = TerminalSelectionRoutingTests()
            let (window, view) = await fixture.makeView()
            defer { fixture.close(window, view) }
            view.scrollingAgentID = agent
            view.frame.size.height = view.getOptimalFrameSize().height
            for line in 0..<80 {
                view.feed(text: "line \(line)\r\n")
            }
            if alternate {
                view.feedTerminalData(Array("\u{1b}[?1049h".utf8)[...])
                view.feed(text: "selected text")
            }
            view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
            view.scroll(toPosition: 1)
            view.setSelectionRange(start: .init(col: 0, row: view.getTerminal().buffer.yDisp), end: .init(col: 4, row: view.getTerminal().buffer.yDisp))
            let selection = try #require(view.getSelection())
            let offset = view.contentOffset
            let mousePan = try #require(view.gestureRecognizers?.compactMap { $0 as? TerminalMousePanGestureRecognizer }.first)
            #expect(view.usesRemoteMouseScrolling == alternate)
            #expect(view.isScrollEnabled == !alternate)
            #expect(view.gestureRecognizerShouldBegin(mousePan) == alternate)
            var raw = Data()
            view.onRawInput = { raw.append($0) }
            let pan = TestTerminalPan()
            pan.state = .began
            pan.point = CGPoint(x: view.cellDimension.width * 10.5, y: offset.y + view.cellDimension.height * 2.5)
            pan.delta.y = view.cellDimension.height * 3 + 0.01
            view.handleMouseModePan(pan)
            #expect(raw.isEmpty == !alternate)
            #expect(view.selectionActive && view.getSelection() == selection)
            #expect(view.contentOffset == offset)
            pan.state = .ended
            pan.speed.y = 1_000
            view.handleMouseModePan(pan)
            #expect(!view.isMouseScrollDecelerating)
            raw.removeAll()
            view.clearSelection()
            #expect(view.usesRemoteMouseScrolling && !view.isScrollEnabled)
            pan.state = .began
            pan.delta.y = view.cellDimension.height * 3 + 0.01
            view.handleMouseModePan(pan)
            #expect(!raw.isEmpty)
        }

        @Test("Returning a frozen pixel viewport to the tail restores output following", arguments: [0.0, 34.0], [false, true])
        func pixelReturnToTailResumesFollowing(bottomInset: Double, rowAlreadyAtTail: Bool) async throws {
            let fixture = TerminalSelectionRoutingTests()
            let (window, view) = await fixture.makeView()
            defer { fixture.close(window, view) }
            view.frame.size.height = view.getOptimalFrameSize().height
            view.contentInset.bottom = bottomInset
            view.layoutIfNeeded()
            for line in 0..<80 {
                view.feed(text: "line \(line)\r\n")
            }
            view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
            view.scroll(toPosition: 1)
            let terminal = view.getTerminal()
            let firstTailRow = terminal.buffer.yDisp
            let firstTailOffset = view.contentOffset
            view.scroll(toPosition: 0.5)
            let historyRow = terminal.buffer.yDisp
            let historyOffset = view.contentOffset
            #expect(view.userScrolling && terminal.userScrolling)
            view.feedTerminalData(Array("\r\nhistory output".utf8)[...])
            #expect(terminal.buffer.yDisp == historyRow && view.contentOffset == historyOffset)
            #expect(view.isScrollEnabled && view.userScrolling && terminal.userScrolling)

            // A tracked drag may already update yDisp; momentum can retain the old row.
            if rowAlreadyAtTail {
                terminal.buffer.yDisp = firstTailRow + 1
            }
            // Return by pixel movement, without the API that would itself clear history mode.
            view.contentOffset = CGPoint(x: firstTailOffset.x, y: firstTailOffset.y + view.cellDimension.height)
            #expect(!view.isScrollEnabled && !view.userScrolling && !terminal.userScrolling)
            #expect(terminal.buffer.yDisp == firstTailRow + 1)
            view.feedTerminalData(Array("\r\nfollow output".utf8)[...])
            #expect(terminal.buffer.yDisp == firstTailRow + 2)
            #expect(abs(view.contentOffset.y - firstTailOffset.y - 2 * view.cellDimension.height) < 0.01)
            #expect(!view.isScrollEnabled && !view.userScrolling && !terminal.userScrolling)
            let mousePan = try #require(view.gestureRecognizers?.compactMap { $0 as? TerminalMousePanGestureRecognizer }.first)
            #expect(view.gestureRecognizerShouldBegin(mousePan))
            var raw = Data()
            view.onRawInput = { raw.append($0) }
            let pan = TestTerminalPan()
            pan.state = .began
            pan.point = CGPoint(x: view.cellDimension.width * 4.5, y: view.contentOffset.y + view.cellDimension.height * 2.5)
            pan.delta.y = view.cellDimension.height * 3 + 0.01
            view.handleMouseModePan(pan)
            #expect(!raw.isEmpty)
        }

        @Test("Clearing a history selection keeps pans local for touch and accessibility paging", arguments: [false, true], [0.0, 34.0])
        func clearedHistoryRetainsLocalScrolling(accessibility: Bool, bottomInset: Double) async throws {
            let fixture = TerminalSelectionRoutingTests()
            let (window, view) = await fixture.makeView()
            defer { fixture.close(window, view) }
            view.frame.size.height = view.getOptimalFrameSize().height
            view.contentInset.bottom = bottomInset
            view.layoutIfNeeded()
            for line in 0..<80 {
                view.feed(text: "line \(line)\r\n")
            }
            view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
            view.scroll(toPosition: 1)
            if accessibility {
                #expect(view.accessibilityScroll(.up))
                #expect(view.scrollPosition == 1)
            } else {
                view.scroll(toPosition: 0.5)
                #expect(view.scrollPosition < 1)
            }
            let offset = view.contentOffset
            let row = Int(floor(offset.y / view.cellDimension.height))
            #expect(view.canScroll && view.isScrollEnabled)
            view.setSelectionRange(start: .init(col: 0, row: row), end: .init(col: 4, row: row))
            view.clearSelection()
            #expect(!view.selectionActive && view.isScrollEnabled)
            let mousePan = try #require(view.gestureRecognizers?.compactMap { $0 as? TerminalMousePanGestureRecognizer }.first)
            #expect(!view.gestureRecognizerShouldBegin(mousePan))
            var raw = Data()
            view.onRawInput = { raw.append($0) }
            let pan = TestTerminalPan()
            pan.point = CGPoint(x: view.cellDimension.width * 4.5, y: offset.y + view.cellDimension.height * 2.5)
            pan.delta.y = view.cellDimension.height * 3 + 0.01
            pan.state = .began
            view.handleMouseModePan(pan)
            #expect(raw.isEmpty && view.contentOffset == offset)
            if accessibility {
                #expect(view.accessibilityScroll(.down))
            } else {
                view.scroll(toPosition: 1)
            }
            #expect(view.scrollPosition == 1 && !view.isScrollEnabled)
            #expect(view.gestureRecognizerShouldBegin(mousePan))
            pan.point.y = view.contentOffset.y + view.cellDimension.height * 2.5
            pan.delta.y = view.cellDimension.height * 3 + 0.01
            view.handleMouseModePan(pan)
            #expect(!raw.isEmpty)
        }

        @Test("Native and accessibility live-tail positioning remain eligible with insets and partial rows", arguments: [0.0, 34.0], [0.0, 0.25, 0.75])
        func nativeTailMatchesItsScrollLimit(bottomInset: Double, extraRowFraction: Double) async throws {
            let fixture = TerminalSelectionRoutingTests()
            let (window, view) = await fixture.makeView()
            defer { fixture.close(window, view) }
            view.frame.size.height = view.getOptimalFrameSize().height + extraRowFraction * view.cellDimension.height
            view.contentInset.bottom = bottomInset
            view.layoutIfNeeded()
            for line in 0..<80 {
                view.feed(text: "line \(line)\r\n")
            }
            view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
            let mousePan = try #require(view.gestureRecognizers?.compactMap { $0 as? TerminalMousePanGestureRecognizer }.first)
            var raw = Data()
            view.onRawInput = { raw.append($0) }
            let pan = TestTerminalPan()
            pan.state = .began
            for position in [1.0, 0.5, 1.0] {
                raw.removeAll()
                view.scroll(toPosition: position)
                let live = position == 1
                #expect(view.isScrollEnabled == !live)
                #expect(view.gestureRecognizerShouldBegin(mousePan) == live)
                pan.point = CGPoint(x: view.cellDimension.width * 4.5, y: view.contentOffset.y + view.cellDimension.height * 2.5)
                pan.delta.y = view.cellDimension.height * 3 + 0.01
                view.handleMouseModePan(pan)
                #expect(raw.isEmpty == !live)
            }
            let liveOffset = view.contentOffset
            #expect(!view.accessibilityScroll(.down) && view.contentOffset == liveOffset)
            #expect(view.accessibilityScroll(.up))
            let row = Int(floor(view.contentOffset.y / view.cellDimension.height))
            view.setSelectionRange(start: .init(col: 0, row: row), end: .init(col: 4, row: row))
            view.clearSelection()
            #expect(view.isScrollEnabled && !view.gestureRecognizerShouldBegin(mousePan))
            #expect(view.accessibilityScroll(.down))
            #expect(view.contentOffset == liveOffset && !view.isScrollEnabled)
            #expect(view.gestureRecognizerShouldBegin(mousePan))
        }

        @Test("Drag distance is compensated and wheel coordinates stay in the initial transcript")
        func anchoredDrag() async {
            let fixture = TerminalSelectionRoutingTests()
            let (window, view) = await fixture.makeView()
            defer { fixture.close(window, view) }
            view.scrollingAgentID = "codex"
            view.feedTerminalData(Array("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h".utf8)[...])
            var raw = Data()
            view.onRawInput = { raw.append($0) }
            let pan = TestTerminalPan()
            pan.point = CGPoint(x: view.cellDimension.width * 4.5, y: view.cellDimension.height * 2.5)
            pan.state = .began
            view.handleMouseModePan(pan)
            pan.state = .changed
            pan.point.y = view.bounds.maxY - 1
            pan.delta.y = view.cellDimension.height * 6 + 0.01
            view.handleMouseModePan(pan)
            let text = String(decoding: raw, as: UTF8.self)
            #expect(text == String(repeating: "\u{1b}[<64;5;3M", count: 2))
        }

        @Test("Gesture end consumes its last translation and only fullscreen Codex coasts", arguments: ["codex", "claude-code"])
        func endGesture(agent: String) async {
            let fixture = TerminalSelectionRoutingTests()
            let (window, view) = await fixture.makeView()
            defer { fixture.close(window, view) }
            view.scrollingAgentID = agent
            view.feedTerminalData(Array("\u{1b}[?1049h\u{1b}[?1000h".utf8)[...])
            var raw = Data()
            view.onRawInput = { raw.append($0) }
            let pan = TestTerminalPan()
            pan.state = .began
            view.handleMouseModePan(pan)
            pan.state = .ended
            pan.delta.y = view.cellDimension.height * 3 + 0.01
            pan.speed.y = 1_000
            view.handleMouseModePan(pan)
            #expect(!raw.isEmpty)
            #expect(view.isMouseScrollDecelerating == (agent == "codex"))
        }

        @Test("Touch, input, pane changes, selection, mode changes and detach stop coasting", arguments: [
            "touch", "input", "inactive", "invalidate", "selection", "mode", "agent", "detach", "tap",
        ])
        func cancelMomentum(reason: String) async throws {
            let fixture = TerminalSelectionRoutingTests()
            let (window, view) = await fixture.makeView()
            defer { fixture.close(window, view) }
            view.scrollingAgentID = "codex"
            view.feedTerminalData(Array("\u{1b}[?1049h\u{1b}[?1000h".utf8)[...])
            let pan = TestTerminalPan()
            pan.state = .began
            view.handleMouseModePan(pan)
            pan.state = .ended
            pan.speed.y = 1_000
            view.handleMouseModePan(pan)
            #expect(view.isMouseScrollDecelerating)
            switch reason {
            case "touch":
                let recognizer = try #require(view.gestureRecognizers?.compactMap { $0 as? TerminalMousePanGestureRecognizer }.first)
                recognizer.onTouchDown?()
            case "input": view.prepareForExternalInput()
            case "inactive": view.updateInput(isEnabled: false, keyboardRequested: false)
            case "invalidate": view.invalidateInput()
            case "selection": _ = view.shouldBeginSelection(at: .init(col: 1, row: 1))
            case "mode": view.feedTerminalData(Array("\u{1b}[?1000l".utf8)[...])
            case "agent": view.scrollingAgentID = nil
            case "detach": view.removeFromSuperview()
            default: view.handleContentTap(at: .zero)
            }
            #expect(!view.isMouseScrollDecelerating)
        }

        final private class TestTerminalPan: UIPanGestureRecognizer {
            var point = CGPoint.zero
            var delta = CGPoint.zero
            var speed = CGPoint.zero
            private var testState: UIGestureRecognizer.State = .possible
            override var state: UIGestureRecognizer.State {
                get { testState }
                set { testState = newValue }
            }

            override func location(in view: UIView?) -> CGPoint {
                point
            }

            override func translation(in view: UIView?) -> CGPoint {
                delta
            }

            override func setTranslation(_ translation: CGPoint, in view: UIView?) {
                delta = translation
            }

            override func velocity(in view: UIView?) -> CGPoint {
                speed
            }
        }
    }
#endif
