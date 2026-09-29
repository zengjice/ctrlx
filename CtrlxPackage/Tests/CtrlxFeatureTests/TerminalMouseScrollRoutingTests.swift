#if os(iOS)
    import Foundation
    import Testing
    import UIKit
    @testable import CtrlxFeature
    @testable import SwiftTerm

    @MainActor
    @Suite("iOS fullscreen mouse scrolling", .serialized)
    struct TerminalMouseScrollRoutingTests {
        @Test("Drag distance is compensated and wheel coordinates stay in the initial transcript")
        func anchoredDrag() async throws {
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

        private final class TestTerminalPan: UIPanGestureRecognizer {
            var point = CGPoint.zero
            var delta = CGPoint.zero
            var speed = CGPoint.zero
            private var testState: UIGestureRecognizer.State = .possible
            override var state: UIGestureRecognizer.State {
                get { testState }
                set { testState = newValue }
            }
            override func location(in view: UIView?) -> CGPoint { point }
            override func translation(in view: UIView?) -> CGPoint { delta }
            override func setTranslation(_ translation: CGPoint, in view: UIView?) { delta = translation }
            override func velocity(in view: UIView?) -> CGPoint { speed }
        }
    }
#endif
