#if os(macOS)
    import ConcurrencyExtras
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite("Local session order")
    struct LocalSessionOrderTests {
        private func settings(_ preferences: PreferencesService) -> AppSettings {
            withDependencies { $0[PreferencesService.self] = preferences } operation: { AppSettings() }
        }

        private func pane(_ id: String, session: String) -> PaneInfo {
            PaneInfo(paneId: id, target: "\(session):0.0", sessionName: session, windowIndex: 0,
                     paneIndex: 0, command: "zsh", currentPath: "/tmp", width: 80, height: 24, isActive: true)
        }

        private func manager(settings: AppSettings) -> MirrorWindowManager {
            withDependencies {
                $0[ProcessRunner.self] = .previewValue
                $0[PreferencesService.self] = .inMemory()
            } operation: {
                let tmux = TmuxService()
                return MirrorWindowManager(
                    settings: settings, tmuxService: tmux,
                    paneStreamManager: PaneStreamManager(tmuxService: tmux, controlClientManager: TmuxControlClientManager()),
                    editorSessionManager: EditorSessionManager()
                )
            }
        }

        @Test("Manual local order persists independently of remote hosts")
        func persistsAndRestoresAutomaticOrder() {
            let preferences = PreferencesService.inMemory()
            let settings = settings(preferences)
            #expect(settings.localSessionOrder.isEmpty)
            settings.setLocalSessionOrder(["b", "a", "b", ""])
            settings.setRemoteSessionOrder(["a", "b"], for: "office")
            settings.setRemoteSessionOrder(["b", "a"], for: "home")
            let reloaded = self.settings(preferences)
            #expect(reloaded.localSessionOrder == ["b", "a"])
            #expect(reloaded.remoteSessionOrder(for: "office") == ["a", "b"])
            #expect(reloaded.remoteSessionOrder(for: "home") == ["b", "a"])

            reloaded.setLocalSessionOrder([])
            #expect(self.settings(preferences).localSessionOrder.isEmpty)
            #expect(reloaded.remoteSessionOrder(for: "office") == ["a", "b"])
            reloaded.setLocalSessionOrder(["a", "b"])
            reloaded.setRemoteSessionOrder([], for: "office")
            #expect(reloaded.localSessionOrder == ["a", "b"])
            #expect(reloaded.remoteSessionOrder(for: "home") == ["b", "a"])
        }

        @Test("Restoring the default order puts working sessions before idle on local and remote lists")
        func restoresActivityPriority() {
            let settings = settings(.inMemory())
            let names = ["biaozhu", "ux", "window", "credit-hl", "cm", "a-terminal"]
            let panes = names.enumerated().map { pane("%\($0.offset)", session: $0.element) }
            let sessions = LocalTmuxSession.groupWindows(LocalTmuxWindow.groupPanes(panes))
            var states = Dictionary(uniqueKeysWithValues: panes.map { ($0.paneId, $0.makePaneState()) })
            for paneID in ["%0", "%1"] {
                states[paneID]?.agentSession = AgentSession(paneId: paneID, state: .idle)
            }
            for paneID in ["%2", "%3"] {
                states[paneID]?.agentSession = AgentSession(paneId: paneID, state: .working)
            }
            states["%4"]?.agentSession = AgentSession(paneId: "%4", state: .doneWorking(summary: nil))

            func localOrder() -> [String] {
                SessionSortData.sortedLocalSessions(
                    sessions, mode: settings.sidebarSortMode, paneStates: states, lastActivity: { _ in nil },
                    sidebarFields: SidebarField.defaultFields, sidebarTerminalFields: SidebarField.defaultTerminalFields,
                    preferredSessionNames: settings.localSessionOrder
                ).map(\.sessionName)
            }
            func remoteOrder() -> [String] {
                SessionSortData.sortedRemoteSessions(
                    TmuxSession.groupWindows(TmuxWindow.groupPanes(Array(states.values))),
                    mode: settings.sidebarSortMode,
                    sidebarFields: SidebarField.defaultFields, sidebarTerminalFields: SidebarField.defaultTerminalFields,
                    homeDirectory: nil, preferredSessionNames: settings.remoteSessionOrder(for: "office")
                ).map(\.sessionName)
            }

            settings.setLocalSessionOrder(names)
            settings.setRemoteSessionOrder(names, for: "office")
            #expect(localOrder() == names)
            #expect(remoteOrder() == names)

            settings.setLocalSessionOrder([])
            settings.setRemoteSessionOrder([], for: "office")
            let expected = ["cm", "credit-hl", "window", "biaozhu", "ux", "a-terminal"]
            #expect(localOrder() == expected)
            #expect(remoteOrder() == expected)

            states["%2"]?.cliSessionState = .idle
            let updated = ["cm", "credit-hl", "biaozhu", "ux", "window", "a-terminal"]
            #expect(localOrder() == updated)
            #expect(remoteOrder() == updated)
        }

        @Test("Saved automatic strategies survive reload and restoring order", arguments: SidebarSortMode.allCases)
        func preservesSavedSortMode(mode: SidebarSortMode) {
            let preferences = PreferencesService.inMemory()
            preferences.setString(mode.rawValue, AppSettings.Keys.sidebarSortMode.rawValue)
            let settings = settings(preferences)
            settings.setLocalSessionOrder(["b", "a"])
            settings.setLocalSessionOrder([])
            #expect(settings.sidebarSortMode == mode)
            #expect(self.settings(preferences).sidebarSortMode == mode)
        }

        @Test("Discovery without a manual order keeps automatic sorting")
        func automaticDiscoveryDoesNotSaveRank() {
            let settings = settings(.inMemory())
            manager(settings: settings).updatePaneStates(from: [pane("%1", session: "a")])
            #expect(settings.localSessionOrder.isEmpty)
        }

        @Test("Background metadata refresh preserves rename position and appends new sessions")
        func reconcilesLifecycleWithoutMainView() {
            let settings = settings(.inMemory())
            settings.setLocalSessionOrder(["b", "old", "closed"])
            let manager = manager(settings: settings)
            // No confirmed snapshot yet: don't erase the persisted order on startup.
            manager.updatePaneStates(from: [])
            #expect(settings.localSessionOrder == ["b", "old", "closed"])
            let initial = [pane("%1", session: "old"), pane("%2", session: "b"), pane("%3", session: "closed")]
            manager.updatePaneStates(from: initial)

            manager.updatePaneStates(from: [pane("%1", session: "renamed"), pane("%2", session: "b"), pane("%4", session: "new")])
            #expect(settings.localSessionOrder == ["b", "renamed", "new"])
            manager.updatePaneStates(from: [pane("%1", session: "renamed"), pane("%2", session: "b"),
                                           pane("%4", session: "new"), pane("%5", session: "a-later")])
            #expect(settings.localSessionOrder == ["b", "renamed", "new", "a-later"])
            manager.updatePaneStates(from: [])
            #expect(settings.localSessionOrder.isEmpty)
        }

        @Test("Closed names do not regain their old position when reused")
        func reusedNamesAreNewSessions() {
            let settings = settings(.inMemory())
            settings.setLocalSessionOrder(["a", "b"])
            let manager = manager(settings: settings)
            manager.updatePaneStates(from: [pane("%1", session: "a"), pane("%2", session: "b")])
            manager.updatePaneStates(from: [pane("%2", session: "b")])
            manager.updatePaneStates(from: [pane("%2", session: "b"), pane("%3", session: "a")])
            #expect(settings.localSessionOrder == ["b", "a"])
        }

        @Test("Repeated metadata and equivalent moves do not rewrite preferences")
        func unchangedOrderDoesNotWrite() {
            var preferences = PreferencesService.inMemory()
            let writes = LockIsolated(0)
            let setData = preferences.setData
            preferences.setData = { data, key in
                if key == "localSessionOrder" { writes.withValue { $0 += 1 } }
                setData(data, key)
            }
            let settings = settings(preferences)
            settings.setLocalSessionOrder(["b", "a"])
            let manager = manager(settings: settings)
            let panes = [pane("%1", session: "a"), pane("%2", session: "b")]
            manager.updatePaneStates(from: panes)
            let baseline = writes.value
            for _ in 0 ..< 20 {
                manager.updatePaneStates(from: panes)
                settings.setLocalSessionOrder(["b", "a", "b", ""])
            }
            #expect(writes.value == baseline)
        }

        @Test("The shared local sorter honors manual rank across modes and state changes", arguments: SidebarSortMode.allCases)
        func manualRankOverridesAutomaticMode(mode: SidebarSortMode) {
            let panes = [pane("%1", session: "a"), pane("%2", session: "b"), pane("%3", session: "new")]
            let sessions = LocalTmuxSession.groupWindows(LocalTmuxWindow.groupPanes(panes))
            var states = Dictionary(uniqueKeysWithValues: panes.map { ($0.paneId, $0.makePaneState()) })
            func sorted(_ preference: [String]) -> [String] {
                SessionSortData.sortedLocalSessions(
                    sessions, mode: mode, paneStates: states, lastActivity: { _ in nil },
                    sidebarFields: SidebarField.defaultFields, sidebarTerminalFields: SidebarField.defaultTerminalFields,
                    preferredSessionNames: preference
                ).map(\.sessionName)
            }
            #expect(sorted(["b", "a"]) == ["b", "a", "new"])
            states["%1"]?.cliSessionState = .waiting
            #expect(sorted(["b", "a"]) == ["b", "a", "new"])
            #expect(sorted([]).first == "a")
        }
    }
#endif
