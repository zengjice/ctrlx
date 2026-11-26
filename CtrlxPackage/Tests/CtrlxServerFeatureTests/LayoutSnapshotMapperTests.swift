#if os(macOS)
    import CtrlxCommon
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
        @Test("A hidden terminal promoted to the shared right is saved as shared")
        func hiddenTerminalLosesPrivateMarkerWhenShared() {
            let tabs = SessionFileTabsState()
            let browser = BrowserTab(url: URL(fileURLWithPath: "/tmp/private"))
            tabs.openBrowserTabs = [browser]
            tabs.selectedBrowserTabId = browser.id
            tabs.locallySplitTerminalID = "@1"
            let ids = ["@1", "@2", "@3"]
            tabs.applySharedTerminalLayout(
                .init(leftWindowId: "@2", rightWindowIds: ["@3"], selectedRightWindowId: "@3", revision: 1),
                liveWindowIds: ["@2", "@3"], sessionWindowIds: Set(ids)
            )
            let shared = SharedTerminalLayout(leftWindowId: "@2", rightWindowIds: ["@1", "@3"], selectedRightWindowId: "@3", revision: 2)
            tabs.applySharedTerminalLayout(shared, liveWindowIds: ["@2", "@3"], sessionWindowIds: Set(ids))
            #expect(tabs.locallySplitTerminalID == nil)
            let saved = LayoutSnapshotMapper.snapshot(
                from: tabs, fileBrowser: nil, hiddenRightWindowIDs: shared.rightWindowIds, windowIndexForId: { ids.firstIndex(of: $0) }
            )
            #expect(saved.localRightTerminalIndex == nil)
            let request = LayoutSnapshotMapper.sharedTerminalLayoutRequest(
                from: saved, sessionName: "work", windows: ids.enumerated().map { .init(index: $0.offset, stableId: $0.element) }
            )
            #expect(request?.leftWindowId == "@2")
            #expect(Set(request?.rightWindowIds ?? []) == ["@1", "@3"])
        }

        @Test("A hidden local-right terminal remains in a saved layout and restores to the right")
        func hiddenLocalTerminalRoundTrip() throws {
            let tabs = SessionFileTabsState()
            let browser = BrowserTab(url: URL(fileURLWithPath: "/tmp/private"))
            tabs.openBrowserTabs = [browser]
            tabs.selectedBrowserTabId = browser.id
            tabs.locallySplitTerminalID = "@1"
            tabs.rightSide = [.window("@2"), .window("@3")]
            let ids = ["@1", "@2", "@3"]
            let snapshot = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil) { ids.firstIndex(of: $0) }
            let saved = try JSONDecoder().decode(SavedFolderLayout.self, from: JSONEncoder().encode(snapshot))
            #expect(saved.localRightTerminalIndex == 0)
            #expect(Set(saved.rightSide) == Set((0..<3).map(SavedTabRef.window(index:))))
            let restored = SessionFileTabsState()
            LayoutSnapshotMapper.apply(
                saved, to: restored, fileBrowser: nil, windowIdForIndex: { ids.indices.contains($0) ? ids[$0] : nil },
                makeBrowserState: { BrowserTabState(initialURL: $0.url) }
            )
            #expect(restored.locallySplitTerminalID == "@1")
            #expect(restored.rightSideWindowIds == Set(ids))
        }

        @Test("A split restores one terminal when two saved indices link to it")
        func restoresLinkedWindowOnce() {
            let layout = SavedFolderLayout(rightSide: [.window(index: 1), .window(index: 3)], selectedRight: .window(index: 3))
            let request = LayoutSnapshotMapper.sharedTerminalLayoutRequest(
                from: layout, sessionName: "work", windows: [
                    .init(index: 0, stableId: "@1"), .init(index: 1, stableId: "@2"), .init(index: 3, stableId: "@2"),
                ]
            )
            #expect(request?.leftWindowId == "@1")
            #expect(request?.rightWindowIds == ["@2"])
            #expect(request?.selectedRightWindowId == "@2")
        }

        @Test("Viewer resize preserves a Host terminal split beside Host Files")
        func viewerResizePreservesHostFilesSplit() {
            let files = HostFileTab(sessionName: "work", windowID: "@1", sourcePaneID: "%1", initialDirectory: "/tmp")
            let tabs = SessionFileTabsState()
            tabs.openFileTabs = [.init(id: files.id, path: "Files", directoryPath: "/tmp", isDirectory: true)]
            tabs.directoryTabs[files.id] = FileBrowserTab(hostTab: files)
            tabs.selectedFileTabId = files.id
            tabs.rightSide = [.window("@1")]
            tabs.locallySplitTerminalID = "@1"
            let saved = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil) { $0 == "@1" ? 0 : nil }
            #expect(saved.fileTabs.isEmpty)

            let shared = SharedTerminalLayout(leftWindowId: "@1", splitRatio: 0.56, revision: 2)
            let resized = LayoutSnapshotMapper.applyingSharedTerminalLayout(shared, previousLeftWindowID: "@1", indices: ["@1": [0]], to: saved)
            #expect(resized.localRightTerminalIndex == 0)
            #expect(resized.rightSide == [.window(index: 0)])
            #expect(resized.splitRatio == 0.56)
            LayoutSnapshotMapper.apply(
                resized, to: tabs, fileBrowser: nil, windowIdForIndex: { $0 == 0 ? "@1" : nil },
                makeBrowserState: { BrowserTabState(initialURL: $0.url) }
            )
            tabs.applySharedTerminalLayout(shared, liveWindowIds: ["@1"])
            #expect(tabs.selectedFileTabId == files.id)
            #expect(tabs.rightSideWindowIds == ["@1"])
        }

        @Test("A browser order edit retains a terminal anchor even if the folder has never saved it", arguments: [false, true])
        func browserOrderKeepsTerminalAnchor(terminalWasSaved: Bool) {
            let tabs = SessionFileTabsState()
            let browser = BrowserTab(url: URL(fileURLWithPath: "/a/page"))
            let other = SavedBrowserTab(id: UUID(), url: URL(fileURLWithPath: "/a/other"))
            let ref = SavedTabRef.browser(id: browser.id)
            let unrelated = SavedTabRef.browser(id: other.id)
            let terminal = SavedTabRef.window(index: 3)
            tabs.openBrowserTabs = [browser]
            tabs.tabOrder = [.browser(browser.id), .window("@2")]
            let saved = SavedFolderLayout(
                browserTabs: [.init(id: browser.id, url: browser.url), other],
                tabOrder: terminalWasSaved ? [terminal, unrelated, ref] : [unrelated, ref]
            )
            let draft = LayoutSnapshotMapper.privateTabAdditions([.browser(browser.id)], from: tabs) { $0 == "@2" ? 3 : nil }
            let reordered = LayoutSnapshotMapper.applyingPrivateTabOrder(from: draft, to: saved)
            #expect(reordered.tabOrder == (terminalWasSaved ? [ref, unrelated, terminal] : [unrelated, ref, terminal]))
        }

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

        @Test("A layout captured before the tab bar appears already follows shared browser order")
        func initialSnapshotUsesSharedBrowserOrder() {
            let tabs = SessionFileTabsState()
            var first = BrowserTab(url: URL(fileURLWithPath: "/first"))
            var second = BrowserTab(url: URL(fileURLWithPath: "/second"))
            first.isAgentBrowser = true
            second.isAgentBrowser = true
            tabs.openBrowserTabs = [first, second]
            let shared = SharedWorkbenchTabLayout.Snapshot(
                ids: [.browser(first.id): .browser(first.id), .browser(second.id): .browser(second.id)],
                layout: .init(order: [.browser(second.id), .browser(first.id)], revision: 1)
            )
            let visible = tabs.localPresentedTabOrder(windows: [], panes: [], layout: shared)
            let initial = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, tabOrder: visible, windowIndexForId: { _ in nil })
            tabs.recordVisibleTabOrder(visible)
            let afterMount = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, windowIndexForId: { _ in nil })

            #expect(initial.linkedTabOrder == [.browser(second.id), .browser(first.id)])
            #expect(initial.isSameWorkbench(as: afterMount))
        }

        @Test("An excluded editor becoming unavailable leaves the destination layout unchanged")
        func excludedEditorDeletionDoesNotChangeLayout() {
            let tabs = SessionFileTabsState()
            let file = OpenFileTab(path: "/b/other.md", directoryPath: "/b")
            tabs.openFileTabs = [file]
            tabs.tabOrder = [.window("@1"), .file(file.id)]
            tabs.selectedFileTabId = file.id
            tabs.tabFolders[.file(file.id)] = ["/a"]
            let foreign = tabs.tabsOutsideFolder("/b")
            let indexForWindow: (String) -> Int? = { _ in 0 }
            let before = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, windowIndexForId: indexForWindow)
            tabs.openFileTabs[0].isDeleted = true
            let after = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, excluding: foreign, windowIndexForId: indexForWindow)

            #expect(before.fileTabs.map(\.id) == [file.id])
            #expect(after.fileTabs.isEmpty)
            #expect(LayoutSnapshotMapper.excluding(foreign, from: before, windowIndexForId: indexForWindow).isSameWorkbench(as: after))
        }

        @Test("A projected browser child keeps its parent only when the parent is also saved")
        func browserParentBelongsToSnapshot() {
            let tabs = SessionFileTabsState()
            let parent = BrowserTab(url: URL(fileURLWithPath: "/parent"))
            let child = BrowserTab(url: URL(fileURLWithPath: "/child"), parentTabId: parent.id)
            tabs.openBrowserTabs = [parent, child]
            let layout = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, windowIndexForId: { _ in nil })
            #expect(layout.browserTabs.last?.parentId == parent.id)
            let projected = LayoutSnapshotMapper.excluding([.browser(parent.id)], from: layout, windowIndexForId: { _ in nil })
            #expect(projected.browserTabs.map(\.id) == [child.id])
            #expect(projected.browserTabs.first?.parentId == nil)
        }

        @Test("Adding a private browser tab preserves a parent already in the destination folder")
        func browserAdditionKeepsSavedParent() {
            let tabs = SessionFileTabsState()
            let parent = BrowserTab(url: URL(fileURLWithPath: "/parent"))
            let child = BrowserTab(url: URL(fileURLWithPath: "/child"), parentTabId: parent.id)
            tabs.openBrowserTabs = [parent, child]
            let parentLayout = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, excluding: [.browser(child.id)], windowIndexForId: { _ in nil })
            let addition = LayoutSnapshotMapper.privateTabAdditions([.browser(child.id)], from: tabs)
            let combined = LayoutSnapshotMapper.addingEarlyTabs(from: addition, to: parentLayout)
            let result = LayoutSnapshotMapper.excluding([], from: combined, windowIndexForId: { _ in nil })

            #expect(result.browserTabs.map(\.id) == [parent.id, child.id])
            #expect(result.browserTabs.last?.parentId == parent.id)
            #expect(result.tabOrder.contains(.browser(id: child.id)))
        }

        @Test("Browser edits update only the addressed saved tabs and remove closed references")
        func browserEditsPreserveFolderLayout() throws {
            let parent = UUID()
            let child = UUID()
            let unrelated = UUID()
            let oldURL = URL(fileURLWithPath: "/old")
            let newURL = URL(fileURLWithPath: "/new")
            let childRef = SavedTabRef.browser(id: child)
            let terminal = SavedTabRef.window(index: 1)
            let saved = SavedFolderLayout(
                browserTabs: [
                    .init(id: parent, url: oldURL, displayTitle: nil, parentId: nil),
                    .init(id: child, url: oldURL, displayTitle: "Child", parentId: parent),
                    .init(id: unrelated, url: oldURL, displayTitle: nil, parentId: nil),
                ],
                tabOrder: [terminal, childRef, .browser(id: parent), .browser(id: unrelated)],
                linkedTabOrder: [.browser(child), .browser(parent), .browser(unrelated)],
                rightSide: [terminal, childRef], selectedRight: childRef, splitRatio: 0.70
            )
            let updated = LayoutSnapshotMapper.applyingBrowserEdits([child: .navigate(newURL)], to: saved)
            let expected = try #require(updated.browserTabs.first { $0.id == child })
            #expect(expected.url == newURL && expected.parentId == parent && expected.displayTitle == "Child")
            #expect(updated.rightSide == saved.rightSide && updated.selectedRight == childRef)
            #expect(updated.browserTabs.last?.url == oldURL)

            let closed = LayoutSnapshotMapper.applyingBrowserEdits([child: .close], to: updated)
            #expect(closed.browserTabs.map(\.id) == [parent, unrelated])
            #expect(closed.tabOrder == saved.tabOrder.filter { $0 != childRef })
            #expect(closed.linkedTabOrder == [.browser(parent), .browser(unrelated)])
            #expect(closed.rightSide == [terminal] && closed.selectedRight == nil && closed.splitRatio == 0.70)
        }

        @Test("Editor path exclusions remove the saved tab and its references")
        func excludedEditorsLeaveNoSavedReferences() {
            let notes = SavedFileTab(id: UUID(), path: "/a/notes.md", directoryPath: "/a")
            let keep = SavedFileTab(id: UUID(), path: "/a/keep.md", directoryPath: "/a")
            let removed = SavedTabRef.file(id: notes.id)
            let retained = SavedTabRef.file(id: keep.id)
            let saved = SavedFolderLayout(
                fileTabs: [notes, keep], tabOrder: [retained, removed], linkedTabOrder: [.file(notes.id), .file(keep.id)],
                rightSide: [removed], selectedLeft: retained, selectedRight: removed, splitRatio: 0.71
            )
            let result = LayoutSnapshotMapper.excludingEditors(at: [notes.path], from: saved)

            #expect(result.fileTabs == [keep])
            #expect(result.tabOrder == [retained])
            #expect(result.linkedTabOrder == [.file(keep.id)])
            #expect(result.selectedLeft == retained && result.selectedRight == nil)
            #expect(result.rightSide.isEmpty && result.splitRatio == 0.71)
        }

        @Test("Files opened before restoration supplement the saved folder without replacing its split")
        func earlyFilesPreserveSavedSplit() {
            let old = SavedFileTab(id: UUID(), path: "/a/old.md", directoryPath: "/a")
            let new = SavedFileTab(id: UUID(), path: "/a/new.md", directoryPath: "/a")
            let right = SavedTabRef.window(index: 1)
            let saved = SavedFolderLayout(
                fileTabs: [old], tabOrder: [.window(index: 0), right, .file(id: old.id)],
                rightSide: [right], selectedRight: right, splitRatio: 0.70
            )
            var duplicate = old
            duplicate.id = UUID()
            let draft = SavedFolderLayout(
                fileTabs: [duplicate, new], tabOrder: [.file(id: duplicate.id), .file(id: new.id)],
                selectedLeft: .file(id: duplicate.id), splitRatio: 0.35
            )
            let merged = LayoutSnapshotMapper.addingEarlyTabs(from: draft, to: saved)
            #expect(merged.fileTabs == [old, new])
            #expect(merged.tabOrder == saved.tabOrder + [.file(id: new.id)])
            #expect(merged.selectedLeft == .file(id: old.id))
            #expect(merged.rightSide == [right] && merged.selectedRight == right)
            #expect(merged.splitRatio == 0.70)
        }

        @Test("A split edit preserves the destination folder's saved private tabs", arguments: [false, true])
        func splitEditPreservesPrivateTabs(updatesPlacement: Bool) {
            let file = SavedFileTab(id: UUID(), path: "/b/notes.md", directoryPath: "/b")
            let browser = SavedBrowserTab(id: UUID(), url: URL(fileURLWithPath: "/page"), displayTitle: nil, parentId: nil)
            let fileRef = SavedTabRef.file(id: file.id)
            let browserRef = SavedTabRef.browser(id: browser.id)
            let oldRight = SavedTabRef.window(index: 1)
            let newRight = SavedTabRef.window(index: 2)
            let saved = SavedFolderLayout(
                fileTabs: [file], browserTabs: [browser], tabOrder: [.window(index: 0), oldRight, newRight, fileRef, browserRef],
                rightSide: [oldRight, browserRef], selectedLeft: fileRef, selectedRight: oldRight, splitRatio: 0.70
            )
            let draft = SavedFolderLayout(rightSide: [newRight], selectedRight: newRight, splitRatio: 0.56)
            let result = LayoutSnapshotMapper.mergingFolderEdit(draft, into: saved, updatesTerminalPlacement: updatesPlacement, splitRatio: 0.56)

            #expect(result.fileTabs == [file] && result.browserTabs == [browser])
            #expect(result.tabOrder == saved.tabOrder && result.selectedLeft == fileRef)
            #expect(Set(result.rightSide) == [browserRef, updatesPlacement ? newRight : oldRight])
            #expect(result.selectedRight == (updatesPlacement ? newRight : oldRight))
            #expect(result.splitRatio == 0.56)
        }

        // MARK: - Restore

        @Test("Reordering reopened editors uses their saved IDs in both orders")
        func reordersReopenedEditors() {
            let first = SavedFileTab(id: UUID(), path: "/b/first.md", directoryPath: "/b")
            let second = SavedFileTab(id: UUID(), path: "/b/second.md", directoryPath: "/b")
            let reopenedFirst = SavedFileTab(id: UUID(), path: first.path, directoryPath: first.directoryPath)
            let reopenedSecond = SavedFileTab(id: UUID(), path: second.path, directoryPath: second.directoryPath)
            let saved = SavedFolderLayout(
                fileTabs: [first, second], tabOrder: [.file(id: first.id), .file(id: second.id)],
                linkedTabOrder: [.file(first.id), .file(second.id)]
            )
            let draft = SavedFolderLayout(
                fileTabs: [reopenedFirst, reopenedSecond], tabOrder: [.file(id: reopenedSecond.id), .file(id: reopenedFirst.id)],
                linkedTabOrder: [.file(reopenedSecond.id), .file(reopenedFirst.id)]
            )
            let edited = LayoutSnapshotMapper.mergingFolderEdit(
                draft, into: saved, updatesTerminalPlacement: false, splitRatio: nil, updatesTabOrder: true
            )
            #expect(edited.fileTabs == [first, second])
            #expect(edited.tabOrder == [.file(id: second.id), .file(id: first.id)])
            #expect(edited.linkedTabOrder == [.file(second.id), .file(first.id)])
        }

        @Test("Editing a recovered layout preserves unseen tabs and saves explicit order and terminal choices")
        func mergeRecoveredWorkbenchEdits() {
            let first = SavedBrowserTab(id: UUID(), url: URL(fileURLWithPath: "/first"))
            let second = SavedBrowserTab(id: UUID(), url: URL(fileURLWithPath: "/second"))
            let unseen = SavedFileTab(id: UUID(), path: "/notes", directoryPath: "/")
            let firstRef = SavedTabRef.browser(id: first.id)
            let secondRef = SavedTabRef.browser(id: second.id)
            let unseenRef = SavedTabRef.file(id: unseen.id)
            let left = SavedTabRef.window(index: 0)
            let right = SavedTabRef.window(index: 1)
            let saved = SavedFolderLayout(
                fileTabs: [unseen], browserTabs: [first, second], tabOrder: [left, firstRef, unseenRef, secondRef, right],
                linkedTabOrder: [.browser(first.id), .file(unseen.id), .browser(second.id)],
                rightSide: [right, secondRef], selectedLeft: firstRef, selectedRight: secondRef
            )
            let draft = SavedFolderLayout(
                browserTabs: [second, first], tabOrder: [left, secondRef, firstRef, right],
                linkedTabOrder: [.browser(second.id), .browser(first.id)], rightSide: [right, secondRef], selectedRight: right
            )

            let edited = LayoutSnapshotMapper.mergingFolderEdit(
                draft, into: saved, updatesTerminalPlacement: false, splitRatio: nil, updatesTabOrder: true, terminalSelectionSides: [false, true]
            )
            #expect(edited.tabOrder == [left, secondRef, unseenRef, firstRef, right])
            #expect(edited.linkedTabOrder == [.browser(second.id), .file(unseen.id), .browser(first.id)])
            #expect(edited.selectedLeft == nil && edited.selectedRight == right)
            #expect(edited.fileTabs == [unseen])
        }

        @Test("Restoring the current folder merges saved files with an editor opened during startup")
        func earlyEditorStaysOpenWithSavedFiles() {
            let tabs = SessionFileTabsState()
            let early = OpenFileTab(path: "/a/early.md", directoryPath: "/a", origin: .terminalWindow("@1"))
            let old = SavedFileTab(id: UUID(), path: "/a/old.md", directoryPath: "/a")
            tabs.openFileTabs = [early]
            tabs.tabFolders[.file(early.id)] = ["/a"]
            tabs.tabOrder = [.file(early.id)]
            tabs.selectedFileTabId = early.id
            let saved = SavedFolderLayout(fileTabs: [old], tabOrder: [.file(id: old.id)], selectedLeft: .file(id: old.id))

            LayoutSnapshotMapper.apply(
                saved, to: tabs, fileBrowser: nil, restoringFolder: "/a",
                windowIdForIndex: { _ in nil }, makeBrowserState: { BrowserTabState(initialURL: $0.url) }
            )
            #expect(tabs.openFileTabs.map(\.id) == [old.id, early.id])
            #expect(tabs.openFileTabs.last == early)
            #expect(tabs.selectedFileTabId == early.id)

            let later = OpenFileTab(path: "/a/later.md", directoryPath: "/a")
            tabs.openFileTabs.append(later)
            let next = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, windowIndexForId: { _ in nil })
            #expect(next.fileTabs.map(\.id) == [old.id, early.id, later.id])
        }

        @Test("Restoring a folder keeps Git open without replacing its saved file selection")
        func foreignGitDoesNotReplaceSavedFiles() {
            let tabs = SessionFileTabsState()
            tabs.selectLeftGit()
            tabs.tabFolders[.git] = ["/a"]
            let draft = SavedFileTab(id: UUID(), path: "/b/draft.md", directoryPath: "/b")
            let saved = SavedFolderLayout(fileTabs: [draft], tabOrder: [.file(id: draft.id)], selectedLeft: .file(id: draft.id))
            let foreign = tabs.tabsOutsideFolder("/b")

            LayoutSnapshotMapper.apply(
                saved, to: tabs, fileBrowser: nil, includeGit: false, restoringFolder: "/b",
                windowIdForIndex: { _ in nil }, makeBrowserState: { BrowserTabState(initialURL: $0.url) }
            )
            #expect(tabs.isGitOpen)
            #expect(tabs.selectedFileTabId == draft.id)
            let snapshot = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, excluding: foreign, windowIndexForId: { _ in nil })
            #expect(snapshot.tabOrder == saved.tabOrder)
            #expect(snapshot.fileTabs == saved.fileTabs)
        }

        @Test("A saved file reuses the open editor at its path and keeps references to that editor", arguments: [false, true])
        func mergingSamePathReusesLiveEditor(onRight: Bool) {
            let live = OpenFileTab(path: "/b/draft.md", directoryPath: "/b", origin: .terminalWindow("@1"))
            let saved = SavedFileTab(id: UUID(), path: live.path, directoryPath: live.directoryPath)
            let duplicate = SavedFileTab(id: UUID(), path: live.path, directoryPath: live.directoryPath)
            let tabs = SessionFileTabsState()
            tabs.openFileTabs = [live]
            tabs.tabFolders[.file(live.id)] = ["/a"]
            if onRight {
                tabs.rightSide.insert(.file(live.id))
            } else {
                tabs.selectedFileTabId = live.id
            }
            LayoutSnapshotMapper.apply(
                .init(
                    fileTabs: [saved, duplicate], tabOrder: [.window(index: 0), .file(id: saved.id), .file(id: duplicate.id), .window(index: 1)],
                    linkedTabOrder: [.file(saved.id), .file(duplicate.id)], rightSide: [.file(id: saved.id)], selectedRight: .file(id: duplicate.id)
                ), to: tabs, fileBrowser: nil, restoringFolder: "/b",
                windowIdForIndex: { "@\($0 + 1)" }, makeBrowserState: { BrowserTabState(initialURL: $0.url) }
            )
            #expect(tabs.openFileTabs == [live])
            #expect(tabs.tabOrder == [.window("@1"), .file(live.id), .window("@2")])
            #expect(tabs.rightSide.contains(.file(live.id)) == onRight)
            #expect(tabs.selectedFileTabId == (onRight ? nil : live.id))
            #expect(tabs.selectedRight == (onRight ? .file(live.id) : nil))
            #expect(tabs.tabsOutsideFolder("/a").isEmpty)
            #expect(tabs.tabsOutsideFolder("/b").isEmpty)
            #expect(tabs.tabsOutsideFolder("/c") == [.file(live.id)])
            let snapshot = LayoutSnapshotMapper.snapshot(
                from: tabs, fileBrowser: nil, excluding: tabs.tabsOutsideFolder("/b"), windowIndexForId: { _ in nil }
            )
            #expect(snapshot.fileTabs.map(\.id) == [live.id])
        }

        @Test("Deduplicating restored editors selects the surviving editor only on its final side")
        func duplicateRestoredEditorsCannotBeSelectedOnBothSides() {
            let first = SavedFileTab(id: UUID(), path: "/b/draft.md", directoryPath: "/b")
            let second = SavedFileTab(id: UUID(), path: first.path, directoryPath: first.directoryPath)
            let layout = SavedFolderLayout(
                fileTabs: [first, second], tabOrder: [.file(id: first.id), .file(id: second.id)],
                rightSide: [.file(id: second.id)], selectedLeft: .file(id: first.id), selectedRight: .file(id: second.id)
            )
            let tabs = SessionFileTabsState()
            LayoutSnapshotMapper.apply(layout, to: tabs, fileBrowser: nil, windowIdForIndex: { _ in nil }, makeBrowserState: { BrowserTabState(initialURL: $0.url) })

            #expect(tabs.openFileTabs.map(\.id) == [first.id])
            #expect(tabs.rightSide == [.file(first.id)])
            #expect(tabs.selectedRight == .file(first.id))
            #expect(tabs.selectedFileTabId == nil)
        }

        @Test("Comparing two live layouts treats right-pane membership as unordered")
        func rightSideOrderIsNotAnEdit() {
            let layout = SavedFolderLayout(rightSide: [.window(index: 0), .window(index: 1)], selectedRight: .window(index: 1))
            var refreshed = layout
            refreshed.rightSide.reverse()
            #expect(layout.isSameWorkbench(as: refreshed))
            refreshed.selectedRight = .window(index: 0)
            #expect(!layout.isSameWorkbench(as: refreshed))
        }

        @Test("A folder restore retains live tabs opened during startup without saving them to another folder")
        func privateStartupTabsStayWithTheirFolder() throws {
            let notes = OpenFileTab(path: "/a/notes.md", directoryPath: "/a")
            let draft = SavedFileTab(id: UUID(), path: "/b/draft.md", directoryPath: "/b")
            let browser = try BrowserTab(url: #require(URL(string: "https://example.com")))
            let page = BrowserTabState(initialURL: browser.url)
            let tabs = SessionFileTabsState()
            tabs.openFileTabs = [notes]
            tabs.openBrowserTabs = [browser]
            tabs.browserStates[browser.id] = page
            tabs.tabFolders = [.file(notes.id): ["/a"], .browser(browser.id): ["/a"]]
            tabs.tabOrder = [.file(notes.id), .browser(browser.id)]
            tabs.selectedFileTabId = notes.id
            tabs.rightSide = [.browser(browser.id)]
            tabs.selectedRight = .browser(browser.id)
            tabs.splitRatio = 0.31

            let foreign = tabs.tabsOutsideFolder("/b")
            LayoutSnapshotMapper.apply(
                .init(fileTabs: [draft], tabOrder: [.file(id: draft.id)], selectedLeft: .file(id: draft.id), splitRatio: 0.65),
                to: tabs, fileBrowser: nil, restoringFolder: "/b",
                windowIdForIndex: { _ in nil }, makeBrowserState: { BrowserTabState(initialURL: $0.url) }
            )
            #expect(tabs.openFileTabs.map(\.id) == [draft.id, notes.id])
            #expect(tabs.browserStates[browser.id] === page)
            #expect(tabs.selectedFileTabId == draft.id)
            #expect(tabs.selectedRight == nil)
            #expect(tabs.rightSide == [.browser(browser.id)])
            #expect(tabs.splitRatio == 0.65)

            let saved = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, excluding: foreign, windowIndexForId: { _ in nil })
            #expect(saved.fileTabs == [draft])
            #expect(saved.browserTabs.isEmpty)
            #expect(saved.tabOrder == [.file(id: draft.id)])
            #expect(saved.selectedLeft == .file(id: draft.id))
            #expect(saved.rightSide.isEmpty)
            #expect(saved.selectedRight == nil)

            let savedA = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, excluding: tabs.tabsOutsideFolder("/a"), windowIndexForId: { _ in nil })
            #expect(savedA.fileTabs.map(\.id) == [notes.id])
        }

        @Test("Folder seeding omits Git while workspace recovery preserves it", arguments: [false, true])
        func gitRestorePolicy(includeGit: Bool) {
            let layout = SavedFolderLayout(
                tabOrder: [.window(index: 0), .git],
                rightSide: [.git],
                selectedRight: .git
            )
            let tabs = SessionFileTabsState()
            LayoutSnapshotMapper.apply(
                layout, to: tabs, fileBrowser: nil, includeGit: includeGit,
                windowIdForIndex: { _ in "@1" },
                makeBrowserState: { BrowserTabState(initialURL: $0.url) }
            )
            #expect(tabs.isGitOpen == includeGit)
            #expect(tabs.rightSide.contains(.git) == includeGit)
            #expect(tabs.selectedRight == (includeGit ? .git : nil))
            tabs.closeGit()
            let saved = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, windowIndexForId: { _ in 0 })
            #expect(!saved.tabOrder.contains(.git))
            #expect(!saved.rightSide.contains(.git))
            #expect(saved.selectedRight == nil)
        }

        @Test("Transient Chromium tabs never replace or restore as existing WebKit tabs")
        func chromiumTabsAreNotRestoredAsWebKit() throws {
            let webKit = try BrowserTab(url: #require(URL(string: "https://example.com")))
            var chromium = try BrowserTab(url: #require(URL(string: "https://swift.org")))
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
            LayoutSnapshotMapper.apply(
                layout,
                to: restored,
                fileBrowser: nil,
                windowIdForIndex: { _ in nil },
                makeBrowserState: { BrowserTabState(initialURL: $0.url) }
            )
            #expect(restored.openBrowserTabs.map(\.id) == [webKit.id])
            #expect(restored.browserStates[webKit.id] != nil)
            #expect(restored.agentBrowserStates.isEmpty)
        }

        @Test("Host Browser and Simulator tabs coexist with restored private files", arguments: [false, true])
        func hostResourceDoesNotSuppressPrivateRestore(isSimulator: Bool) throws {
            var resource = try BrowserTab(url: #require(URL(string: "https://example.com")))
            resource.isSimulator = isSimulator
            resource.isAgentBrowser = !isSimulator
            let tabs = SessionFileTabsState()
            tabs.openBrowserTabs = [resource]
            tabs.tabOrder = [.browser(resource.id)]
            tabs.rightSide = [.browser(resource.id)]
            tabs.selectedRight = .browser(resource.id)
            #expect(tabs.isPrivateWorkbenchEmpty)

            let draft = SavedFileTab(id: UUID(), path: "/b/draft.md", directoryPath: "/b")
            let layout = SavedFolderLayout(fileTabs: [draft], tabOrder: [.file(id: draft.id)], selectedLeft: .file(id: draft.id))
            LayoutSnapshotMapper.apply(layout, to: tabs, fileBrowser: nil, windowIdForIndex: { _ in nil }, makeBrowserState: { BrowserTabState(initialURL: $0.url) })

            #expect(tabs.openFileTabs.map(\.id) == [draft.id])
            #expect(tabs.selectedFileTabId == draft.id)
            #expect(tabs.openBrowserTabs == [resource])
            #expect(tabs.selectedRight == .browser(resource.id))
            let saved = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, windowIndexForId: { _ in nil })
            #expect(saved.browserTabs.isEmpty)
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
        func browserRoundTrip() throws {
            let b1 = UUID()
            let b2 = UUID()
            let tabs = SessionFileTabsState()
            tabs.openBrowserTabs = try [
                BrowserTab(id: b1, url: #require(URL(string: "https://example.com")), displayTitle: "Ex"),
                BrowserTab(id: b2, url: #require(URL(string: "https://swift.org")), parentTabId: b1),
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
                restoringFolder: "/a",
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
            #expect(restored.tabsOutsideFolder("/a").isEmpty)
            let otherFolder = LayoutSnapshotMapper.snapshot(from: restored, fileBrowser: nil, excluding: restored.tabsOutsideFolder("/b"), windowIndexForId: { _ in nil })
            #expect(otherFolder.browserTabs.isEmpty)
            #expect(restored.browserStates[b2] != nil)
            #expect(restored.selectedBrowserTabId == b2)
            #expect(restored.tabOrder == [.browser(b1), .browser(b2)])
        }

        @Test("Host Files do not suppress private restore or lose their live presentation", arguments: [false, true], [nil, "host"] as [String?])
        func hostFilesMergeWithPrivateRestore(onRight: Bool, host: String?) throws {
            let manager = DetachedTerminalWindows()
            let hostFile = HostFileTab(sessionName: "work", windowID: "@1", sourcePaneID: "%1", initialDirectory: "/host")
            manager.syncFileTabs(hostID: host, descriptors: [hostFile], sessionWindows: ["work": ["@1"]])
            let tabs = manager.mainTabs.tabs(hostID: host, session: "work")
            let live = try #require(tabs.directoryTabs[hostFile.id])
            live.navigate("/host/selected")
            tabs.tabOrder = [.file(hostFile.id)]
            if onRight {
                tabs.rightSide = [.file(hostFile.id)]
                tabs.selectedRight = .file(hostFile.id)
            } else {
                tabs.selectedFileTabId = hostFile.id
            }
            tabs.splitRatio = 0.7
            #expect(tabs.isPrivateWorkbenchEmpty)

            let legacy = FileBrowserTab(path: "/private")
            let saved = SavedFolderLayout(
                fileTabs: [.init(id: legacy.id, path: "Files", directoryPath: "", browser: legacy.snapshot)],
                tabOrder: [.file(id: legacy.id)],
                selectedLeft: .file(id: legacy.id), splitRatio: 0.4
            )
            LayoutSnapshotMapper.apply(saved, to: tabs, fileBrowser: nil, windowIdForIndex: { _ in nil }, makeBrowserState: { BrowserTabState(initialURL: $0.url) })

            #expect(!tabs.isPrivateWorkbenchEmpty)
            #expect(tabs.directoryTabs[hostFile.id] === live)
            #expect(live.path == "/host/selected")
            #expect(tabs.openFileTabs.map(\.id) == [legacy.id, hostFile.id])
            #expect(tabs.tabOrder == [.file(legacy.id), .file(hostFile.id)])
            #expect(tabs.selectedFileTabId == (onRight ? legacy.id : hostFile.id))
            #expect(tabs.selectedRight == (onRight ? .file(hostFile.id) : nil))
            #expect(tabs.splitRatio == (onRight ? 0.7 : 0.4))
            let resaved = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, windowIndexForId: { _ in nil })
            #expect(resaved.fileTabs.map(\.id) == [legacy.id])
            #expect(resaved.rightSide.isEmpty)
        }

        @Test("Shared terminals do not suppress private layout restore")
        func sharedTerminalLayoutMergesWithPrivateTabs() throws {
            let browserId = UUID()
            let saved = try SavedFolderLayout(
                browserTabs: [SavedBrowserTab(
                    id: browserId,
                    url: #require(URL(string: "https://example.com"))
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
        func collapsedSharedTerminalSelectsPrivateTab() throws {
            let browserId = UUID()
            let saved = try SavedFolderLayout(
                browserTabs: [SavedBrowserTab(
                    id: browserId,
                    url: #require(URL(string: "https://example.com"))
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
        func viewerPrivateLayoutSanitizesGeneralLayout() throws {
            let browserId = UUID()
            let missingBrowserId = UUID()
            let fileId = UUID()
            let saved = try SavedFolderLayout(
                fileTabs: [SavedFileTab(id: fileId, path: "/proj/a.swift", directoryPath: "/proj")],
                browserTabs: [SavedBrowserTab(
                    id: browserId,
                    url: #require(URL(string: "https://example.com"))
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
        func restoresBackgroundTerminalSplit() throws {
            let browserId = UUID()
            let saved = try SavedFolderLayout(
                browserTabs: [SavedBrowserTab(
                    id: browserId,
                    url: #require(URL(string: "https://example.com"))
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
            let layout = try SavedFolderLayout(
                fileTabs: [SavedFileTab(id: UUID(), path: "/p/a", directoryPath: "/p")],
                browserTabs: [SavedBrowserTab(id: UUID(), url: #require(URL(string: "https://x.io")))],
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
