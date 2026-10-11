#if os(iOS)
import CtrlxCommon
import Testing
import UIKit
@testable import CtrlxFeature

@Suite("Terminal native viewport", .serialized)
@MainActor
struct TerminalNativeViewportTests {
    @Test("Window swipes reserve Back, selection and horizontal scrolling")
    func windowSwipeEligibility() {
        let fixture = makeViewport(rows: 57)
        defer { fixture.close() }
        let swipe = TerminalWindowSwipeGesture(viewport: fixture.viewport, terminal: fixture.terminal)
        let center = CGPoint(x: 180, y: 200)
        #expect(!swipe.recognizer.isEnabled)
        #expect(!swipe.canStart(at: center))
        swipe.onNextWindow = { }
        #expect(swipe.canStart(at: center))
        #expect(!swipe.canStart(at: CGPoint(x: 32, y: 200)))
        #expect(swipe.recognizer.direction == .right)
        #expect(swipe.recognizer.numberOfTouchesRequired == 1)
        #expect(!swipe.recognizer.cancelsTouchesInView)

        fixture.viewport.contentSize.width = 900
        fixture.viewport.contentOffset.x = 80
        #expect(!swipe.canStart(at: center))
        fixture.viewport.contentInset.left = 12
        fixture.viewport.contentOffset.x = -12
        #expect(swipe.canStart(at: center))

        fixture.terminal.feedTerminalData(Array("selected text".utf8)[...])
        fixture.terminal.setSelectionRange(start: .init(col: 0, row: 0), end: .init(col: 8, row: 0))
        #expect(!swipe.canStart(at: center))
        #expect(!swipe.gestureRecognizerShouldBegin(swipe.recognizer))
        swipe.onNextWindow = nil
        #expect(!swipe.recognizer.isEnabled)
    }

    @Test("Window swipes coexist only with terminal pans, not navigation or selection gestures")
    func windowSwipeGestureCoexistence() {
        let fixture = makeViewport(rows: 57)
        defer { fixture.close() }
        let swipe = TerminalWindowSwipeGesture(viewport: fixture.viewport, terminal: fixture.terminal)
        #expect(swipe.gestureRecognizer(swipe.recognizer, shouldRecognizeSimultaneouslyWith: fixture.viewport.panGestureRecognizer))
        #expect(swipe.gestureRecognizer(swipe.recognizer, shouldRecognizeSimultaneouslyWith: fixture.terminal.panGestureRecognizer))
        let back = UIScreenEdgePanGestureRecognizer()
        fixture.window.addGestureRecognizer(back)
        #expect(!swipe.gestureRecognizer(swipe.recognizer, shouldRecognizeSimultaneouslyWith: back))
        let selection = UILongPressGestureRecognizer()
        fixture.terminal.addGestureRecognizer(selection)
        #expect(!swipe.gestureRecognizer(swipe.recognizer, shouldRecognizeSimultaneouslyWith: selection))
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
        swipe.onNextWindow = { }
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
