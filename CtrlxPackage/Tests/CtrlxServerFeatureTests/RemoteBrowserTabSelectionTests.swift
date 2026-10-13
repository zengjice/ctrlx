#if os(macOS)
    import CtrlxNetworking
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Remote browser tab selection") @MainActor
    struct RemoteBrowserTabSelectionTests {
        private func page(_ title: String) -> RemoteBrowserTab {
            RemoteBrowserTab(
                id: UUID(),
                sessionName: "s",
                title: title,
                url: "about:blank",
                isLoading: false,
                isAgentOwned: false
            )
        }

        @Test
        func closingSelectedRightBrowserSelectsRemainingBrowser() {
            let tabs = SessionFileTabsState()
            let closed = page("closed"), remaining = page("remaining")
            tabs.syncHostBrowserTabs([closed, remaining], sessionWindowIDs: ["@1"])
            tabs.rightSide = [.browser(closed.id), .browser(remaining.id)]
            tabs.selectedRight = .browser(closed.id)

            #expect(!tabs.syncHostBrowserTabs([remaining], sessionWindowIDs: ["@1"]))
            #expect(tabs.selectedRight == .browser(remaining.id))
            #expect(tabs.rightSide == [.browser(remaining.id)])
            #expect(tabs.remoteBrowserTabs[closed.id] == nil)
            #expect(tabs.openBrowserTabs.map(\.id) == [remaining.id])
        }

        @Test(arguments: [false, true])
        func closingSelectedBrowserWithoutTerminalSelectsRemainingLeftTab(useFile: Bool) {
            let tabs = SessionFileTabsState()
            let closed = page("closed"), remaining = page("remaining")
            let file = OpenFileTab(path: "/tmp/test.txt", directoryPath: "/tmp")
            tabs.openFileTabs = [file]
            tabs.syncHostBrowserTabs([closed, remaining], sessionWindowIDs: [])
            tabs.tabOrder = useFile ? [.file(file.id), .browser(remaining.id)] : [.browser(remaining.id), .file(file.id)]
            tabs.selectedBrowserTabId = closed.id

            #expect(!tabs.syncHostBrowserTabs([remaining], sessionWindowIDs: []))
            #expect(tabs.selectedBrowserTabId == (useFile ? nil : remaining.id))
            #expect(tabs.selectedFileTabId == (useFile ? file.id : nil))
            #expect(!tabs.isSplit)
        }

        @Test
        func closingSelectedLeftBrowserDoesNotSelectRightBrowser() {
            let tabs = SessionFileTabsState()
            let closed = page("closed"), left = page("left"), right = page("right")
            tabs.syncHostBrowserTabs([closed, left, right], sessionWindowIDs: [])
            tabs.rightSide = [.browser(right.id)]
            tabs.selectedRight = .browser(right.id)
            tabs.selectedBrowserTabId = closed.id
            tabs.tabOrder = [.browser(right.id), .browser(left.id)]

            #expect(!tabs.syncHostBrowserTabs([left, right], sessionWindowIDs: []))
            #expect(tabs.selectedBrowserTabId == left.id)
            #expect(tabs.selectedRight == .browser(right.id))
        }

        @Test
        func closingLastBrowserWithoutTerminalClearsSelection() {
            let tabs = SessionFileTabsState()
            let closed = page("closed")
            tabs.syncHostBrowserTabs([closed], sessionWindowIDs: [])
            tabs.selectedBrowserTabId = closed.id
            tabs.syncHostBrowserTabs([], sessionWindowIDs: [])
            #expect(tabs.selectedBrowserTabId == nil)
            #expect(tabs.selectedFileTabId == nil)
        }

        @Test(arguments: ["terminal", "file", "localBrowser"])
        func closingRightBrowserUsesExistingFallbacks(kind: String) {
            let tabs = SessionFileTabsState()
            let closed = page("closed")
            let local = BrowserTab(url: URL(staticString: "about:blank"))
            let file = OpenFileTab(path: "/tmp/test.txt", directoryPath: "/tmp")
            tabs.openBrowserTabs = [local]
            tabs.openFileTabs = [file]
            tabs.syncHostBrowserTabs([closed], sessionWindowIDs: ["@1", "@2"])
            let fallback: TabDragPayload = switch kind {
            case "terminal": .window("@2")
            case "file": .file(file.id)
            default: .browser(local.id)
            }
            tabs.rightSide = [.browser(closed.id), fallback]
            tabs.selectedRight = .browser(closed.id)

            tabs.syncHostBrowserTabs([], sessionWindowIDs: ["@1", "@2"])
            #expect(tabs.selectedRight == fallback)
            #expect(tabs.openBrowserTabs.map(\.id) == [local.id])
            #expect(tabs.openBrowserTabs.first?.isViewerLocal == true)
            #expect(tabs.openFileTabs == [file])
        }

        @Test
        func catalogUpdatesDoNotStealValidLeftOrRightSelection() {
            let tabs = SessionFileTabsState()
            let left = page("left"), right = page("right"), closed = page("closed"), added = page("added")
            tabs.syncHostBrowserTabs([left, right, closed], sessionWindowIDs: ["@1"])
            tabs.selectedBrowserTabId = left.id
            tabs.rightSide = [.browser(right.id), .browser(closed.id)]
            tabs.selectedRight = .browser(right.id)
            tabs.splitRatio = 0.7

            tabs.syncHostBrowserTabs([left, right, added], sessionWindowIDs: ["@1"])
            #expect(tabs.selectedBrowserTabId == left.id)
            #expect(tabs.selectedRight == .browser(right.id))
            #expect(tabs.splitRatio == 0.7)
        }

        @Test
        func closingOnlyRightBrowserRemovesSplit() {
            let tabs = SessionFileTabsState()
            let closed = page("closed")
            tabs.syncHostBrowserTabs([closed], sessionWindowIDs: ["@1"])
            tabs.rightSide = [.browser(closed.id)]
            tabs.selectedRight = .browser(closed.id)

            tabs.syncHostBrowserTabs([], sessionWindowIDs: ["@1"])
            #expect(!tabs.isSplit)
            #expect(tabs.selectedRight == nil)
        }

        @Test
        func closingLastLeftBrowserCollapsesAllRightLayout() {
            let tabs = SessionFileTabsState()
            let closed = page("closed"), right = page("right")
            tabs.syncHostBrowserTabs([closed, right], sessionWindowIDs: ["@1"])
            tabs.selectedBrowserTabId = closed.id
            tabs.rightSide = [.window("@1"), .browser(right.id)]
            tabs.selectedRight = .browser(right.id)

            #expect(tabs.syncHostBrowserTabs([right], sessionWindowIDs: ["@1"]))
            #expect(!tabs.isSplit)
            #expect(tabs.selectedRight == nil)
            #expect(tabs.selectedBrowserTabId == nil)
            #expect(tabs.openBrowserTabs.map(\.id) == [right.id])
        }
    }
#endif
