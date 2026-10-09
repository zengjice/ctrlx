#if os(iOS)
import CtrlxCommon
import Testing
import UIKit
@testable import CtrlxFeature

@Suite("Terminal native viewport", .serialized)
@MainActor
struct TerminalNativeViewportTests {
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
