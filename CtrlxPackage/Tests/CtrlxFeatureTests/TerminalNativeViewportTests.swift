#if os(iOS)
import CtrlxCommon
import Testing
import UIKit
@testable import CtrlxFeature

@Suite("Terminal native viewport", .serialized)
@MainActor
struct TerminalNativeViewportTests {
    @Test("Window swipes reserve Back and selection")
    func windowSwipeEligibility() {
        let fixture = makeViewport(rows: 57)
        defer { fixture.close() }
        let swipe = TerminalWindowSwipeGesture(viewport: fixture.viewport, terminal: fixture.terminal)
        let center = CGPoint(x: 180, y: 200)
        #expect(!swipe.recognizer.isEnabled)
        #expect(!swipe.canStart(at: center))
        swipe.onSwitchWindow = { _ in }
        #expect(swipe.canStart(at: center))
        #expect(!swipe.canStart(at: CGPoint(x: 32, y: 200)))
        #expect(swipe.recognizer.minimumNumberOfTouches == 1)
        #expect(swipe.recognizer.maximumNumberOfTouches == 1)
        #expect(!swipe.recognizer.cancelsTouchesInView)
        #expect(swipe.recognizer.view === fixture.viewport)

        fixture.terminal.feedTerminalData(Array("selected text".utf8)[...])
        fixture.terminal.setSelectionRange(start: .init(col: 0, row: 0), end: .init(col: 8, row: 0))
        #expect(!swipe.canStart(at: center))
        #expect(!swipe.gestureRecognizerShouldBegin(swipe.recognizer))
        swipe.onSwitchWindow = nil
        #expect(!swipe.recognizer.isEnabled)
    }

    @Test("Window drags switch once on release, keeping the captured window and direction", arguments: [-1.0, 1.0])
    func windowSwipeCompletion(sign: Double) {
        let fixture = makeViewport(rows: 57)
        defer { fixture.close() }
        let swipe = TerminalWindowSwipeGesture(viewport: fixture.viewport, terminal: fixture.terminal)
        fixture.viewport.contentSize.width = fixture.viewport.bounds.width
        fixture.viewport.contentOffset.x = 0
        var actions: [String] = []
        var directions: [TerminalWindowSwipePolicy.Direction] = []
        swipe.onSwitchWindow = {
            actions.append("original")
            directions.append($0)
        }
        swipe.recognizer.setTranslation(CGPoint(x: sign * 12, y: 1), in: fixture.window)
        #expect(swipe.gestureRecognizerShouldBegin(swipe.recognizer))
        let pan = TestWindowPan()
        pan.state = .began
        swipe.handlePan(pan)
        swipe.onSwitchWindow = { _ in actions.append("updated") }
        pan.state = .changed
        pan.delta = CGPoint(x: sign * 100, y: 10)
        swipe.handlePan(pan)
        #expect(actions.isEmpty)
        pan.state = .ended
        swipe.handlePan(pan)
        swipe.handlePan(pan)
        #expect(actions == ["original"])
        #expect(directions == [sign < 0 ? .next : .previous])
    }

    @Test("Cancelled, short, reversed and disabled window drags never switch",
          arguments: ["cancelled", "short", "reversed", "disabled", "selection"], [-1.0, 1.0])
    func windowSwipeCancellation(reason: String, sign: Double) {
        let fixture = makeViewport(rows: 57)
        defer { fixture.close() }
        let swipe = TerminalWindowSwipeGesture(viewport: fixture.viewport, terminal: fixture.terminal)
        fixture.viewport.contentSize.width = fixture.viewport.bounds.width
        fixture.viewport.contentOffset.x = 0
        var count = 0
        swipe.onSwitchWindow = { _ in count += 1 }
        swipe.recognizer.setTranslation(CGPoint(x: sign * 12, y: 1), in: fixture.window)
        #expect(swipe.gestureRecognizerShouldBegin(swipe.recognizer))
        let pan = TestWindowPan()
        pan.delta = CGPoint(x: sign * 100, y: 10)
        switch reason {
        case "cancelled":
            pan.state = .cancelled
            swipe.handlePan(pan)
        case "short": pan.delta = CGPoint(x: sign * 30, y: 0)
        case "reversed": pan.delta = CGPoint(x: sign * -100, y: 0)
        case "disabled":
            swipe.onSwitchWindow = nil
            swipe.onSwitchWindow = { _ in count += 1 }
        default:
            fixture.terminal.feedTerminalData(Array("selected text".utf8)[...])
            fixture.terminal.setSelectionRange(start: .init(col: 0, row: 0), end: .init(col: 8, row: 0))
        }
        pan.state = .ended
        swipe.handlePan(pan)
        #expect(count == 0)
    }

