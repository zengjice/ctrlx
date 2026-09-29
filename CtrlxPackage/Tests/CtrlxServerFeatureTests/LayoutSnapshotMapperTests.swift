#if os(macOS)
    import CtrlxNetworking
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    /// Covers the `SessionFileTabsState` ⇄ `SavedFolderLayout` translation:
    /// file/browser tabs survive a round trip, window references re-map by tmux
    /// window *index* (and drop when the target session lacks that index), and
    /// the split arrangement / selection are preserved. See
    /// `docs/folder-layout-persistence-plan.md`.
    @Suite("LayoutSnapshotMapper")
    @MainActor
    struct LayoutSnapshotMapperTests {
        // MARK: - Capture

        @Test("Snapshot maps windows to indices, drops unknown windows and deleted files")
        func snapshotMapsAndFilters() {
            let keepId = UUID()
            let deletedId = UUID()

            let tabs = SessionFileTabsState()
            tabs.openFileTabs = [
                OpenFileTab(id: keepId, path: "/proj/a.swift", directoryPath: "/proj"),
                OpenFileTab(id: deletedId, path: "/proj/gone.swift", directoryPath: "/proj", isDeleted: true),
            ]
            tabs.selectedFileTabId = keepId
            tabs.splitRatio = 0.7
            tabs.tabOrder = [
                .window("win-A"),
                .window("win-orphan"), // no live index → dropped
                .fileExplorer,
                .git,
                .file(keepId),
                .file(deletedId), // filtered out (deleted)
            ]
            tabs.rightSide = [.window("win-A")]
            tabs.selectedRight = .window("win-A")

            let indices = ["win-A": 0, "win-B": 1]
            let layout = LayoutSnapshotMapper.snapshot(
                from: tabs,
                fileBrowser: nil,
                windowIndexForId: { indices[$0] }
            )

            #expect(layout.fileTabs == [SavedFileTab(id: keepId, path: "/proj/a.swift", directoryPath: "/proj")])
            #expect(layout.tabOrder == [
                .window(index: 0),
                .fileExplorer,
                .git,
                .file(id: keepId),
            ])
            #expect(layout.rightSide == [.window(index: 0)])
            #expect(layout.selectedRight == .window(index: 0))
            #expect(layout.selectedLeft == .file(id: keepId))
            #expect(layout.splitRatio == 0.7)
        }

        @Test("Sidebar width is captured when a file browser is present")
        func snapshotCapturesFileTree() {
            let tabs = SessionFileTabsState()
            let fileBrowser = FileBrowserState()
            fileBrowser.sidebarWidth = 321

            let layout = LayoutSnapshotMapper.snapshot(
                from: tabs,
                fileBrowser: fileBrowser,
                windowIndexForId: { _ in nil }
            )

            #expect(layout.fileTree?.sidebarWidth == 321)
        }

        // MARK: - Restore

        @Test("Transient Chromium tabs never replace or restore as existing WebKit tabs")
        func chromiumTabsAreNotRestoredAsWebKit() {
            let webKit = BrowserTab(url: URL(string: "https://example.com")!)
            var chromium = BrowserTab(url: URL(string: "https://swift.org")!)
            chromium.isAgentBrowser = true
            let tabs = SessionFileTabsState()
            tabs.openBrowserTabs = [webKit, chromium]
            tabs.tabOrder = [.browser(webKit.id), .browser(chromium.id)]
            tabs.selectedBrowserTabId = chromium.id
            tabs.rightSide = [.browser(chromium.id)]
            tabs.selectedRight = .browser(chromium.id)

            let layout = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, windowIndexForId: { _ in nil })
            #expect(layout.browserTabs.map(\.id) == [webKit.id])
            #expect(layout.tabOrder == [.browser(id: webKit.id)])
            #expect(layout.selectedLeft == nil)
            #expect(layout.selectedRight == nil)
            #expect(layout.rightSide.isEmpty)

            let restored = SessionFileTabsState()
            LayoutSnapshotMapper.apply(layout, to: restored, fileBrowser: nil,
                windowIdForIndex: { _ in nil }, makeBrowserState: { BrowserTabState(initialURL: $0.url) })
            #expect(restored.openBrowserTabs.map(\.id) == [webKit.id])
            #expect(restored.browserStates[webKit.id] != nil)
            #expect(restored.agentBrowserStates.isEmpty)
        }

        @Test("Apply preserves file tabs and re-maps window indices to live ids, dropping absent ones")
        func applyRemapsWindows() {
            let fileId = UUID()
            let layout = SavedFolderLayout(
                fileTabs: [SavedFileTab(id: fileId, path: "/proj/a.swift", directoryPath: "/proj")],
                tabOrder: [.window(index: 0), .window(index: 1), .file(id: fileId), .fileExplorer],
                rightSide: [.window(index: 0)],
                selectedLeft: .file(id: fileId),
                selectedRight: .window(index: 0),
                splitRatio: 0.99, // out of range → clamped
                fileTree: SavedFileTree(sidebarWidth: 200)
            )

            let tabs = SessionFileTabsState()
            let fileBrowser = FileBrowserState()
            // The restored session only has a window at index 0.
            let idForIndex = [0: "new-0"]
            LayoutSnapshotMapper.apply(
                layout,
                to: tabs,
                fileBrowser: fileBrowser,
                windowIdForIndex: { idForIndex[$0] },
                makeBrowserState: { BrowserTabState(initialURL: $0.url) }
            )

            #expect(tabs.openFileTabs.map(\.id) == [fileId])
            #expect(tabs.openFileTabs.map(\.path) == ["/proj/a.swift"])
            // index 1 has no live window → dropped; index 0 → "new-0".
            #expect(tabs.tabOrder == [.window("new-0"), .file(fileId), .fileExplorer])
            #expect(tabs.rightSide == [.window("new-0")])
            #expect(tabs.selectedFileTabId == fileId)
            #expect(tabs.selectedBrowserTabId == nil)
            #expect(tabs.splitRatio == SplitLayout.maxRatio)
            #expect(fileBrowser.sidebarWidth == 200)
        }

        @Test("Browser tabs round-trip their URLs, ids and live state")
        func browserRoundTrip() {
            let b1 = UUID()
            let b2 = UUID()
            let tabs = SessionFileTabsState()
            tabs.openBrowserTabs = [
                BrowserTab(id: b1, url: URL(string: "https://example.com")!, displayTitle: "Ex"),
                BrowserTab(id: b2, url: URL(string: "https://swift.org")!, parentTabId: b1),
            ]
            tabs.selectedBrowserTabId = b2
            tabs.tabOrder = [.browser(b1), .browser(b2)]

            let layout = LayoutSnapshotMapper.snapshot(
                from: tabs,
                fileBrowser: nil,
                windowIndexForId: { _ in nil }
            )

            let restored = SessionFileTabsState()
            LayoutSnapshotMapper.apply(
                layout,
                to: restored,
                fileBrowser: nil,
                windowIdForIndex: { _ in nil },
                makeBrowserState: { BrowserTabState(initialURL: $0.url) }
            )

            #expect(restored.openBrowserTabs.map(\.id) == [b1, b2])
            #expect(restored.openBrowserTabs.map(\.url.absoluteString) == [
                "https://example.com",
                "https://swift.org",
            ])
            #expect(restored.openBrowserTabs[1].parentTabId == b1)
            #expect(restored.browserStates[b1] != nil)
            #expect(restored.browserStates[b2] != nil)
            #expect(restored.selectedBrowserTabId == b2)
            #expect(restored.tabOrder == [.browser(b1), .browser(b2)])
        }

        @Test("Shared terminals do not suppress private layout restore")
        func sharedTerminalLayoutMergesWithPrivateTabs() {
            let browserId = UUID()
            let saved = SavedFolderLayout(
                browserTabs: [SavedBrowserTab(
                    id: browserId,
                    url: URL(string: "https://example.com")!
                )],
                tabOrder: [.browser(id: browserId)],
                rightSide: [.browser(id: browserId)],
                selectedRight: .browser(id: browserId),
                splitRatio: 0.3
            )
            let shared = SharedTerminalLayout(
                leftWindowId: "@1",
                rightWindowIds: ["@2"],
                selectedRightWindowId: "@2",
                splitRatio: 0.6,
                revision: 1
            )
            let tabs = SessionFileTabsState()
            tabs.applySharedTerminalLayout(shared, liveWindowIds: ["@1", "@2"])

            #expect(tabs.isPrivateWorkbenchEmpty)

            LayoutSnapshotMapper.apply(
                saved,
                to: tabs,
                fileBrowser: nil,
                windowIdForIndex: { _ in nil },
                makeBrowserState: { BrowserTabState(initialURL: $0.url) }
            )
            tabs.applySharedTerminalLayout(shared, liveWindowIds: ["@1", "@2"])

            #expect(tabs.openBrowserTabs.map(\.id) == [browserId])
            #expect(tabs.rightSide == [.browser(browserId), .window("@2")])
            #expect(tabs.selectedRight == .browser(browserId))
            #expect(tabs.splitRatio == 0.6)
            #expect(!tabs.isPrivateWorkbenchEmpty)
        }

        @Test("A private right tab remains selected when the shared terminal collapses")
        func collapsedSharedTerminalSelectsPrivateTab() {
            let browserId = UUID()
            let saved = SavedFolderLayout(
                browserTabs: [SavedBrowserTab(
                    id: browserId,
                    url: URL(string: "https://example.com")!
                )],
                tabOrder: [.browser(id: browserId), .window(index: 1)],
                rightSide: [.browser(id: browserId), .window(index: 1)],
                selectedRight: .window(index: 1)
            )
            let tabs = SessionFileTabsState()
            LayoutSnapshotMapper.apply(
                saved,
                to: tabs,
                fileBrowser: nil,
                windowIdForIndex: { $0 == 1 ? "@2" : nil },
                makeBrowserState: { BrowserTabState(initialURL: $0.url) }
            )

            tabs.applySharedTerminalLayout(
                SharedTerminalLayout(
                    leftWindowId: "@1",
                    rightWindowIds: [],
                    selectedRightWindowId: nil,
                    splitRatio: 0.5,
                    revision: 2
                ),
                liveWindowIds: ["@1", "@2"]
            )

            #expect(tabs.rightSide == [.browser(browserId)])
            #expect(tabs.selectedRight == .browser(browserId))
        }

        @Test("Viewer persistence drops every Host-owned or unsupported tab reference")
        func viewerPrivateLayoutSanitizesGeneralLayout() {
            let browserId = UUID()
            let missingBrowserId = UUID()
            let fileId = UUID()
            let saved = SavedFolderLayout(
                fileTabs: [SavedFileTab(id: fileId, path: "/proj/a.swift", directoryPath: "/proj")],
                browserTabs: [SavedBrowserTab(
                    id: browserId,
                    url: URL(string: "https://example.com")!
                )],
                tabOrder: [
                    .window(index: 1), .fileExplorer, .git, .file(id: fileId),
                    .browser(id: missingBrowserId), .browser(id: browserId),
                ],
                rightSide: [.window(index: 1), .git, .browser(id: missingBrowserId), .browser(id: browserId)],
                selectedLeft: .fileExplorer,
                selectedRight: .git,
                splitRatio: 0.63,
                fileTree: SavedFileTree(sidebarWidth: 240)
            )

            let viewer = LayoutSnapshotMapper.viewerPrivateLayout(from: saved)

            #expect(viewer.fileTabs.isEmpty)
            #expect(viewer.fileTree == nil)
            #expect(viewer.browserTabs == saved.browserTabs)
            #expect(viewer.tabOrder == [.browser(id: browserId)])
            #expect(viewer.rightSide == [.browser(id: browserId)])
            #expect(viewer.selectedLeft == nil)
            #expect(viewer.selectedRight == nil)
            #expect(viewer.splitRatio == 0.63)
        }

        @Test("Legacy Viewer-only stale split sanitizes to a full-width terminal")
        func viewerLegacyStaleSplitCollapses() {
            let saved = SavedFolderLayout(
                tabOrder: [.window(index: 1), .fileExplorer, .git],
                rightSide: [.window(index: 1), .git],
                selectedRight: .git
            )
            let viewer = LayoutSnapshotMapper.viewerPrivateLayout(from: saved)
            let tabs = SessionFileTabsState()

            LayoutSnapshotMapper.apply(
                viewer,
                to: tabs,
                fileBrowser: nil,
                windowIdForIndex: { _ in nil },
                makeBrowserState: { BrowserTabState(initialURL: $0.url) }
            )
            tabs.applySharedTerminalLayout(
                SharedTerminalLayout(leftWindowId: "@1", revision: 3),
                liveWindowIds: ["@1", "@2"]
            )

            #expect(viewer.isEmpty)
            #expect(tabs.rightSide.isEmpty)
            #expect(tabs.selectedRight == nil)
            #expect(!tabs.isSplit)
        }

        // MARK: - Host terminal-layout authority

        @Test("A background session restores its persisted terminal split without opening private tabs")
        func restoresBackgroundTerminalSplit() {
            let browserId = UUID()
            let saved = SavedFolderLayout(
                browserTabs: [SavedBrowserTab(
                    id: browserId,
                    url: URL(string: "https://example.com")!
                )],
                tabOrder: [.window(index: 0), .window(index: 1), .browser(id: browserId)],
                rightSide: [.window(index: 1), .browser(id: browserId)],
                selectedRight: .window(index: 1),
                splitRatio: 0.62
            )

            let request = LayoutSnapshotMapper.sharedTerminalLayoutRequest(
                from: saved,
                sessionName: "background",
                windows: [
                    .init(index: 0, stableId: "@10", isActive: true),
                    .init(index: 1, stableId: "@11"),
                ]
            )

            #expect(request == SetSharedTerminalLayout(
                sessionName: "background",
                leftWindowId: "@10",
                rightWindowIds: ["@11"],
                selectedRightWindowId: "@11",
                splitRatio: 0.62
            ))
        }

        @Test("No persisted split still produces an explicit unsplit Host layout")
        func createsExplicitUnsplitLayout() {
            let request = LayoutSnapshotMapper.sharedTerminalLayoutRequest(
                from: nil,
                sessionName: "fresh",
                windows: [
                    .init(index: 0, stableId: "@20"),
                    .init(index: 1, stableId: "@21", isActive: true),
                ]
            )

            #expect(request == SetSharedTerminalLayout(
                sessionName: "fresh",
                leftWindowId: "@21"
            ))
        }

        // MARK: - Codable

        @Test("SavedFolderLayout survives a JSON round trip")
        func codableRoundTrip() throws {
            let layout = SavedFolderLayout(
                fileTabs: [SavedFileTab(id: UUID(), path: "/p/a", directoryPath: "/p")],
                browserTabs: [SavedBrowserTab(id: UUID(), url: URL(string: "https://x.io")!)],
                tabOrder: [.window(index: 2), .fileExplorer, .git],
                rightSide: [.git],
                selectedLeft: nil,
                selectedRight: .git,
                splitRatio: 0.4,
                fileTree: SavedFileTree(sidebarWidth: 250, expandedPaths: ["/p"])
            )

            let data = try JSONEncoder().encode(layout)
            let decoded = try JSONDecoder().decode(SavedFolderLayout.self, from: data)
            #expect(decoded == layout)
        }
    }
#endif
