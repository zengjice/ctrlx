#if os(macOS)
    import CtrlxNetworking
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Remote browser tab selection") @MainActor
    struct RemoteBrowserTabSelectionTests {
        @Test("Passive catalog removal preserves unrelated right tabs", arguments: [false, true], [false, true])
        func passiveRemovalUsesLatestPlacement(simulator: Bool, layoutAppliedFirst: Bool) {
            let tabs = SessionFileTabsState()
            let ids = ["@1", "@2", "@3", "@4"]
            let browser = page("Host"), other = BrowserTab(url: URL(fileURLWithPath: "/tmp/kept"))
            let device = RemoteSimulatorTab(
                id: UUID(), sessionName: "s", windowID: "@1", sourcePaneID: "%1", title: "Phone", runtime: "iOS", isPrimary: true
            )
            if simulator {
                tabs.syncHostSimulatorTabs([device], sessionWindowIDs: ids)
                tabs.selectedBrowserTabId = device.id
            } else {
                tabs.syncHostBrowserTabs([browser], sessionWindowIDs: ids)
                tabs.selectedBrowserTabId = browser.id
            }
            tabs.openBrowserTabs.append(other)
            tabs.applySharedTerminalLayout(
                .init(leftWindowId: "@1", rightWindowIds: ["@2", "@3", "@4"], selectedRightWindowId: "@4", revision: 1, sessionWindowIds: ids),
                liveWindowIds: Set(ids)
            )
            tabs.placeRemoteTerminal("@1", onRight: true, sessionWindowIDs: ids)
            tabs.rightSide.insert(.browser(other.id))
            tabs.selectedRight = .browser(other.id)
            let latest = SharedTerminalLayout(
                leftWindowId: "@2", rightWindowIds: ["@3", "@4"], selectedRightWindowId: "@4", revision: 2, sessionWindowIds: ids
            )
            if layoutAppliedFirst {
                tabs.applySharedTerminalLayout(latest, liveWindowIds: Set(ids))
            }
            tabs.projectRemoteTerminalLayout(latest, liveWindowIDs: Set(ids), sessionWindowIDs: Set(ids))
            if simulator {
                #expect(!tabs.syncHostSimulatorTabs([], sessionWindowIDs: ids))
            } else {
                let result = tabs.syncHostBrowserTabs([], sessionWindowIDs: ids) { _ in Issue.record("Passive close became a user close") }
                #expect(result.automaticFit == nil)
            }
            #expect(tabs.rightSide.contains(.browser(other.id)))
            #expect(tabs.selectedRight == .browser(other.id))
            let saved = LayoutSnapshotMapper.viewerPrivateLayout(from: LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil) { ids.firstIndex(of: $0) })
            #expect(saved.rightSide.contains(.browser(id: other.id)))
        }

        private enum ResourceRemoval: CaseIterable {
            case hostBrowser
            case file
            case detachedFile
        }

        @Test("Resource fallback follows the latest right membership", arguments: [false, true], [false, true])
        func latestRightMembership(insertsFirst: Bool, layoutAppliedFirst: Bool) throws {
            for removal in ResourceRemoval.allCases {
                let tabs = SessionFileTabsState()
                let ids = ["@1", "@2", "@3", "@4"]
                let resource = page("closing")
                openResource(removal, id: resource.id, tabs: tabs, browser: resource, windowIDs: ids)
                tabs.applySharedTerminalLayout(
                    .init(
                        leftWindowId: "@1", rightWindowIds: insertsFirst ? ["@3", "@4"] : ["@2", "@3", "@4"],
                        selectedRightWindowId: "@4", revision: 1, sessionWindowIds: ids
                    ), liveWindowIds: Set(ids)
                )
                let payload: TabDragPayload = removal == .hostBrowser ? .browser(resource.id) : .file(resource.id)
                tabs.rightSide.insert(payload)
                tabs.selectedRight = payload
                let latest = SharedTerminalLayout(
                    leftWindowId: insertsFirst ? "@1" : "@2", rightWindowIds: insertsFirst ? ["@2", "@3", "@4"] : ["@3", "@4"],
                    selectedRightWindowId: "@4", splitRatio: 0.6, revision: 2, sessionWindowIds: ids
                )
                if layoutAppliedFirst {
                    tabs.applySharedTerminalLayout(latest, liveWindowIds: Set(ids))
                }
                try removeResource(removal, id: resource.id, tabs: tabs, layout: latest, windowIDs: ids)
                tabs.applySharedTerminalLayout(latest, liveWindowIds: Set(ids))
                let expected = insertsFirst ? "@2" : "@3"
                let request = try #require(tabs.remoteTerminalLayoutRequest(
                    sessionName: "s", sessionWindowIDs: ids, visibleWindowIDs: ids, selectedLeftWindowID: nil, shared: latest
                ))
                #expect(tabs.selectedRight == .window(expected))
                #expect(request.selectedRightWindowId == expected)
                #expect(request.rightWindowIds == latest.rightWindowIds)
            }
        }

        @Test("Removing a left resource keeps unrelated private tabs on the right", arguments: [false, true], ResourceRemoval.allCases)
        private func leftRemovalKeepsPrivatePlacement(layoutAppliedFirst: Bool, removal: ResourceRemoval) throws {
            let tabs = SessionFileTabsState()
            let ids = ["@1", "@2", "@3", "@4"]
            let resource = page("closing"), other = BrowserTab(url: URL(fileURLWithPath: "/tmp/still-open"))
            openResource(removal, id: resource.id, tabs: tabs, browser: resource, windowIDs: ids)
            tabs.openBrowserTabs.append(other)
            tabs.applySharedTerminalLayout(
                .init(leftWindowId: "@1", rightWindowIds: ["@2", "@3", "@4"], selectedRightWindowId: "@4", revision: 1, sessionWindowIds: ids),
                liveWindowIds: Set(ids)
            )
            tabs.rightSide.insert(.browser(other.id))
            if removal == .hostBrowser {
                tabs.selectedBrowserTabId = resource.id
            } else {
                tabs.selectedFileTabId = resource.id
            }
            tabs.placeRemoteTerminal("@1", onRight: true, sessionWindowIDs: ids)
            tabs.selectedRight = .browser(other.id)
            let latest = SharedTerminalLayout(
                leftWindowId: "@2", rightWindowIds: ["@3", "@4"], selectedRightWindowId: "@4",
                splitRatio: 0.6, revision: 2, sessionWindowIds: ids
            )
            if layoutAppliedFirst {
                tabs.applySharedTerminalLayout(latest, liveWindowIds: Set(ids))
            }
            try removeResource(removal, id: resource.id, tabs: tabs, layout: latest, windowIDs: ids)
            #expect(tabs.rightSide.contains(.browser(other.id)))
            #expect(tabs.selectedRight == .browser(other.id))
            #expect(!tabs.rightSide.contains(.window("@2")))
            let snapshot = LayoutSnapshotMapper.viewerPrivateLayout(from: LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil) { ids.firstIndex(of: $0) })
            let restored = try JSONDecoder().decode(SavedFolderLayout.self, from: JSONEncoder().encode(snapshot))
            #expect(restored.rightSide.contains(.browser(id: other.id)))
        }

        private func openResource(_ removal: ResourceRemoval, id: UUID, tabs: SessionFileTabsState, browser: RemoteBrowserTab, windowIDs: [String]) {
            if removal == .hostBrowser {
                tabs.syncHostBrowserTabs([browser], sessionWindowIDs: windowIDs)
            } else {
                tabs.openFileTabs.append(.init(id: id, path: "/tmp/closing.md", directoryPath: "/tmp"))
            }
        }

        private func removeResource(_ removal: ResourceRemoval, id: UUID, tabs: SessionFileTabsState, layout: SharedTerminalLayout, windowIDs: [String]) throws {
            func reconcile(_ wasSelectedRight: Bool) {
                tabs.reconcileRemoteRightPaneSelection(
                    sharedLayout: layout, sessionWindowIDs: windowIDs, visibleWindowIDs: windowIDs,
                    userInitiated: true, recordSelection: wasSelectedRight
                )
            }
            switch removal {
            case .hostBrowser:
                tabs.beginClosingHostBrowserTab(id)
                tabs.syncHostBrowserTabs([], sessionWindowIDs: windowIDs, onUserClose: reconcile)
            case .file:
                let result = try #require(tabs.removeFileTab(id))
                reconcile(result.wasSelectedRight)
            case .detachedFile:
                let wasSelectedRight = tabs.selectedRight == .file(id)
                #expect(tabs.move(.file(id), to: SessionFileTabsState()))
                reconcile(wasSelectedRight)
            }
        }

        @Test(
            "Host browser close preserves its intent across pending layout projection",
            arguments: [false, true], [false, true]
        )
        func userCloseSurvivesPendingLayout(onRight: Bool, layoutAppliedFirst: Bool) throws {
            for addsTerminal in [false, true] {
                let tabs = SessionFileTabsState()
                let browser = page("closing")
                let ids = ["@1", "@2", "@3"]
                tabs.syncHostBrowserTabs([browser], sessionWindowIDs: ids)
                tabs.applySharedTerminalLayout(
                    .init(leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2", revision: 1, sessionWindowIds: ids),
                    liveWindowIds: Set(ids)
                )
                if onRight {
                    tabs.rightSide.insert(.browser(browser.id))
                    tabs.selectedRight = .browser(browser.id)
                } else {
                    tabs.selectedBrowserTabId = browser.id
                    tabs.placeRemoteTerminal("@1", onRight: true, sessionWindowIDs: ids)
                }
                let latestIDs = addsTerminal ? ids + ["@4"] : ids
                let latest = SharedTerminalLayout(
                    leftWindowId: "@1", rightWindowIds: Array(latestIDs.dropFirst()), selectedRightWindowId: "@3",
                    splitRatio: 0.6, revision: 2, sessionWindowIds: latestIDs
                )
                if layoutAppliedFirst {
                    tabs.reconcileRemoteRightPaneSelection(
                        sharedLayout: latest, sessionWindowIDs: latestIDs, visibleWindowIDs: latestIDs,
                        userInitiated: false, recordSelection: false
                    )
                }
                tabs.beginClosingHostBrowserTab(browser.id)
                tabs.syncHostBrowserTabs([], sessionWindowIDs: latestIDs) { wasSelectedRight in
                    tabs.reconcileRemoteRightPaneSelection(
                        sharedLayout: latest, sessionWindowIDs: latestIDs, visibleWindowIDs: latestIDs,
                        userInitiated: true, recordSelection: wasSelectedRight
                    )
                }
                tabs.reconcileRemoteRightPaneSelection(
                    sharedLayout: latest, sessionWindowIDs: latestIDs, visibleWindowIDs: latestIDs,
                    userInitiated: false, recordSelection: false
                )
                let request = try #require(tabs.remoteTerminalLayoutRequest(
                    sessionName: "s", sessionWindowIDs: latestIDs, visibleWindowIDs: latestIDs,
                    selectedLeftWindowID: nil, shared: latest
                ))
                #expect(request.rightWindowIds == (onRight ? latest.rightWindowIds : []))
                #expect(request.selectedRightWindowId == (onRight ? "@2" : nil))
                #expect(tabs.selectedRight == (onRight ? .window("@2") : nil))
            }
        }

        @Test("A confirmed user close runs before automatic fallback or collapse", arguments: [false, true], [false, true])
        func userCloseNotifiesBeforeProjection(onRight: Bool, explicitClose: Bool) {
            let tabs = SessionFileTabsState()
            let browser = page("closing")
            let ids = ["@1", "@2", "@3"]
            tabs.syncHostBrowserTabs([browser], sessionWindowIDs: ids)
            let shared = SharedTerminalLayout(
                leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@3", revision: 1, sessionWindowIds: ids
            )
            tabs.applySharedTerminalLayout(shared, liveWindowIds: Set(ids))
            if onRight {
                tabs.rightSide.insert(.browser(browser.id))
                tabs.selectedRight = .browser(browser.id)
            } else {
                tabs.selectedBrowserTabId = browser.id
                tabs.placeRemoteTerminal("@1", onRight: true, sessionWindowIDs: ids)
            }
            if explicitClose {
                tabs.beginClosingHostBrowserTab(browser.id)
            }
            var events: [Bool] = []
            tabs.syncHostBrowserTabs([], sessionWindowIDs: ids) { wasSelectedRight in
                events.append(wasSelectedRight)
                #expect(tabs.remoteBrowserTabs[browser.id] == nil)
                #expect(!tabs.openBrowserTabs.contains { $0.id == browser.id })
                if onRight {
                    #expect(tabs.selectedRight == nil)
                } else {
                    #expect(tabs.locallySplitTerminalID == "@1")
                    #expect(tabs.isSplit)
                }
            }
            tabs.syncHostBrowserTabs([], sessionWindowIDs: ids) { _ in Issue.record("Close callback repeated") }
            #expect(events == (explicitClose ? [onRight] : []))
        }

        @Test
        func simulatorDescriptorsKeepLocalSelectionAndAreRemovedWithoutAHostClose() {
            let tabs = SessionFileTabsState()
            let page = page("Web")
            tabs.syncHostBrowserTabs([page], sessionWindowIDs: ["@1"])
            tabs.selectedBrowserTabId = page.id
            let simulator = RemoteSimulatorTab(
                id: UUID(),
                sessionName: "s",
                windowID: "@1",
                sourcePaneID: "%1",
                title: "iPhone",
                runtime: "iOS 27",
                isPrimary: true
            )
            tabs.syncHostSimulatorTabs([simulator], sessionWindowIDs: ["@1"])
            #expect(tabs.selectedBrowserTabId == page.id)
            tabs.syncHostBrowserTabs([page], sessionWindowIDs: ["@1"])
            let row = tabs.openBrowserTabs.first { $0.id == simulator.id }
            #expect(row?.isSimulator == true && row?.canClose == false && row?.isViewerLocal == false)
            tabs.rightSide.insert(.browser(simulator.id))
            tabs.selectedRight = .browser(simulator.id)
            tabs.syncHostSimulatorTabs([], sessionWindowIDs: ["@1"])
            #expect(!tabs.openBrowserTabs.contains { $0.id == simulator.id })
            #expect(!tabs.rightSide.contains(.browser(simulator.id)))
            #expect(tabs.remoteBrowserTabs[page.id] == page)
        }

        @Test
        func simulatorRemovalRestoresFileSelection() {
            let tabs = SessionFileTabsState()
            let file = OpenFileTab(path: "/tmp/test.txt", directoryPath: "/tmp")
            tabs.openFileTabs = [file]
            let simulator = RemoteSimulatorTab(
                id: UUID(), sessionName: "s", windowID: "@1", sourcePaneID: "%1",
                title: "iPhone", runtime: "iOS 27", isPrimary: true
            )
            tabs.syncHostSimulatorTabs([simulator], sessionWindowIDs: [])
            tabs.selectedBrowserTabId = simulator.id
            tabs.syncHostSimulatorTabs([], sessionWindowIDs: [])
            #expect(tabs.selectedBrowserTabId == nil)
            #expect(tabs.selectedFileTabId == file.id)
        }

        @Test
        func simulatorTabMovesWithNativeIdentity() {
            let tabs = SessionFileTabsState()
            let simulator = RemoteSimulatorTab(
                id: UUID(), sessionName: "s", windowID: "@1", sourcePaneID: "%1",
                title: "iPhone", runtime: "iOS 27", isPrimary: true
            )
            tabs.syncHostSimulatorTabs([simulator], sessionWindowIDs: [])
            tabs.selectedBrowserTabId = simulator.id
            let destination = SessionFileTabsState()

            #expect(tabs.move(.browser(simulator.id), to: destination))
            #expect(tabs.remoteSimulatorTabs[simulator.id] == nil)
            #expect(destination.remoteSimulatorTabs[simulator.id] == simulator)
            #expect(destination.openBrowserTabs.map(\.id) == [simulator.id])
            #expect(destination.tabOrder == [.browser(simulator.id)])
        }

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

            #expect(!tabs.syncHostBrowserTabs([remaining], sessionWindowIDs: ["@1"]).restoreLeftWindow)
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
            tabs.beginClosingHostBrowserTab(closed.id)

            let update = tabs.syncHostBrowserTabs([remaining], sessionWindowIDs: [])
            #expect(!update.restoreLeftWindow)
            #expect(update.automaticFit == nil)
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

            #expect(!tabs.syncHostBrowserTabs([left, right], sessionWindowIDs: []).restoreLeftWindow)
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

            #expect(tabs.syncHostBrowserTabs([right], sessionWindowIDs: ["@1"]).restoreLeftWindow)
            #expect(!tabs.isSplit)
            #expect(tabs.selectedRight == nil)
            #expect(tabs.selectedBrowserTabId == nil)
            #expect(tabs.openBrowserTabs.map(\.id) == [right.id])
        }

        @Test
        func explicitHostBrowserCloseFitsOnCatalogRemovalOnlyOnce() {
            let tabs = SessionFileTabsState()
            let closed = page("closed")
            tabs.syncHostBrowserTabs([closed], sessionWindowIDs: ["@1"])
            tabs.selectedBrowserTabId = closed.id
            tabs.beginClosingHostBrowserTab(closed.id)

            // A successful command reply need not contain the updated catalog.
            #expect(tabs.syncHostBrowserTabs([closed], sessionWindowIDs: ["@1"]).automaticFit == nil)
            // Conversely, the catalog may confirm removal before the reply arrives.
            let update = tabs.syncHostBrowserTabs([], sessionWindowIDs: ["@1"])
            #expect(update.automaticFit == .left)
            #expect(tabs.selectedBrowserTabId == nil)
            #expect(tabs.syncHostBrowserTabs([], sessionWindowIDs: ["@1"]).automaticFit == nil)
        }

        @Test
        func passiveHostBrowserRemovalDoesNotFit() {
            let tabs = SessionFileTabsState()
            let closed = page("closed")
            tabs.syncHostBrowserTabs([closed], sessionWindowIDs: ["@1"])
            tabs.selectedBrowserTabId = closed.id

            #expect(tabs.syncHostBrowserTabs([], sessionWindowIDs: ["@1"]).automaticFit == nil)
            #expect(tabs.selectedBrowserTabId == nil)
        }

        @Test
        func failedCloseDoesNotGrantFitToALaterCatalogUpdate() {
            let tabs = SessionFileTabsState()
            let closed = page("closed")
            tabs.syncHostBrowserTabs([closed], sessionWindowIDs: ["@1"])
            tabs.selectedBrowserTabId = closed.id
            tabs.beginClosingHostBrowserTab(closed.id)
            tabs.cancelClosingHostBrowserTab(closed.id)

            #expect(tabs.syncHostBrowserTabs([], sessionWindowIDs: ["@1"]).automaticFit == nil)
        }

        @Test(arguments: ["terminal", "file", "browser"])
        func delayedCloseDoesNotFitAfterSelectingAnotherTab(kind: String) {
            let tabs = SessionFileTabsState()
            let closed = page("closed"), other = page("other")
            tabs.syncHostBrowserTabs([closed, other], sessionWindowIDs: ["@1"])
            tabs.selectedBrowserTabId = closed.id
            tabs.beginClosingHostBrowserTab(closed.id)
            tabs.selectedBrowserTabId = kind == "browser" ? other.id : nil
            tabs.selectedFileTabId = kind == "file" ? UUID() : nil

            #expect(tabs.syncHostBrowserTabs([other], sessionWindowIDs: ["@1"]).automaticFit == nil)
        }

        @Test(arguments: ["terminal", "file", "browser", "none"])
        func explicitRightHostBrowserCloseFitsOnlyATerminalFallback(kind: String) {
            let tabs = SessionFileTabsState()
            let closed = page("closed"), other = page("other")
            let file = OpenFileTab(path: "/tmp/test.txt", directoryPath: "/tmp")
            tabs.openFileTabs = [file]
            tabs.syncHostBrowserTabs([closed, other], sessionWindowIDs: ["@1", "@2"])
            tabs.rightSide = [.browser(closed.id)]
            if kind == "terminal" {
                tabs.rightSide.insert(.window("@2"))
            }
            if kind == "file" {
                tabs.rightSide.insert(.file(file.id))
            }
            if kind == "browser" {
                tabs.rightSide.insert(.browser(other.id))
            }
            tabs.selectedRight = .browser(closed.id)
            tabs.beginClosingHostBrowserTab(closed.id)

            let update = tabs.syncHostBrowserTabs([other], sessionWindowIDs: ["@1", "@2"])
            switch kind {
            case "terminal": #expect(update.automaticFit == .right("@2"))
            case "none": #expect(update.automaticFit == .left)
            default: #expect(update.automaticFit == nil)
            }
            #expect(tabs.syncHostBrowserTabs([other], sessionWindowIDs: ["@1", "@2"]).automaticFit == nil)
        }

        @Test
        func explicitLeftCloseFitsRestoredWindowAfterSplitCollapse() {
            let tabs = SessionFileTabsState()
            let closed = page("closed")
            tabs.syncHostBrowserTabs([closed], sessionWindowIDs: ["@1"])
            tabs.selectedBrowserTabId = closed.id
            tabs.rightSide = [.window("@1")]
            tabs.selectedRight = .window("@1")
            tabs.beginClosingHostBrowserTab(closed.id)

            let update = tabs.syncHostBrowserTabs([], sessionWindowIDs: ["@1"])
            #expect(update.restoreLeftWindow)
            #expect(update.automaticFit == .left)
        }
    }
#endif