    @Test("Vertical and diagonal drags release the terminal's scrolling recognizers")
    func windowSwipeDirection() {
        let fixture = makeViewport(rows: 57)
        defer { fixture.close() }
        let swipe = TerminalWindowSwipeGesture(viewport: fixture.viewport, terminal: fixture.terminal)
        swipe.onSwitchWindow = { _ in }
        for translation in [CGPoint(x: 1, y: 12), CGPoint(x: -1, y: -12), CGPoint(x: 12, y: -12), CGPoint(x: -12, y: 12)] {
            swipe.recognizer.setTranslation(translation, in: fixture.window)
            #expect(!swipe.gestureRecognizerShouldBegin(swipe.recognizer))
        }
    }

    @Test("Wide terminals scroll first and only navigate outward at the corresponding edge")
    func windowSwipeHorizontalEdges() {
        let fixture = makeViewport(rows: 57)
        defer { fixture.close() }
        let swipe = TerminalWindowSwipeGesture(viewport: fixture.viewport, terminal: fixture.terminal)
        swipe.onSwitchWindow = { _ in }
        fixture.viewport.contentSize.width = 900
        fixture.viewport.contentInset.left = 12
        fixture.viewport.contentInset.right = 20
        let leftEdge = -fixture.viewport.adjustedContentInset.left
        let rightEdge = 900 - fixture.viewport.bounds.width + fixture.viewport.adjustedContentInset.right
        for offset in [leftEdge, 80, rightEdge] {
            fixture.viewport.contentOffset.x = offset
            for x in [-12.0, 12.0] {
                swipe.recognizer.setTranslation(CGPoint(x: x, y: 1), in: fixture.window)
                let isOutward = x < 0 ? offset == rightEdge : offset == leftEdge
                #expect(swipe.gestureRecognizerShouldBegin(swipe.recognizer) == isOutward)
            }
        }
    }

