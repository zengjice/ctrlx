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
        private func makeManager(layoutStore: LayoutStore = .inMemory()) -> MirrorWindowManager {
            withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[ProcessRunner.self] = .previewValue
                $0[LoginItemService.self] = .previewValue
                $0[LayoutStore.self] = layoutStore
            } operation: {
                let tmux = TmuxService()
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
            isWindowActive: Bool = false
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
                isWindowActive: isWindowActive
            )
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
            for _ in 0..<100 { await Task.yield() }

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
