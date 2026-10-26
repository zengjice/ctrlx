#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("SessionSortData.forLocalSession")
    struct SessionSortDataForLocalSessionTests {
        private let sidebarFields: [SidebarField] = [.customDescription, .projectName, .sessionName]
        private let terminalFields: [SidebarField] = [.customDescription, .currentPath, .sessionName]

        @Test("Default label priority exposes the renamed tmux session")
        func defaultLabelPriority() {
            let label = SessionSortData.primaryLabel(
                fields: SidebarField.defaultFields,
                customDescription: "Description",
                projectName: "Project",
                sessionName: "renamed-session",
                windowName: "terminal 1",
                terminalTitle: "Terminal",
                command: "codex",
                currentPath: "/tmp/project"
            )
            #expect(label == "renamed-session")
        }

        private func makePane(
            _ paneId: String,
            session: String,
            window: Int = 0,
            pane: Int = 0,
            command: String = "zsh",
            currentPath: String = "/tmp/dir",
            isActive: Bool = true,
            lastActivityAt: Date? = nil,
            windowName: String = "",
            isWindowActive: Bool = false
        ) -> PaneInfo {
            PaneInfo(
                paneId: paneId, target: "\(session):\(window).\(pane)", sessionName: session,
                windowIndex: window, paneIndex: pane, command: command, currentPath: currentPath,
                width: 80, height: 24, isActive: isActive, lastActivityAt: lastActivityAt,
                windowName: windowName, isWindowActive: isWindowActive
            )
        }

        private func makeSession(_ panes: [PaneInfo]) -> LocalTmuxSession {
            LocalTmuxSession.groupWindows(LocalTmuxWindow.groupPanes(panes))[0]
        }

        @Test("An agent session uses the agent sidebar fields and carries its status priority")
        func agentSession() {
            let session = makeSession([makePane("%1", session: "work")])
            var paneState = PaneState(paneId: "%1", sessionName: "work")
            paneState.agentSession = AgentSession(
                paneId: "%1",
                detectedProjectPath: "/Users/me/Dev/CtrlX",
                state: .doneWorking(summary: nil)
            )
            let data = SessionSortData.forLocalSession(
                session,
                paneStates: ["%1": paneState],
                lastActivity: { _ in nil },
                sidebarFields: sidebarFields,
                sidebarTerminalFields: terminalFields
            )
            #expect(data.hasClaude)
            #expect(data.primaryLabel == "CtrlX")
            #expect(data.statusPriority == 0)
        }

        @Test("The manual Set State override drives the status priorities, in both directions")
        func overrideDrivesStatusPriority() {
            let session = makeSession([makePane("%1", session: "work")])

            // Pinned to Waiting over an idle agent -> attention bucket (the
            // reported bug: the row showed the bell but sorted as idle).
            var pinned = PaneState(paneId: "%1", sessionName: "work")
            pinned.agentSession = AgentSession(paneId: "%1", state: .idle)
            pinned.cliSessionState = .waiting
            let pinnedData = SessionSortData.forLocalSession(
                session,
                paneStates: ["%1": pinned],
                lastActivity: { _ in nil },
                sidebarFields: sidebarFields,
                sidebarTerminalFields: terminalFields
            )
            #expect(pinnedData.statusPriority == 0)
            #expect(pinnedData.statusPriorityIdleFirst == 0)

            // Pinned to Idle over a needs-attention agent -> idle bucket.
            var suppressed = PaneState(paneId: "%1", sessionName: "work")
            suppressed.agentSession = AgentSession(paneId: "%1", state: .doneWorking(summary: nil))
            suppressed.cliSessionState = .idle
            let suppressedData = SessionSortData.forLocalSession(
                session,
                paneStates: ["%1": suppressed],
                lastActivity: { _ in nil },
                sidebarFields: sidebarFields,
                sidebarTerminalFields: terminalFields
            )
            #expect(suppressedData.statusPriority == 2)
            #expect(suppressedData.statusPriorityIdleFirst == 1)
        }

        @Test("A pinned terminal-only session sorts by its pinned bucket, matching its bell")
        func pinnedTerminalSorts() {
            let session = makeSession([makePane("%1", session: "scratch")])
            var pane = PaneState(paneId: "%1", sessionName: "scratch")
            pane.cliSessionState = .waiting
            let data = SessionSortData.forLocalSession(
                session,
                paneStates: ["%1": pane],
                lastActivity: { _ in nil },
                sidebarFields: sidebarFields,
                sidebarTerminalFields: terminalFields
            )
            #expect(!data.hasClaude)
            #expect(data.statusPriority == 0)
            #expect(data.statusPriorityIdleFirst == 0)
        }

        @Test("Remote sort data honors the override too")
        func remoteOverrideDrivesStatusPriority() {
            let pane = PaneState(
                paneId: "%9",
                sessionName: "work",
                windowIndex: 0,
                paneIndex: 0,
                agentSession: AgentSession(paneId: "%9", state: .idle),
                cliSessionState: .waiting
            )
            let session = TmuxSession.groupWindows(TmuxWindow.groupPanes([pane]))[0]
            let data = SessionSortData.forRemoteSession(
                session,
                sidebarFields: sidebarFields,
                sidebarTerminalFields: terminalFields,
                homeDirectory: nil
            )
            #expect(data.statusPriority == 0)
            #expect(data.statusPriorityIdleFirst == 0)
        }

        @Test("A terminal session uses the terminal fields; recency is the max across panes")
        func terminalSession() {
            let panes = [
                makePane("%1", session: "scratch", window: 0),
                makePane("%2", session: "scratch", window: 1),
            ]
            let session = makeSession(panes)
            let older = Date(timeIntervalSince1970: 100)
            let newer = Date(timeIntervalSince1970: 200)
            let activity = ["%1": older, "%2": newer]
            let data = SessionSortData.forLocalSession(
                session,
                paneStates: [
                    "%1": PaneState(paneId: "%1", sessionName: "scratch"),
                    "%2": PaneState(paneId: "%2", sessionName: "scratch"),
                ],
                lastActivity: { activity[$0] },
                sidebarFields: sidebarFields,
                sidebarTerminalFields: terminalFields
            )
            #expect(!data.hasClaude)
            #expect(data.primaryLabel == "/tmp/dir")
            #expect(data.statusPriority == 3)
            #expect(data.latestEventTimestamp == newer)
        }

        @Test("Window activity restores idle recency after a Host restart")
        func windowActivityAfterRestart() {
            let older = Date(timeIntervalSince1970: 100)
            let newer = Date(timeIntervalSince1970: 200)
            let panes = [
                makePane("%1", session: "cm", lastActivityAt: older),
                makePane("%2", session: "multi-agent", lastActivityAt: newer),
            ]
            let states = Dictionary(uniqueKeysWithValues: panes.map { pane in
                var state = pane.makePaneState()
                state.agentSession = AgentSession(paneId: pane.paneId, state: .idle)
                return (pane.paneId, state)
            })
            let order = SessionSortData.sortedLocalSessions(
                LocalTmuxSession.groupWindows(LocalTmuxWindow.groupPanes(panes)),
                mode: .statusPriority,
                paneStates: states,
                lastActivity: { states[$0]?.lastAgentActivityAt },
                sidebarFields: sidebarFields,
                sidebarTerminalFields: terminalFields
            ).map(\.sessionName)
            #expect(order == ["multi-agent", "cm"])
        }

        @Test("Local and remote task order agrees after ISO 8601 encoding", arguments: [
            (200.999, ["cm", "ux"]),
            (201.001, ["ux", "cm"]),
        ])
        func localAndRemoteActivityOrder(latestActivity: TimeInterval, expected: [String]) throws {
            let panes = [
                makePane("%1", session: "ux", isWindowActive: true),
                makePane("%2", session: "ux", window: 1),
                makePane("%3", session: "ux", window: 1, pane: 1, isActive: false),
                makePane("%4", session: "cm"),
            ]
            let activity = ["%1": 100.0, "%2": 100.0, "%3": latestActivity, "%4": 200.001]
            let states = Dictionary(uniqueKeysWithValues: panes.map { pane in
                var state = pane.makePaneState()
                state.agentSession = AgentSession(paneId: pane.paneId, state: .idle)
                state.lastAgentActivityAt = activity[pane.paneId].map { Date(timeIntervalSince1970: $0) }
                return (pane.paneId, state)
            })
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let message = WebSocketMessage.sessionState(SessionStateMessage(pairId: "host", paneStates: states))
            let decoded = try decoder.decode(WebSocketMessage.self, from: encoder.encode(message))
            guard case let .sessionState(snapshot) = decoded else {
                Issue.record("Expected a session state snapshot")
                return
            }
            let local = LocalTmuxSession.groupWindows(LocalTmuxWindow.groupPanes(panes))
            let remote = TmuxSession.groupWindows(TmuxWindow.groupPanes(Array(snapshot.paneStates.values)))
            for mode in [SidebarSortMode.statusPriority, .statusPriorityIdleFirst, .recentActivity] {
                let localOrder = mode.sorted(local) {
                    SessionSortData.forLocalSession(
                        $0, paneStates: states, lastActivity: { states[$0]?.lastAgentActivityAt },
                        sidebarFields: sidebarFields, sidebarTerminalFields: terminalFields
                    )
                }.map(\.sessionName)
                let remoteOrder = SessionSortData.sortedRemoteSessions(
                    remote, mode: mode, sidebarFields: sidebarFields,
                    sidebarTerminalFields: terminalFields, homeDirectory: nil
                ).map(\.sessionName)
                #expect(localOrder == expected)
                #expect(remoteOrder == localOrder)
            }
        }

        @Test("Local and remote status includes agents beyond the first tab", arguments: [
            (AgentState.working, 1),
            (.doneWorking(summary: nil), 0),
        ])
        func statusAcrossWindows(state: AgentState, priority: Int) {
            let panes = [makePane("%1", session: "ux"), makePane("%2", session: "ux", window: 1)]
            let states = Dictionary(uniqueKeysWithValues: panes.enumerated().map { index, pane in
                var value = pane.makePaneState()
                value.agentSession = AgentSession(paneId: pane.paneId, state: index == 0 ? .idle : state)
                return (pane.paneId, value)
            })
            let local = SessionSortData.forLocalSession(
                makeSession(panes), paneStates: states, lastActivity: { _ in nil },
                sidebarFields: sidebarFields, sidebarTerminalFields: terminalFields
            )
            let remote = TmuxSession.groupWindows(TmuxWindow.groupPanes(Array(states.values)))[0]
            let remoteData = SessionSortData.forRemoteSession(
                remote, sidebarFields: sidebarFields, sidebarTerminalFields: terminalFields, homeDirectory: nil
            )
            #expect(local.statusPriority == priority)
            #expect(remoteData.statusPriority == priority)
            #expect(remote.agentSession?.state == state)
        }

        @Test("Local labels use only the active window and pane metadata")
        func localLabelsUseActiveWindow() {
            let session = makeSession([
                makePane(
                    "%1", session: "scratch", window: 0,
                    command: "inactive-command", currentPath: "/inactive",
                    windowName: "inactive-window"
                ),
                makePane(
                    "%2", session: "scratch", window: 1,
                    command: "active-command", currentPath: "/active",
                    windowName: "active-window", isWindowActive: true
                ),
            ])
            let states = [
                "%1": PaneState(
                    paneId: "%1", sessionName: "scratch",
                    terminalTitle: "Inactive OSC Title", gitBranch: "inactive-branch"
                ),
                "%2": PaneState(
                    paneId: "%2", sessionName: "scratch",
                    terminalTitle: "Active OSC Title", gitBranch: "active-branch"
                ),
            ]

            let metadata = session.activeWindowMetadata(paneStates: states)
            #expect(metadata.windowName == "active-window")
            #expect(metadata.terminalTitle == "Active OSC Title")
            #expect(metadata.command == "active-command")
            #expect(metadata.currentPath == "/active")
            #expect(metadata.gitBranch == "active-branch")

            let windowNameData = SessionSortData.forLocalSession(
                session,
                paneStates: states,
                lastActivity: { _ in nil },
                sidebarFields: sidebarFields,
                sidebarTerminalFields: [.windowName]
            )
            #expect(windowNameData.primaryLabel == "active-window")

            let titleData = SessionSortData.forLocalSession(
                session,
                paneStates: states,
                lastActivity: { _ in nil },
                sidebarFields: sidebarFields,
                sidebarTerminalFields: [.terminalTitle]
            )
            #expect(titleData.primaryLabel == "Active OSC Title")
        }

        @Test("Remote labels use only the active window and pane metadata")
        func remoteLabelsUseActiveWindow() {
            let panes = [
                PaneState(
                    paneId: "%1", sessionName: "remote", windowIndex: 0,
                    command: "inactive-command", currentPath: "/inactive", isActive: true,
                    windowName: "inactive-window", terminalTitle: "Inactive OSC Title"
                ),
                PaneState(
                    paneId: "%2", sessionName: "remote", windowIndex: 1,
                    command: "active-command", currentPath: "/active", isActive: true,
                    windowName: "active-window", isWindowActive: true,
                    terminalTitle: "Active OSC Title", gitBranch: "active-branch"
                ),
            ]
            let session = TmuxSession.groupWindows(TmuxWindow.groupPanes(panes))[0]

            #expect(session.activeWindowMetadata == ActiveWindowMetadata(
                windowName: "active-window",
                terminalTitle: "Active OSC Title",
                command: "active-command",
                currentPath: "/active",
                gitBranch: "active-branch"
            ))

            let windowNameData = SessionSortData.forRemoteSession(
                session,
                sidebarFields: sidebarFields,
                sidebarTerminalFields: [.windowName],
                homeDirectory: nil
            )
            #expect(windowNameData.primaryLabel == "active-window")

            let titleData = SessionSortData.forRemoteSession(
                session,
                sidebarFields: sidebarFields,
                sidebarTerminalFields: [.terminalTitle],
                homeDirectory: nil
            )
            #expect(titleData.primaryLabel == "Active OSC Title")
        }
    }
#endif