    @Test("Window swipes take priority over iOS 26 content Back, but not edge Back")
    func windowSwipeBackPriority() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = makeViewport(rows: 57)
        defer { fixture.close() }
        let root = try #require(fixture.window.rootViewController)
        let navigation = UINavigationController(rootViewController: root)
        fixture.window.rootViewController = navigation
        let swipe = TerminalWindowSwipeGesture(viewport: fixture.viewport, terminal: fixture.terminal)
        swipe.onSwitchWindow = { _ in }
        let contentBack = try #require(navigation.interactiveContentPopGestureRecognizer)
        let edgeBack = try #require(navigation.interactivePopGestureRecognizer)
        #expect(swipe.gestureRecognizer(swipe.recognizer, shouldBeRequiredToFailBy: contentBack))
        #expect(!swipe.gestureRecognizer(swipe.recognizer, shouldBeRequiredToFailBy: edgeBack))
        #expect(!swipe.gestureRecognizer(swipe.recognizer, shouldBeRequiredToFailBy: fixture.viewport.panGestureRecognizer))
    }

    @Test("A quiet tall Shell is visible before any drag or additional byte")
    func quietShell() throws {
        let fixture = makeViewport(rows: 57)
        defer { fixture.close() }
        fixture.terminal.feedTerminalData(Array("\u{1b}[H\u{1b}[2J(base) Office > ".utf8)[...])
        fixture.viewport.requestInitialTailPresentation { fixture.terminal.presentCurrentTail() }
        fixture.layout()
        let cursor = try #require(fixture.terminal.liveCursorRect)
        let visibleCursor = fixture.terminal.convert(cursor, to: fixture.viewport)
        #expect(visibleCursor.minY >= fixture.viewport.bounds.minY)
        #expect(visibleCursor.maxY <= fixture.viewport.bounds.maxY)
        #expect(fixture.viewport.contentOffset.y == 0)
        #expect(fixture.terminal.getTerminal().rows == 57)
        #expect(fixture.terminal.getTerminal().getLine(row: 0)?.translateToString().contains("Office") == true)

        // A later accessory/keyboard shrink needs no output to reveal the prompt.
        fixture.viewport.frame.size.height = 400
        fixture.layout()
        #expect(fixture.viewport.contentOffset.y == 0)
        #expect(fixture.terminal.getTerminal().rows == 57)
    }

    @Test("Alternate-screen applications retain bottom positioning")
    func alternateScreen() {
        let fixture = makeViewport(rows: 57)
        defer { fixture.close() }
        fixture.terminal.feedTerminalData(Array("\u{1b}[?1049h\u{1b}[Hcomposer".utf8)[...])
        fixture.viewport.requestInitialTailPresentation { fixture.terminal.presentCurrentTail() }
        fixture.layout()
        #expect(fixture.terminal.liveCursorRect == nil)
        #expect(fixture.viewport.contentOffset.y > 0)
    }

    @Test("Normal-screen history and selection are not reset by layout")
    func historyAndSelection() {
        let fixture = makeViewport(rows: 57)
        defer { fixture.close() }
        fixture.terminal.feedTerminalData(Array("prompt".utf8)[...])
        fixture.terminal.setSelectionRange(start: .init(col: 0, row: 0), end: .init(col: 6, row: 0))
        fixture.viewport.userWillBeginScrolling()
        fixture.viewport.contentOffset.y = 30
        fixture.viewport.userDidEndScrolling()
        fixture.viewport.frame.size.height = 400
        fixture.layout()
        #expect(fixture.viewport.contentOffset.y == 30)
        #expect(fixture.terminal.selectionActive)
    }

    @Test("Fit waits for native input presentation and the final viewport")
    func finalViewportMeasurement() throws {
        let fixture = makeViewport(rows: 57)
        defer { fixture.close() }
        var inputReady = false
        fixture.viewport.isInputPresentationReady = { inputReady }
        var measurements: [CGSize?] = []
        fixture.viewport.onViewportChange = { measurements.append($0) }
        fixture.layout()
        #expect(measurements.last == .some(nil))
        inputReady = true
        fixture.viewport.setKeyboardTransitioning(true)
        fixture.layout()
        #expect(measurements.last == .some(nil))
        fixture.viewport.frame.size.height = 400
        fixture.viewport.contentInset = .init(top: 10, left: 0, bottom: 20, right: 0)
        fixture.viewport.setKeyboardTransitioning(false)
        fixture.layout()
        let size = try #require(measurements.last ?? nil)
        #expect(size.height == 370)
        let grid = try #require(TerminalViewportSizing.grid(viewport: size, cellSize: .init(width: 6, height: 13)))
        #expect(grid.rows == 28)
    }

    @Test("Cursor coordinates include normal-screen scrollback")
    func scrollbackCoordinates() throws {
        let fixture = makeViewport(rows: 57)
        defer { fixture.close() }
        fixture.terminal.feedTerminalData(Array(String(repeating: "line\r\n", count: 80).utf8)[...])
        fixture.terminal.presentCurrentTail()
        fixture.layout()
        let cursor = try #require(fixture.terminal.liveCursorRect)
        let rect = fixture.terminal.convert(cursor, to: fixture.viewport)
        #expect(rect.minY >= fixture.viewport.bounds.minY)
        #expect(rect.maxY <= fixture.viewport.bounds.maxY)
        fixture.terminal.scroll(toPosition: 0)
        #expect(fixture.terminal.liveCursorRect == nil)
    }

    @Test("File links follow native content offsets even when yDisp stays behind")
    func fileLinksAfterNativeScroll() throws {
        let fixture = makeViewport(rows: 8)
        defer { fixture.close() }
        var opened: [String] = []
        fixture.terminal.onOpenPath = { opened.append($0) }
        let output = (0..<60).map { "./history/\($0).txt\r\n" }.joined() + "$ "
        fixture.terminal.feedTerminalData(Array(output.utf8)[...])
        fixture.terminal.presentCurrentTail()
        fixture.layout()
        fixture.terminal.scroll(toPosition: 0)
        let terminal = fixture.terminal.getTerminal()
        let cellHeight = fixture.terminal.getOptimalFrameSize().height / CGFloat(terminal.rows)
        let cellWidth = fixture.terminal.getOptimalFrameSize().width / CGFloat(terminal.cols)

        for firstRow in [12.5, 30.25] {
            fixture.terminal.setContentOffset(CGPoint(x: 0, y: firstRow * cellHeight), animated: false)
            fixture.terminal.setNeedsLayout()
            fixture.terminal.layoutIfNeeded()
            #expect(terminal.buffer.yDisp == 0)
            // Include the partially visible final row, not just whole rows.
            let row = Int(ceil(fixture.terminal.bounds.maxY / cellHeight)) - 1
            let path = "./history/\(row).txt"
            #expect(terminal.getScrollInvariantLine(row: row)?.translateToString().hasPrefix(path) == true)
            #expect(fixture.terminal.layer.sublayers?.contains {
                abs($0.frame.minY - (CGFloat(row + 1) * cellHeight - 2)) < 0.1 && $0.frame.height == 1
            } == true)
            fixture.terminal.handleContentTap(at: CGPoint(
                x: cellWidth / 2,
                y: (CGFloat(row) * cellHeight + fixture.terminal.bounds.maxY) / 2
            ))
            #expect(opened.last == path)
        }
        #expect(opened.count == 2)
    }

    private final class TestWindowPan: UIPanGestureRecognizer {
        var delta = CGPoint.zero
        private var testState: UIGestureRecognizer.State = .possible
        override var state: UIGestureRecognizer.State {
            get { testState }
            set { testState = newValue }
        }
        override func translation(in view: UIView?) -> CGPoint { delta }
    }

    private func makeViewport(rows: Int) -> Fixture {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 414, height: 896))
        window.rootViewController = UIViewController()
        window.isHidden = false
        let viewport = BottomAnchoredTerminalScrollView(frame: CGRect(x: 0, y: 0, width: 414, height: 638))
        viewport.contentInsetAdjustmentBehavior = .never
        window.rootViewController?.view.addSubview(viewport)
        let terminal = InteractiveTerminalView(frame: .zero, font: UIFont(name: "Menlo", size: 10))
        terminal.getTerminal().resize(cols: 69, rows: rows)
        terminal.frame = terminal.getOptimalFrameSize()
        viewport.addSubview(terminal)
        viewport.contentSize = terminal.frame.size
        viewport.cursorTop = { [weak terminal, weak viewport] in
            guard let terminal, let viewport, let cursor = terminal.liveCursorRect else { return nil }
            return terminal.convert(cursor, to: viewport).minY
        }
        viewport.isInputPresentationReady = { true }
        return Fixture(window: window, viewport: viewport, terminal: terminal)
    }

    @MainActor
    private struct Fixture {
        let window: UIWindow
        let viewport: BottomAnchoredTerminalScrollView
        let terminal: InteractiveTerminalView

        func layout() {
            viewport.setNeedsLayout()
            viewport.layoutIfNeeded()
        }

        func close() {
            terminal.invalidateInput()
            terminal.updateUiClosed()
            window.isHidden = true
            window.rootViewController = nil
        }
    }
}
#endif
