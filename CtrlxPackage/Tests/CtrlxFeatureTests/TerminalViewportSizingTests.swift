import CtrlxCommon
import Foundation
import Testing
@testable import CtrlxFeature

@Suite("Explicit iOS terminal fit")
struct TerminalViewportSizingTests {
    private typealias Grid = TerminalViewportSizing.Grid

    @Test("The measured viewport excludes padding and rounds down to complete cells")
    func measuredGrid() {
        #expect(TerminalViewportSizing.grid(
            viewport: CGSize(width: 395, height: 667),
            cellSize: CGSize(width: 6, height: 13)
        ) == Grid(columns: 65, rows: 51))
    }

    @Test("Keyboard and rotation change capacity, not Host dimensions")
    func differentViewports() {
        let cell = CGSize(width: 6, height: 13)
        #expect(TerminalViewportSizing.grid(viewport: CGSize(width: 394, height: 390), cellSize: cell)
            == Grid(columns: 65, rows: 30))
        #expect(TerminalViewportSizing.grid(viewport: CGSize(width: 784, height: 286), cellSize: cell)
            == Grid(columns: 130, rows: 22))
    }

    @Test("Invalid or tiny viewports are not ready for fitting")
    func invalidGrid() {
        for viewport in [CGSize.zero, CGSize(width: 15, height: 20), CGSize(width: CGFloat.infinity, height: 100)] {
            #expect(TerminalViewportSizing.grid(viewport: viewport, cellSize: CGSize(width: 6, height: 13)) == nil)
        }
        for cell in [CGSize.zero, CGSize(width: -1, height: 13), CGSize(width: CGFloat.nan, height: 13)] {
            #expect(TerminalViewportSizing.grid(viewport: CGSize(width: 394, height: 650), cellSize: cell) == nil)
        }
    }

    @Test("Single pane uses phone capacity without a desktop minimum")
    func singlePane() {
        let request = TerminalViewportSizing.request(
            layout: .pane(id: 5, width: 132, height: 48),
            paneGrids: ["%5": Grid(columns: 65, rows: 51)]
        )
        #expect(request?.width == 65)
        #expect(request?.height == 51)
        #expect(request?.userInitiated == true)
    }

    @Test("Side-by-side fit respects the smaller proportional capacity and divider")
    func horizontalPanes() {
        let request = TerminalViewportSizing.request(
            layout: .horizontal(children: panes, width: 121, height: 60),
            paneGrids: ["%1": Grid(columns: 28, rows: 44), "%2": Grid(columns: 36, rows: 43)]
        )
        #expect(request?.width == 57)
        #expect(request?.height == 43)
    }

    @Test("Stacked panes include the divider and per-pane telemetry consumption")
    func verticalPanes() {
        let request = TerminalViewportSizing.request(
            layout: .vertical(children: panes, width: 120, height: 61),
            paneGrids: ["%1": Grid(columns: 65, rows: 20), "%2": Grid(columns: 64, rows: 23)]
        )
        #expect(request?.width == 64)
        #expect(request?.height == 41)
    }

    @Test("Nested splits combine actual leaf viewports, not Host leaf sizes")
    func nestedPanes() {
        let layout = LayoutNode.horizontal(children: [
            .vertical(children: panes, width: 60, height: 61),
            .pane(id: 3, width: 60, height: 61),
        ], width: 121, height: 61)
        let request = TerminalViewportSizing.request(layout: layout, paneGrids: [
            "%1": Grid(columns: 28, rows: 20), "%2": Grid(columns: 27, rows: 23),
            "%3": Grid(columns: 36, rows: 45),
        ])
        #expect(request?.width == 55)
        #expect(request?.height == 41)
    }

    @Test("Missing measurements and empty layouts cannot send a resize")
    func incompleteLayout() {
        #expect(TerminalViewportSizing.request(
            layout: .horizontal(children: panes, width: 121, height: 60),
            paneGrids: ["%1": Grid(columns: 28, rows: 44), "%99": Grid(columns: 60, rows: 60)]
        ) == nil)
        #expect(TerminalViewportSizing.request(
            layout: .vertical(children: [], width: 120, height: 60), paneGrids: [:]
        ) == nil)
    }

    @Test("Large viewports and combined layouts are bounded")
    func boundedGrid() {
        #expect(TerminalViewportSizing.grid(
            viewport: CGSize(width: 1e20, height: 1e20), cellSize: CGSize(width: 6, height: 13)
        ) == Grid(columns: 300, rows: 100))
        let request = TerminalViewportSizing.request(
            layout: .horizontal(children: panes, width: 121, height: 60),
            paneGrids: ["%1": Grid(columns: 300, rows: 100), "%2": Grid(columns: 300, rows: 100)]
        )
        #expect(request?.width == 300)
        #expect(request?.height == 100)
    }

    private var panes: [LayoutNode] {
        [.pane(id: 1, width: 60, height: 60), .pane(id: 2, width: 60, height: 60)]
    }

    @Test("Unequal panes remain measurable and Fit converges after actual proportional resizing")
    func unequalFitConverges() throws {
        let initial = LayoutNode.horizontal(children: [
            .pane(id: 1, width: 179, height: 60), .pane(id: 2, width: 60, height: 60),
        ], width: 240, height: 60)
        let initialRequest = TerminalViewportSizing.request(layout: initial, paneGrids: [
            "%1": Grid(columns: 48, rows: 44), "%2": Grid(columns: 15, rows: 44),
        ])
        #expect(initialRequest?.width == 60)
        // Matches the real tmux proportional layout for a 60-column target.
        let fitted = LayoutNode.horizontal(children: [
            .pane(id: 1, width: 44, height: 44), .pane(id: 2, width: 15, height: 44),
        ], width: 60, height: 44)
        let cell = CGSize(width: 6, height: 13)
        let left = try #require(TerminalViewportSizing.grid(viewport: CGSize(width: 395 * 44.0 / 60, height: 572), cellSize: cell))
        let right = try #require(TerminalViewportSizing.grid(viewport: CGSize(width: 395 * 15.0 / 60, height: 572), cellSize: cell))
        let repeated = TerminalViewportSizing.request(layout: fitted, paneGrids: ["%1": left, "%2": right])
        #expect(repeated == initialRequest)
    }
}
