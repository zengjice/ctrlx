#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite("Host shared terminal layout store")
    struct SharedTerminalLayoutManagerTests {
        private func makeManager(layoutStore: LayoutStore = .inMemory(), tmuxService: TmuxService? = nil) -> MirrorWindowManager {
            withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[ProcessRunner.self] = .previewValue
                $0[LoginItemService.self] = .previewValue
                $0[LayoutStore.self] = layoutStore
            } operation: {
                let tmux = tmuxService ?? TmuxService()
                let control = TmuxControlClientManager()
                return MirrorWindowManager(
                    settings: AppSettings(),
                    tmuxService: tmux,
                    paneStreamManager: PaneStreamManager(
                        tmuxService: tmux,
                        controlClientManager: control
                    ),
                    editorSessionManager: EditorSessionManager()
                )
            }
        }

        private func pane(
            id: String,
            windowId: String,
            windowIndex: Int,
            sessionName: String = "coding",
            currentPath: String = "/tmp",
            isWindowActive: Bool = false,
            identity: WorkspacePaneIdentity? = nil,
            serverID: String? = nil
        ) -> PaneInfo {
            PaneInfo(
                paneId: id,
                target: "\(sessionName):\(windowIndex).0",
                sessionName: sessionName,
                windowIndex: windowIndex,
                tmuxWindowId: windowId,
                paneIndex: 0,
                command: "zsh",
                currentPath: currentPath,
                width: 80,
                height: 24,
                isActive: true,
                isWindowActive: isWindowActive,
                workspaceIdentity: identity,
                tmuxServerID: serverID
            )
        }

        @Test("A Viewer can save terminal placement before the Host opens the workbench")
        func viewerPersistsBackgroundLayout() async throws {
            let key = try SavedFolderRecord.Key(host: SavedFolderRecord.localHost, folder: #require(LayoutFolderKey.canonicalize("/tmp")))
            let browser = SavedBrowserTab(id: UUID(), url: URL(fileURLWithPath: "/page"))
            let browserRef = SavedTabRef.browser(id: browser.id)
            let store = LayoutStore.inMemory([.init(host: key.host, folder: key.folder, lastActive: Date(), layout: .init(
                browserTabs: [browser], rightSide: [.window(index: 1), browserRef], selectedRight: browserRef, splitRatio: 0.7
            ))])
            let manager = makeManager(layoutStore: store)
            manager.updatePaneStates(from: [
                pane(id: "%1", windowId: "@1", windowIndex: 0),
                pane(id: "%2", windowId: "@2", windowIndex: 1),
                pane(id: "%3", windowId: "@3", windowIndex: 2),
            ])
            #expect(await manager.setViewerTerminalLayout(.init(
                sessionName: "coding", leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@3", splitRatio: 0.56
            )))

            let saved = try #require(await store.record(key)?.layout)
            #expect(saved.browserTabs == [browser])
            #expect(saved.selectedRight == browserRef)
            #expect(saved.splitRatio == 0.56)
            let request = LayoutSnapshotMapper.sharedTerminalLayoutRequest(
                from: saved, sessionName: "new", windows: [.init(index: 0, stableId: "@4"), .init(index: 1, stableId: "@5"), .init(index: 2, stableId: "@6")]
            )
            #expect(request?.rightWindowIds == ["@5", "@6"])
            #expect(request?.selectedRightWindowId == "@6")
        }

        @Test("Viewer snapshots include linked session membership alongside the canonical layout")
        func viewerLayoutIncludesLinkedWindowMembership() async throws {
            let key = SavedFolderRecord.Key(host: SavedFolderRecord.localHost, folder: "/project")
            let store = LayoutStore.inMemory()
            let manager = makeManager(layoutStore: store)
            manager.updatePaneStates(from: [
                pane(id: "%1", windowId: "@1", windowIndex: 0, currentPath: key.folder),
                pane(id: "%2", windowId: "@2", windowIndex: 1, currentPath: key.folder),
                pane(id: "%3", windowId: "@3", windowIndex: 2, currentPath: key.folder),
                pane(id: "%2", windowId: "@2", windowIndex: 0, sessionName: "linked", currentPath: key.folder),
            ])
            manager.setSharedTerminalLayout(sessionName: "coding", leftWindowId: "@1", rightWindowIds: ["@3"], selectedRightWindowId: "@3", splitRatio: 0.5)
            let sent = try #require(manager.sharedTerminalLayoutsForViewers()["coding"])
            let layout = try JSONDecoder().decode(SharedTerminalLayout.self, from: JSONEncoder().encode(sent))
            #expect(layout.sessionWindowIds == ["@1", "@2", "@3"])
            #expect(manager.sharedTerminalLayouts["coding"]?.sessionWindowIds == nil)

            let tabs = SessionFileTabsState()
            let visible = ["@1", "@3"]
            tabs.applySharedTerminalLayout(layout, liveWindowIds: Set(visible))
            tabs.recordRemoteTerminalPlacement("@1", onRight: true)
            let request = try #require(tabs.remoteTerminalLayoutRequest(
                sessionName: "coding", sessionWindowIDs: visible, visibleWindowIDs: visible, selectedLeftWindowID: "@1", shared: layout
            ))
            #expect(await manager.setViewerTerminalLayout(request))
            #expect(manager.sharedTerminalLayouts["coding"]?.leftWindowId == "@2")
            #expect(Set(await store.record(key)?.layout.rightSide ?? []) == [.window(index: 0), .window(index: 2)])
        }

        @Test("Viewer selection preserves a Host-private terminal while placement moves the requested terminal", arguments: [false, true])
        func viewerEditsHostLocalSplit(movesTerminal: Bool) async throws {
            let key = SavedFolderRecord.Key(host: SavedFolderRecord.localHost, folder: "/project")
            let editor = SavedFileTab(id: UUID(), path: "/project/notes.md", directoryPath: key.folder)
            let positions = (0..<3).map(SavedTabRef.window(index:))
            let store = LayoutStore.inMemory([.init(
                host: key.host, folder: key.folder, lastActive: Date(),
                layout: .init(fileTabs: [editor], rightSide: positions, selectedLeft: .file(id: editor.id), selectedRight: .window(index: 2))
            )])
            let manager = makeManager(layoutStore: store)
            manager.updatePaneStates(from: (0..<3).map {
                pane(id: "%\($0)", windowId: "@\($0)", windowIndex: $0, currentPath: key.folder)
            })
            manager.setSharedTerminalLayout(sessionName: "coding", leftWindowId: "@0", rightWindowIds: ["@1", "@2"], selectedRightWindowId: "@2", splitRatio: 0.5)
            #expect(await manager.setViewerTerminalLayout(.init(
                sessionName: "coding", leftWindowId: movesTerminal ? "@1" : "@0",
                rightWindowIds: movesTerminal ? ["@2"] : ["@1", "@2"],
                selectedRightWindowId: movesTerminal ? "@2" : "@1"
            )))
            let saved = try #require(await store.record(key)?.layout)
            #expect(Set(saved.rightSide) == Set(movesTerminal ? [positions[0], positions[2]] : positions))
            #expect(saved.selectedLeft == .file(id: editor.id))
            #expect(saved.selectedRightTerminalIndex == (movesTerminal ? 2 : 1))
            #expect(saved.localRightTerminalIndex == 0)
            if movesTerminal {
                let persisted = try JSONDecoder().decode(SavedFolderLayout.self, from: JSONEncoder().encode(saved))
                let request = LayoutSnapshotMapper.sharedTerminalLayoutRequest(
                    from: persisted, sessionName: "coding", windows: (0..<3).map { .init(index: $0, stableId: "@\($0)", isActive: $0 == 0) }
                )
                #expect(request?.leftWindowId == "@1")
                #expect(request?.rightWindowIds == ["@2"])
                let tabs = SessionFileTabsState()
                LayoutSnapshotMapper.apply(
                    persisted, to: tabs, fileBrowser: nil, windowIdForIndex: { "@\($0)" },
                    makeBrowserState: { BrowserTabState(initialURL: $0.url) }
                )
                let shared = try #require(manager.sharedTerminalLayouts["coding"])
                tabs.applySharedTerminalLayout(shared, liveWindowIds: ["@0", "@1", "@2"])
                #expect(tabs.rightSideWindowIds == ["@0", "@2"])
                #expect(await manager.setViewerTerminalLayout(.init(
                    sessionName: "coding", leftWindowId: "@1", rightWindowIds: ["@2"], selectedRightWindowId: "@2", splitRatio: 0.58
                )))
                let resized = try #require(await store.record(key)?.layout)
                #expect(Set(resized.rightSide) == [positions[0], positions[2]])
                #expect(resized.localRightTerminalIndex == 0 && resized.splitRatio == 0.58)
            }
        }

        @Test("A Viewer resize keeps the saved index when a lower link to the same terminal appears", arguments: [false, true])
        func viewerResizeKeepsSavedIndex(localOnly: Bool) async throws {
            let key = SavedFolderRecord.Key(host: SavedFolderRecord.localHost, folder: "/project")
            let savedRight = SavedTabRef.window(index: 3)
            let original = SavedFolderLayout(
                tabOrder: [.window(index: 0), savedRight], rightSide: [savedRight], selectedRight: savedRight,
                localRightTerminalIndex: localOnly ? 3 : nil, splitRatio: 0.70
            )
            let store = LayoutStore.inMemory([.init(host: key.host, folder: key.folder, lastActive: Date(), layout: original)])
            let manager = makeManager(layoutStore: store)
            let left = pane(id: "%1", windowId: "@1", windowIndex: 0, currentPath: key.folder)
            let terminal = pane(id: "%2", windowId: "@2", windowIndex: 3, currentPath: key.folder)
            let link = pane(id: "%2", windowId: "@2", windowIndex: 1, currentPath: key.folder)
            manager.updatePaneStates(from: [left, terminal, link])
            let right = localOnly ? [] : ["@2"]
            #expect(await manager.setViewerTerminalLayout(.init(
                sessionName: "coding", leftWindowId: "@1", rightWindowIds: right, selectedRightWindowId: right.first, splitRatio: 0.56
            )))
            let saved = try #require(await store.record(key)?.layout)
            #expect(saved.rightSide == [savedRight])
            #expect(saved.localRightTerminalIndex == original.localRightTerminalIndex)
            #expect(saved.splitRatio == 0.56)

            var hostDraft = saved
            hostDraft.rightSide = [.window(index: 1)]
            hostDraft.selectedRight = .window(index: 1)
            hostDraft.localRightTerminalIndex = localOnly ? 1 : nil
            let remapped = LayoutSnapshotMapper.preservingAliasedWindowIndices(in: hostDraft, from: saved, windowIndices: ["@2": [1, 3]])
            #expect(remapped.rightSide == [savedRight])
            #expect(remapped.selectedRight == savedRight)
            #expect(remapped.localRightTerminalIndex == original.localRightTerminalIndex)

            let restored = LayoutSnapshotMapper.sharedTerminalLayoutRequest(
                from: saved, sessionName: "coding", windows: [.init(index: 0, stableId: "@1"), .init(index: 3, stableId: "@2")]
            )
            #expect(restored?.rightWindowIds == right)
        }

        @Test("A same-named replacement cannot consume a deferred Viewer layout", arguments: [false, true])
        func replacementSessionDropsDeferredLayout(restartsServer: Bool) async {
            let saved = SavedFolderRecord(host: "local", folder: "/replacement", lastActive: Date(), layout: .init(
                rightSide: [.window(index: 1)], splitRatio: 0.70
            ))
            let store = LayoutStore.inMemory([saved])
            let manager = makeManager(layoutStore: store)
            let windowIDs = [UUID(), UUID()]
            let paneIDs = [UUID(), UUID()]
            func panes(session: UUID?, folder: String, serverID: String) -> [PaneInfo] {
                (0..<2).map { index in
                    pane(
                        id: "%\(index)",
                        windowId: "@\(index)",
                        windowIndex: index,
                        currentPath: folder,
                        identity: session.map { .init(serverID: serverID, sessionID: $0, windowID: windowIDs[index], paneID: paneIDs[index]) },
                        serverID: serverID
                    )
                }
            }
            manager.updatePaneStates(from: panes(session: UUID(), folder: "", serverID: "server"))
            #expect(await manager.setViewerTerminalLayout(.init(
                sessionName: "coding", leftWindowId: "@0", rightWindowIds: ["@1"], selectedRightWindowId: "@1", splitRatio: 0.56
            )))
            manager.defersWorkspaceLayoutInitialization = true
            manager.updatePaneStates(from: panes(
                session: restartsServer ? nil : UUID(), folder: saved.folder, serverID: restartsServer ? "new-server" : "server"
            ))
            #expect(manager.sharedTerminalLayouts["coding"] == nil)
            #expect(await store.record(saved.key) == saved)
        }

        @Test("Linked windows retain their session folder and a single saved split position")
        func linkedWindowRemainsInSharedSplit() async throws {
            let key = SavedFolderRecord.Key(host: "local", folder: "/project")
            let store = LayoutStore.inMemory()
            let firstSession = UUID(), secondSession = UUID(), linkedWindow = UUID(), linkedPane = UUID()
            let sep = String(PaneInfo.fieldSeparator)
            func row(
                _ pane: Int, _ session: String, _ index: Int, _ sessionID: UUID, _ window: UUID, _ paneID: UUID,
                folder: String, active: Bool = false
            ) -> String {
                [
                    "%\(pane)",
                    session,
                    "\(index)",
                    "0",
                    "zsh",
                    folder,
                    "80",
                    "24",
                    "1",
                    "",
                    "",
                    "shell",
                    active ? "1" : "0",
                    "",
                    "",
                    "",
                    "@\(pane)",
                    "server",
                    sessionID.uuidString,
                    window.uuidString,
                    paneID.uuidString,
                    session == "coding" ? "$0" : "$1",
                ]
                .joined(separator: sep)
            }
            let output = [
                row(1, "coding", 0, firstSession, UUID(), UUID(), folder: "/visible"),
                row(2, "coding", 1, firstSession, UUID(), UUID(), folder: "/visible"),
                row(3, "coding", 2, firstSession, linkedWindow, linkedPane, folder: key.folder),
                row(3, "coding", 5, firstSession, linkedWindow, linkedPane, folder: key.folder, active: true),
                row(4, "other", 0, secondSession, UUID(), UUID(), folder: "/other", active: true),
                row(3, "other", 1, secondSession, linkedWindow, linkedPane, folder: key.folder),
            ].joined(separator: "\n")
            let tmux = withDependencies {
                $0[ProcessRunner.self].run = { _, arguments, _, _ in
                    let result = arguments.contains("list-panes") ? output : "0\(sep)other"
                    return ProcessResult(exitCode: 0, stdout: Data(result.utf8), stderr: Data())
                }
            } operation: {
                TmuxService(tmuxPath: "/bin/sh")
            }
            let manager = makeManager(layoutStore: store, tmuxService: tmux)
            let panes = await tmux.refreshPanes()
            #expect(panes.filter { $0.stableWindowId == "@3" }.map(\.sessionName) == ["other"])
            manager.updatePaneStates(from: panes)
            #expect(manager.layoutFolder(forSession: "coding") == key.folder)
            manager.setSharedTerminalLayout(sessionName: "coding", leftWindowId: "@1", rightWindowIds: ["@2", "@3"], selectedRightWindowId: "@2", splitRatio: 0.70)
            manager.updatePaneStates(from: panes)
            #expect(manager.sharedTerminalLayouts["coding"]?.rightWindowIds == ["@2", "@3"])
            #expect(await manager.setViewerTerminalLayout(.init(
                sessionName: "coding", leftWindowId: "@1", rightWindowIds: ["@2"], selectedRightWindowId: "@2", splitRatio: 0.64
            )))
            let saved = try #require(await store.record(key)?.layout)
            #expect(Set(saved.rightSide) == [.window(index: 1), .window(index: 2)])
            #expect(saved.splitRatio == 0.64)
            #expect(await store.record(.init(host: key.host, folder: "/visible")) == nil)
            #expect(await manager.setViewerTerminalLayout(.init(
                sessionName: "coding", leftWindowId: "@1", splitRatio: 0.64, removedRightWindowIds: ["@2", "@3"]
            )))
            #expect(manager.sharedTerminalLayouts["coding"]?.rightWindowIds.isEmpty == true)
            #expect(await store.record(key)?.layout.rightSide.isEmpty == true)
        }

        @Test("A second folder's Viewer edit leaves the first folder's newer layout available to Host saves")
        func retainsViewerEditsByFolder() async throws {
            let manager = makeManager()
            func selectFolder(_ folder: String) {
                manager.updatePaneStates(from: (0..<3).map {
                    pane(id: "%\($0)", windowId: "@\($0)", windowIndex: $0, currentPath: folder)
                })
            }
            selectFolder("/a")
            #expect(await manager.setViewerTerminalLayout(.init(
                sessionName: "coding", leftWindowId: "@0", rightWindowIds: ["@1", "@2"], selectedRightWindowId: "@1", splitRatio: 0.56
            )))
            selectFolder("/b")
            #expect(await manager.setViewerTerminalLayout(.init(
                sessionName: "coding", leftWindowId: "@0", rightWindowIds: ["@1", "@2"], selectedRightWindowId: "@2", splitRatio: 0.63
            )))
            let edit = try #require(manager.viewerTerminalLayout(after: nil, sessionName: "coding", folder: "/a"))
            let applied = edit.applying(to: .init(splitRatio: 0.70))
            #expect(applied.splitRatio == 0.56)
            #expect(applied.selectedRight == .window(index: 1))
            #expect(manager.viewerTerminalLayout(after: edit.layout.revision, sessionName: "coding", folder: "/a") == nil)
        }

        @Test("Pane metadata flushes a Viewer layout that was accepted without a directory")
        func persistsViewerLayoutWhenDirectoryAppears() async throws {
            let key = SavedFolderRecord.Key(host: SavedFolderRecord.localHost, folder: "/project")
            let old = SavedFolderRecord(host: key.host, folder: key.folder, lastActive: Date(), layout: .init(splitRatio: 0.70))
            let store = LayoutStore.inMemory([old])
            let manager = makeManager(layoutStore: store)
            func panes(_ folder: String) -> [PaneInfo] {
                (0..<3).map { pane(id: "%\($0)", windowId: "@\($0)", windowIndex: $0, currentPath: folder) }
            }
            manager.updatePaneStates(from: panes(""))
            manager.initializeSharedTerminalLayoutsIfNeeded()
            #expect(await manager.setViewerTerminalLayout(.init(
                sessionName: "coding", leftWindowId: "@0", rightWindowIds: ["@1", "@2"], selectedRightWindowId: "@2", splitRatio: 0.56
            )))
            #expect(await store.record(key) == old)
            manager.updatePaneStates(from: panes(key.folder))
            for _ in 0..<1_000 {
                if await store.record(key)?.layout.splitRatio == 0.56 {
                    break
                }
                await Task.yield()
            }
            let saved = try #require(await store.record(key)?.layout)
            #expect(saved.splitRatio == 0.56)
            #expect(saved.selectedRightTerminalIndex == 2)
            #expect(manager.sharedTerminalLayoutFolders["coding"] == key.folder)
        }

        @Test("The fallback layout remains provisional until a folder or explicit layout is available")
        func missingFolderEstablishesProvisionalLayout() {
            let manager = makeManager()
            manager.updatePaneStates(from: [
                pane(id: "%1", windowId: "@1", windowIndex: 0, currentPath: ""),
                pane(id: "%2", windowId: "@2", windowIndex: 1, currentPath: ""),
            ])
            manager.initializeSharedTerminalLayoutsIfNeeded()
            #expect(manager.sharedLayoutsAwaitingFolder == ["coding"])
            #expect(manager.sharedTerminalLayouts["coding"]?.rightWindowIds.isEmpty == true)

            manager.setSharedTerminalLayout(
                sessionName: "coding", leftWindowId: "@1", rightWindowIds: ["@2"],
                selectedRightWindowId: "@2", splitRatio: 0.7
            )
            #expect(manager.sharedLayoutsAwaitingFolder.isEmpty)
        }

        @Test("A background session reloads its split when pane metadata supplies a folder")
        func reloadsBackgroundLayoutAfterFolderAppears() async {
            let store = LayoutStore.inMemory([
                SavedFolderRecord(
                    host: SavedFolderRecord.localHost, folder: "/background", lastActive: Date(),
                    layout: SavedFolderLayout(rightSide: [.window(index: 1)], selectedRight: .window(index: 1), splitRatio: 0.7)
                ),
            ])
            let manager = makeManager(layoutStore: store)
            manager.updatePaneStates(from: [
                pane(id: "%1", windowId: "@12", windowIndex: 0, currentPath: ""),
                pane(id: "%2", windowId: "@13", windowIndex: 1, currentPath: ""),
            ])
            manager.initializeSharedTerminalLayoutsIfNeeded()
            #expect(manager.sharedLayoutsAwaitingFolder == ["coding"])

            manager.updatePaneStates(from: [
                pane(id: "%1", windowId: "@12", windowIndex: 0, currentPath: "/background"),
                pane(id: "%2", windowId: "@13", windowIndex: 1, currentPath: "/background"),
            ])
            for _ in 0..<1_000 where manager.sharedLayoutsAwaitingFolder.contains("coding") {
                await Task.yield()
            }

            #expect(manager.sharedLayoutsAwaitingFolder.isEmpty)
            #expect(manager.sharedTerminalLayouts["coding"]?.rightWindowIds == ["@13"])
            #expect(manager.sharedTerminalLayouts["coding"]?.splitRatio == 0.7)
        }

        @Test("The Host clamps ratios, increments revisions, and ignores duplicates")
        func storesCanonicalLayout() {
            let manager = makeManager()

            #expect(manager.setSharedTerminalLayout(
                sessionName: "coding",
                leftWindowId: "@1",
                rightWindowIds: ["@2", "@3"],
                selectedRightWindowId: "@3",
                splitRatio: 1
            ))
            #expect(manager.sharedTerminalLayouts["coding"] == SharedTerminalLayout(
                leftWindowId: "@1",
                rightWindowIds: ["@2", "@3"],
                selectedRightWindowId: "@3",
                splitRatio: 0.85,
                revision: 1
            ))

            #expect(!manager.setSharedTerminalLayout(
                sessionName: "coding",
                leftWindowId: "@1",
                rightWindowIds: ["@2", "@3"],
                selectedRightWindowId: "@3",
                splitRatio: 0.85
            ))
            #expect(manager.setSharedTerminalLayout(
                sessionName: "coding",
                leftWindowId: "@2",
                rightWindowIds: [],
                selectedRightWindowId: nil,
                splitRatio: 0
            ))
            #expect(manager.sharedTerminalLayouts["coding"]?.revision == 2)
            #expect(manager.sharedTerminalLayouts["coding"]?.splitRatio == 0.15)
        }

        @Test("Invalid identities are rejected")
        func rejectsInvalidIdentity() {
            let manager = makeManager()

            #expect(!manager.setSharedTerminalLayout(
                sessionName: "",
                leftWindowId: "@1",
                rightWindowIds: [],
                selectedRightWindowId: nil,
                splitRatio: 0.5
            ))
            #expect(!manager.setSharedTerminalLayout(
                sessionName: "coding",
                leftWindowId: "@1",
                rightWindowIds: ["@1"],
                selectedRightWindowId: "@1",
                splitRatio: 0.5
            ))
            #expect(manager.sharedTerminalLayouts.isEmpty)
        }

        @Test("Dead windows are removed before a shared layout is published")
        func prunesDeadWindows() {
            let manager = makeManager()
            manager.updatePaneStates(from: [
                pane(id: "%1", windowId: "@1", windowIndex: 0),
                pane(id: "%2", windowId: "@2", windowIndex: 1),
            ])
            manager.setSharedTerminalLayout(
                sessionName: "coding",
                leftWindowId: "@1",
                rightWindowIds: ["@2"],
                selectedRightWindowId: "@2",
                splitRatio: 0.5
            )

            manager.updatePaneStates(from: [pane(id: "%1", windowId: "@1", windowIndex: 0)])

            #expect(manager.sharedTerminalLayouts["coding"] == SharedTerminalLayout(
                leftWindowId: "@1",
                rightWindowIds: [],
                selectedRightWindowId: nil,
                splitRatio: 0.5,
                revision: 2
            ))

            manager.updatePaneStates(from: [])

            #expect(manager.sharedTerminalLayouts.isEmpty)
        }

        @Test("Closing the left tab publishes the first remaining tab and keeps the split")
        func closesLeftWindow() {
            let manager = makeManager()
            let panes = [
                pane(id: "%1", windowId: "@1", windowIndex: 0),
                pane(id: "%2", windowId: "@2", windowIndex: 1),
                pane(id: "%3", windowId: "@3", windowIndex: 2, isWindowActive: true),
                pane(id: "%4", windowId: "@4", windowIndex: 3),
            ]
            manager.updatePaneStates(from: panes)
            manager.setSharedTerminalLayout(sessionName: "coding", leftWindowId: "@1", rightWindowIds: ["@4"], selectedRightWindowId: "@4", splitRatio: 0.6)
            manager.updatePaneStates(from: Array(panes.dropFirst()))
            #expect(manager.sharedTerminalLayouts["coding"] == SharedTerminalLayout(
                leftWindowId: "@2", rightWindowIds: ["@4"], selectedRightWindowId: "@4", splitRatio: 0.6, revision: 2
            ))
            manager.updatePaneStates(from: [panes[3]])
            #expect(manager.sharedTerminalLayouts["coding"]?.leftWindowId == "@4")
            #expect(manager.sharedTerminalLayouts["coding"]?.rightWindowIds.isEmpty == true)
        }

        @Test("Cold start initializes saved background splits and explicit unsplit sessions")
        func initializesEveryLiveSession() async {
            let savedBackgroundLayout = SavedFolderLayout(
                tabOrder: [.window(index: 0), .window(index: 1)],
                rightSide: [.window(index: 1)],
                selectedRight: .window(index: 1),
                splitRatio: 0.64
            )
            let store = LayoutStore.inMemory([
                SavedFolderRecord(
                    host: SavedFolderRecord.localHost,
                    folder: "/background",
                    lastActive: Date(),
                    layout: savedBackgroundLayout
                ),
            ])
            let manager = makeManager(layoutStore: store)
            manager.updatePaneStates(from: [
                pane(
                    id: "%1",
                    windowId: "@1",
                    windowIndex: 0,
                    sessionName: "foreground",
                    currentPath: "/foreground",
                    isWindowActive: true
                ),
                pane(
                    id: "%2",
                    windowId: "@2",
                    windowIndex: 0,
                    sessionName: "background",
                    currentPath: "/background",
                    isWindowActive: true
                ),
                pane(
                    id: "%3",
                    windowId: "@3",
                    windowIndex: 1,
                    sessionName: "background",
                    currentPath: "/background"
                ),
            ])

            manager.initializeSharedTerminalLayoutsIfNeeded()
            for _ in 0..<1_000 where manager.sharedTerminalLayouts.count < 2 {
                await Task.yield()
            }

            #expect(manager.sharedTerminalLayouts["foreground"] == SharedTerminalLayout(
                leftWindowId: "@1",
                rightWindowIds: [],
                selectedRightWindowId: nil,
                splitRatio: 0.5,
                revision: 1
            ))
            #expect(manager.sharedTerminalLayouts["background"] == SharedTerminalLayout(
                leftWindowId: "@2",
                rightWindowIds: ["@3"],
                selectedRightWindowId: "@3",
                splitRatio: 0.64,
                revision: 1
            ))
        }

        @Test("A folder change during the first read retries without a pane update")
        func retriesFirstReadAfterFolderChange() async {
            let release = AsyncStream<Void>.makeStream()
            let storage = LayoutStore.inMemory([
                .init(host: SavedFolderRecord.localHost, folder: "/first", lastActive: Date(), layout: .init(splitRatio: 0.7)),
                .init(
                    host: SavedFolderRecord.localHost, folder: "/second", lastActive: Date(),
                    layout: .init(rightSide: [.window(index: 1)], selectedRight: .window(index: 1), splitRatio: 0.35)
                ),
            ])
            var store = storage
            store.record = { key in
                if key.folder == "/first" {
                    for await _ in release.stream { }
                }
                return await storage.record(key)
            }
            let manager = makeManager(layoutStore: store)
            manager.updatePaneStates(from: [
                pane(id: "%1", windowId: "@1", windowIndex: 0, currentPath: "/first", isWindowActive: true),
                pane(id: "%2", windowId: "@2", windowIndex: 1, currentPath: "/first"),
            ])
            manager.initializeSharedTerminalLayoutsIfNeeded()
            manager.updatePaneStates(from: [
                pane(id: "%1", windowId: "@1", windowIndex: 0, currentPath: "/second", isWindowActive: true),
                pane(id: "%2", windowId: "@2", windowIndex: 1, currentPath: "/second"),
            ])
            release.continuation.finish()
            for _ in 0..<1_000 where manager.sharedTerminalLayouts["coding"] == nil {
                await Task.yield()
            }

            #expect(manager.sharedTerminalLayoutFolders["coding"] == "/second")
            #expect(manager.sharedTerminalLayouts["coding"]?.rightWindowIds == ["@2"])
            #expect(manager.sharedTerminalLayouts["coding"]?.splitRatio == 0.35)
        }

        @Test("A layout changed after hydration starts wins over the late disk read")
        func liveLayoutWinsHydrationRace() async {
            let store = LayoutStore.inMemory([
                SavedFolderRecord(
                    host: SavedFolderRecord.localHost,
                    folder: "/race",
                    lastActive: Date(),
                    layout: SavedFolderLayout(
                        rightSide: [.window(index: 1)],
                        selectedRight: .window(index: 1)
                    )
                ),
            ])
            let manager = makeManager(layoutStore: store)
            manager.updatePaneStates(from: [
                pane(
                    id: "%1",
                    windowId: "@1",
                    windowIndex: 0,
                    currentPath: "/race",
                    isWindowActive: true
                ),
                pane(id: "%2", windowId: "@2", windowIndex: 1, currentPath: "/race"),
            ])

            manager.initializeSharedTerminalLayoutsIfNeeded()
            #expect(manager.setSharedTerminalLayout(
                sessionName: "coding",
                leftWindowId: "@2",
                rightWindowIds: [],
                selectedRightWindowId: nil,
                splitRatio: 0.4
            ))
            for _ in 0..<100 {
                await Task.yield()
            }

            #expect(manager.sharedTerminalLayouts["coding"] == SharedTerminalLayout(
                leftWindowId: "@2",
                rightWindowIds: [],
                selectedRightWindowId: nil,
                splitRatio: 0.4,
                revision: 1
            ))
        }
    }
#endif
