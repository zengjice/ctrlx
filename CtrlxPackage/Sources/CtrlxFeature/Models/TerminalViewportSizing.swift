import CtrlxCommon
import CtrlxNetworking
import Foundation

enum TerminalViewportSizing {
    struct Grid: Equatable, Sendable {
        let columns: Int
        let rows: Int
    }

    static func grid(viewport: CGSize, cellSize: CGSize) -> Grid? {
        let columns = (viewport.width - 4) / cellSize.width
        let rows = viewport.height / cellSize.height
        guard columns.isFinite, rows.isFinite, cellSize.width > 0, cellSize.height > 0,
              columns >= 2, rows >= 2 else { return nil }
        return Grid(columns: Int(min(300, columns)), rows: Int(min(100, rows)))
    }

    /// Measure actual terminal viewports, excluding per-pane telemetry and
    /// parent controls. Fit the whole tmux window, not just its selected pane.
    static func request(layout: LayoutNode, paneGrids: [String: Grid]) -> ResizeTmuxPane? {
        func capacity(_ node: LayoutNode) -> Grid? {
            switch node {
            case let .pane(id, _, _):
                return paneGrids["%\(id)"]
            case let .horizontal(children, _, _), let .vertical(children, _, _):
                let grids = children.compactMap(capacity)
                guard !grids.isEmpty, grids.count == children.count,
                      children.allSatisfy({ $0.width > 0 && $0.height > 0 }) else { return nil }
                let dividers = children.count - 1
                if case .horizontal = node {
                    let total = children.reduce(0) { $0 + $1.width }
                    let available = zip(children, grids).map { child, grid in
                        Int((Double(grid.columns) * Double(total) / Double(child.width)).rounded(.down))
                    }.min() ?? 0
                    return Grid(columns: available + dividers,
                                rows: grids.map(\.rows).min() ?? 0)
                }
                let total = children.reduce(0) { $0 + $1.height }
                let available = zip(children, grids).map { child, grid in
                    Int((Double(grid.rows) * Double(total) / Double(child.height)).rounded(.down))
                }.min() ?? 0
                return Grid(columns: grids.map(\.columns).min() ?? 0,
                            rows: available + dividers)
            }
        }
        guard let grid = capacity(layout) else { return nil }
        return ResizeTmuxPane(width: min(300, grid.columns), height: min(100, grid.rows), userInitiated: true)
    }
}
