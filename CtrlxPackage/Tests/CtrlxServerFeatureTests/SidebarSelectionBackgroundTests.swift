#if os(macOS)
    import AppKit
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite("Sidebar selection background")
    struct SidebarSelectionBackgroundTests {
        @Test("Suppresses native decoration without changing selection")
        func preservesSelection() {
            let table = NSTableView()
            let rows = Rows()
            table.dataSource = rows
            table.reloadData()
            table.allowsMultipleSelection = true
            table.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
            table.style = .sourceList
            table.selectionHighlightStyle = .regular
            let cell = NSTableCellView()
            table.addSubview(cell)
            cell.addSubview(SidebarSelectionBackgroundView())

            #expect(table.selectionHighlightStyle == .none)
            #expect(table.selectedRowIndexes == IndexSet([0, 2]))
            #expect(table.allowsMultipleSelection)
            #expect(table.style == .sourceList)
        }

        @Test("Only changes the nearest enclosing table")
        func nearestTableOnly() {
            let parentTable = NSTableView()
            let sidebarTable = NSOutlineView()
            let unrelatedTable = NSTableView()
            parentTable.selectionHighlightStyle = .regular
            sidebarTable.style = .sourceList
            sidebarTable.selectionHighlightStyle = .regular
            unrelatedTable.selectionHighlightStyle = .regular
            parentTable.addSubview(sidebarTable)
            parentTable.addSubview(unrelatedTable)
            sidebarTable.addSubview(SidebarSelectionBackgroundView())

            #expect(sidebarTable.selectionHighlightStyle == .none)
            #expect(parentTable.selectionHighlightStyle == .regular)
            #expect(unrelatedTable.selectionHighlightStyle == .regular)
        }

        @Test("Layout suppresses a native style reset")
        func reappliesAfterLayout() {
            let table = NSTableView()
            let view = SidebarSelectionBackgroundView()
            table.addSubview(view)
            table.selectionHighlightStyle = .regular
            view.layout()
            #expect(table.selectionHighlightStyle == .none)
            view.layout()
            #expect(table.selectionHighlightStyle == .none)
        }

        @Test("An initially detached view attaches without intercepting input")
        func attachmentAndHitTesting() {
            let view = SidebarSelectionBackgroundView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
            view.suppressNativeHighlight()
            #expect(view.hitTest(CGPoint(x: 10, y: 10)) == nil)

            let table = NSTableView()
            table.selectionHighlightStyle = .regular
            table.addSubview(view)
            #expect(table.selectionHighlightStyle == .none)
            view.removeFromSuperview()
            view.suppressNativeHighlight()
        }

        private final class Rows: NSObject, NSTableViewDataSource {
            func numberOfRows(in tableView: NSTableView) -> Int { 3 }
        }
    }
#endif
