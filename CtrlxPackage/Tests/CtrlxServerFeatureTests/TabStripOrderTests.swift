import Foundation
import Testing
@testable import CtrlxServerFeature

/// Reconciles saved IDs against live tabs, including legacy interleaved layouts.
/// The presentation layer subsequently groups pane-linked children; raw stored
/// order still determines the order of children within each group.
@Suite("TabDragPayload.reconciledOrder")
struct TabStripOrderTests {
    @Test("Dropping on a target always inserts before its leading indicator")
    func dropInsertionIsSymmetric() {
        let a = TabDragPayload.window("@1")
        let b = TabDragPayload.window("@2")
        let c = TabDragPayload.window("@3")

        #expect(TabDragPayload.moving(a, before: c, in: [a, b, c]) == [b, a, c])
        #expect(TabDragPayload.moving(c, before: a, in: [a, b, c]) == [c, a, b])
        #expect(TabDragPayload.moving(a, before: b, in: [a, b, c]) == nil)
    }

    @Test("Window rollback preserves a later file-tab move")
    func rollbackPreservesNonWindowChanges() {
        let file = UUID()
        let before: [TabDragPayload] = [.window("@1"), .file(file), .window("@2"), .window("@3")]
        let pending: [TabDragPayload] = [.file(file), .window("@3"), .window("@1"), .window("@2")]

        #expect(TabDragPayload.restoringWindowOrder(from: before, in: pending) == [
            .file(file), .window("@1"), .window("@2"), .window("@3"),
        ])
    }

    @Test("New sessions omit Git until explicitly opened")
    func defaultOrder() {
        let w1 = "win-1"
        let w2 = "win-2"
        let file = UUID()
        let browser = UUID()

        let order = TabDragPayload.reconciledOrder(
            windowIds: [w1, w2],
            fileTabIds: [file],
            browserTabIds: [browser],
            storedOrder: []
        )

        #expect(order == [
            .window(w1),
            .window(w2),
            .fileExplorer,
            .file(file),
            .browser(browser),
        ])
    }

    @Test("A browser dragged between two windows keeps its interleaved position")
    func interleavedOrderIsPreserved() {
        // Reproduces issue #566: starting layout T1-T2-FileExplorer-Browser,
        // the user drags Browser to sit between T1 and T2.
        let t1 = "win-1"
        let t2 = "win-2"
        let browser = UUID()

        let reordered: [TabDragPayload] = [
            .window(t1),
            .browser(browser),
            .window(t2),
            .fileExplorer,
        ]

        let order = TabDragPayload.reconciledOrder(
            windowIds: [t1, t2],
            fileTabIds: [],
            browserTabIds: [browser],
            storedOrder: reordered
        )

        #expect(order == reordered)
    }

    @Test("New windows slot in just before the file explorer")
    func newWindowSlotsInBeforeFileExplorer() {
        let t1 = "win-1"
        let t2 = "win-2"
        let browser = UUID()

        // Stored order only knows about T1 + Browser (reordered); a new
        // window T2 has just appeared and is not yet in the stored order.
        let stored: [TabDragPayload] = [
            .window(t1),
            .browser(browser),
            .fileExplorer,
        ]

        let order = TabDragPayload.reconciledOrder(
            windowIds: [t1, t2],
            fileTabIds: [],
            browserTabIds: [browser],
            storedOrder: stored
        )

        #expect(order == [
            .window(t1),
            .browser(browser),
            .window(t2),
            .fileExplorer,
        ])
    }

    @Test("Entries whose underlying data is gone drop out of the order")
    func staleEntriesArePruned() {
        let t1 = "win-1"
        let goneWindow = "win-gone"
        let goneBrowser = UUID()

        let stored: [TabDragPayload] = [
            .window(t1),
            .window(goneWindow),
            .browser(goneBrowser),
            .fileExplorer,
        ]

        let order = TabDragPayload.reconciledOrder(
            windowIds: [t1],
            fileTabIds: [],
            browserTabIds: [],
            storedOrder: stored
        )

        #expect(order == [.window(t1), .fileExplorer])
    }

    @Test("Reconciliation is idempotent")
    func idempotent() {
        let t1 = "win-1"
        let t2 = "win-2"
        let browser = UUID()
        let stored: [TabDragPayload] = [
            .window(t1),
            .browser(browser),
            .window(t2),
            .fileExplorer,
        ]

        let once = TabDragPayload.reconciledOrder(
            windowIds: [t1, t2],
            fileTabIds: [],
            browserTabIds: [browser],
            storedOrder: stored
        )
        let twice = TabDragPayload.reconciledOrder(
            windowIds: [t1, t2],
            fileTabIds: [],
            browserTabIds: [browser],
            storedOrder: once
        )

        #expect(once == twice)
    }

    @Test("Duplicate refs in the stored order collapse to a single entry")
    func duplicateRefsAreDeduped() {
        let t1 = "win-1"
        let browser = UUID()

        // A corrupt/legacy stored order containing the same refs twice.
        let stored: [TabDragPayload] = [
            .window(t1),
            .window(t1),
            .fileExplorer,
            .browser(browser),
            .browser(browser),
        ]

        let order = TabDragPayload.reconciledOrder(
            windowIds: [t1],
            fileTabIds: [],
            browserTabIds: [browser],
            storedOrder: stored
        )

        #expect(order == [.window(t1), .fileExplorer, .browser(browser)])
    }

    @Test("New windows append before an absent file explorer falls back to the end")
    func newWindowsFallBackToEndWhenNoFileExplorerStored() {
        let t1 = "win-1"
        let t2 = "win-2"

        // Stored order omits the file explorer entirely; both windows are
        // live, so the `insertAt ?? order.count` fallback drives placement.
        let stored: [TabDragPayload] = [.window(t1)]

        let order = TabDragPayload.reconciledOrder(
            windowIds: [t1, t2],
            fileTabIds: [],
            browserTabIds: [],
            storedOrder: stored
        )

        #expect(order == [.window(t1), .window(t2), .fileExplorer])
    }

    @Test("Remote sessions omit the file explorer and git tab entirely")
    func remoteDefaultOrderHasNoFileExplorer() {
        let t1 = "win-1"
        let t2 = "win-2"
        let browser = UUID()

        let order = TabDragPayload.reconciledOrder(
            windowIds: [t1, t2],
            fileTabIds: [],
            browserTabIds: [browser],
            storedOrder: [],
            includeFileExplorer: false,
            includeGit: false
        )

        #expect(order == [.window(t1), .window(t2), .browser(browser)])
    }

    @Test("A new remote window slots in before the first browser tab")
    func remoteNewWindowSlotsInBeforeBrowser() {
        let t1 = "win-1"
        let t2 = "win-2"
        let browser = UUID()

        // Stored order knows T1 + Browser; a new window T2 has just appeared.
        // The old inline remote cycler dropped it from Cmd-Shift-[/] cycling
        // (issue #566); the shared helper must slot it in.
        let stored: [TabDragPayload] = [
            .window(t1),
            .browser(browser),
        ]

        let order = TabDragPayload.reconciledOrder(
            windowIds: [t1, t2],
            fileTabIds: [],
            browserTabIds: [browser],
            storedOrder: stored,
            includeFileExplorer: false,
            includeGit: false
        )

        #expect(order == [.window(t1), .window(t2), .browser(browser)])
    }

    @Test("A dragged Git tab keeps its interleaved position")
    func gitTabInterleaveIsPreserved() {
        let t1 = "win-1"
        let t2 = "win-2"

        // The user dragged the Git tab to sit between the two terminals.
        let reordered: [TabDragPayload] = [
            .window(t1),
            .git,
            .window(t2),
            .fileExplorer,
        ]

        let order = TabDragPayload.reconciledOrder(
            windowIds: [t1, t2],
            fileTabIds: [],
            browserTabIds: [],
            storedOrder: reordered
        )

        #expect(order == reordered)
    }

    @Test("Reconciliation does not recreate a closed Git tab")
    func closedGitStaysClosed() {
        let t1 = "win-1"

        let stored: [TabDragPayload] = [
            .window(t1),
            .fileExplorer,
        ]

        let order = TabDragPayload.reconciledOrder(
            windowIds: [t1],
            fileTabIds: [],
            browserTabIds: [],
            storedOrder: stored
        )

        #expect(order == [.window(t1), .fileExplorer])
    }

    @Test("Opening Git is explicit and idempotent; closing keeps other tabs")
    @MainActor
    func gitLifecycle() {
        let tabs = SessionFileTabsState()
        tabs.tabOrder = [.window("@1")]
        #expect(!tabs.isGitOpen)
        tabs.selectLeftGit()
        tabs.selectLeftGit()
        #expect(tabs.tabOrder == [.window("@1"), .git])
        #expect(tabs.isGitSelected)
        #expect(!tabs.isPrivateWorkbenchEmpty)
        _ = tabs.selectLeftTerminalWindow("@1")
        #expect(!tabs.isGitSelected && tabs.isGitOpen)
        #expect(!tabs.isPrivateWorkbenchEmpty)
        tabs.closeGit()
        #expect(!tabs.isGitOpen && !tabs.isGitSelected)
        #expect(TabDragPayload.reconciledOrder(
            windowIds: ["@1"], fileTabIds: [], browserTabIds: [],
            storedOrder: tabs.tabOrder, includeFileExplorer: false
        ) == [.window("@1")])
        tabs.selectLeftGit()
        #expect(tabs.isGitOpen && tabs.isGitSelected)
    }

    @Test("Closing right Git chooses the remaining terminal or collapses the split")
    @MainActor
    func closeRightGit() {
        let tabs = SessionFileTabsState()
        tabs.tabOrder = [.window("@1"), .git, .window("@2")]
        tabs.rightSide = [.git, .window("@2")]
        tabs.selectedRight = .git
        tabs.closeGit()
        tabs.reconcileRightPaneSelection(sessionWindowIDs: ["@1", "@2"], includeLocalTabs: true)
        #expect(tabs.selectedRight == .window("@2"))
        #expect(tabs.rightSide == [.window("@2")])

        tabs.tabOrder.append(.git)
        tabs.rightSide = [.git]
        tabs.selectedRight = .git
        tabs.closeGit()
        tabs.reconcileRightPaneSelection(sessionWindowIDs: ["@1", "@2"], includeLocalTabs: true)
        #expect(!tabs.isSplit && tabs.selectedRight == nil)
    }

    @Test("Closing background Git leaves the selected file untouched")
    @MainActor
    func closeBackgroundGit() {
        let tabs = SessionFileTabsState()
        let file = OpenFileTab(path: "/tmp/note.md", directoryPath: "/tmp")
        tabs.openFileTabs = [file]
        tabs.selectLeftGit()
        tabs.selectedFileTabId = file.id
        tabs.closeGit()
        #expect(tabs.selectedFileTabId == file.id)
        #expect(tabs.openFileTabs == [file])
    }

    @Test("Git alone can occupy the left split until closed")
    @MainActor
    func gitKeepsLeftSplitAlive() {
        let tabs = SessionFileTabsState()
        tabs.selectLeftGit()
        _ = tabs.selectLeftTerminalWindow("@1")
        tabs.rightSide = [.window("@1")]
        tabs.selectedRight = .window("@1")
        #expect(!tabs.reconcileRightPaneSelection(sessionWindowIDs: ["@1"], includeLocalTabs: true))
        tabs.repairLeftContent(hasTerminal: false)
        #expect(tabs.isSplit && tabs.isGitSelected)
        tabs.closeGit()
        #expect(tabs.reconcileRightPaneSelection(sessionWindowIDs: ["@1"], includeLocalTabs: true))
        #expect(!tabs.isSplit)
    }
}
