#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftUI

    struct WindowTabActions: View {
        let window: TmuxWindow?
        let focusedPaneID: String?
        let files: [FileBrowserTab]
        let browsers: [RemoteBrowserTab]
        let simulators: [RemoteSimulatorTab]
        let isConnected: Bool
        let canOpenFiles: Bool
        let canOpenBrowser: Bool
        let canOpenSimulator: Bool
        let canCreateSimulator: Bool
        let canCreateNewSimulator: Bool
        let canCreateIndependentResources: Bool
        let isCreatingWindow: Bool
        let forkUnavailableReason: String?
        let canForkOtherDirectory: Bool
        var includesWindowManagement = false
        var includesFork = true
        var restartUnavailableReason: String?
        var logoutUnavailableReason: String?
        var restartingAgentPaneIDs: Set<String> = []
        let choose: (WindowTabAction) -> Void

        func menuState(hostID: String) -> WindowTabMenuState {
            var state = WindowTabMenuState(hostID: hostID, window: window, focusedPaneID: focusedPaneID, files: files, browsers: browsers, simulators: simulators)
            state.isConnected = isConnected
            state.canOpenFiles = canOpenFiles
            state.canOpenBrowser = canOpenBrowser
            state.canOpenSimulator = canOpenSimulator
            state.canCreateSimulator = canCreateSimulator
            state.canCreateNewSimulator = canCreateNewSimulator
            state.canCreateIndependentResources = canCreateIndependentResources
            state.isCreatingWindow = isCreatingWindow
            state.forkUnavailableReason = forkUnavailableReason
            state.canForkOtherDirectory = canForkOtherDirectory
            state.includesWindowManagement = includesWindowManagement
            state.includesFork = includesFork
            state.restartUnavailableReason = restartUnavailableReason
            state.logoutUnavailableReason = logoutUnavailableReason
            state.restartingAgentPaneIDs = restartingAgentPaneIDs
            return state
        }

        var body: some View {
            if includesWindowManagement, let window {
                Button { choose(.window(stableID: window.stableId, operation: .rename)) } label: {
                    Label("Rename Tab", symbol: .pencil)
                }
                .disabled(!isConnected)
                Button(role: .destructive) { choose(.window(stableID: window.stableId, operation: .close)) } label: {
                    Label("Close Tab", symbol: .rectangleBadgeMinus)
                }
                .disabled(!isConnected)
                Divider()
            }
            openFilesButton(window)
            openBrowserButton(window)
            openSimulatorButton(window)
            newTabMenu(window)
            if includesFork, let window {
                forkMenu(window)
            }
        }

        @ViewBuilder
        var agentSessionActions: some View {
            if includesWindowManagement, includesFork, let window {
                AgentRestartMenu(panes: window.panes, unavailableReason: restartUnavailableReason, busyPaneIDs: restartingAgentPaneIDs) { source in
                    choose(.restartAgent(source))
                }
                AgentRestartMenu(panes: window.panes, unavailableReason: logoutUnavailableReason, busyPaneIDs: restartingAgentPaneIDs, logoutBeforeResume: true) { source in
                    choose(.restartAgent(source))
                }
            }
        }

        private func newTabMenu(_ window: TmuxWindow?) -> some View {
            let simulatorAction = WindowTabAction.simulatorCreation(
                window: window,
                preferredPaneID: focusedPaneID,
                simulators: simulators,
                supportsIndependentResources: canCreateIndependentResources,
                supportsPaneSimulator: canCreateSimulator,
                supportsNewSimulator: canCreateNewSimulator
            )
            return Menu {
                Group {
                    newAgentButton(window)
                    newTerminalButton(window)
                    Button {
                        if canCreateIndependentResources {
                            choose(.newResource(.browser))
                        } else if let window {
                            choose(.window(stableID: window.stableId, operation: .openBrowser))
                        }
                    } label: {
                        Label("New Browser", symbol: .globe)
                    }
                    .disabled(!canCreateIndependentResources && (!canOpenBrowser || window?.panes.isEmpty != false))
                    Button {
                        if canCreateIndependentResources {
                            choose(.newResource(.files))
                        } else if let window {
                            choose(.window(stableID: window.stableId, operation: .openAnotherFiles))
                        }
                    } label: {
                        Label("New Files", symbol: .folder)
                    }
                    .disabled(!canCreateIndependentResources && (!canOpenFiles || window?.panes.isEmpty != false))
                    Button {
                        if let simulatorAction {
                            choose(simulatorAction)
                        }
                    } label: {
                        Label("New iOS Simulator", symbol: .iphone)
                    }
                    .disabled(simulatorAction == nil)
                }
                .labelStyle(.titleAndIcon)
            } label: {
                Label("New Tab", symbol: .plus)
            }
            .disabled(!isConnected)
            .accessibilityIdentifier("window-new-tab-\(window?.stableId ?? "independent")")
        }

        private func newAgentButton(_ window: TmuxWindow?) -> some View {
            Button { choose(.newAgent) } label: {
                Label("New Agent…", symbol: .sparkles)
            }
            .disabled(!isConnected || isCreatingWindow)
            .accessibilityIdentifier("window-new-agent-\(window?.stableId ?? "independent")")
        }

        private func newTerminalButton(_ window: TmuxWindow?) -> some View {
            Button { choose(.newTerminal) } label: {
                Label("New Terminal", symbol: .terminal)
            }
            .disabled(!isConnected || isCreatingWindow)
            .accessibilityIdentifier("window-new-terminal-\(window?.stableId ?? "independent")")
        }

        private func tabs<T>(_ values: [T], in window: TmuxWindow?, sourcePaneID: (T) -> String?) -> [T] {
            guard let window else { return values.filter { sourcePaneID($0) == nil } }
            let paneIDs = Set(window.panes.map(\.paneId))
            return values.filter { sourcePaneID($0).map(paneIDs.contains) == true }
        }

        @ViewBuilder
        private func openFilesButton(_ window: TmuxWindow?) -> some View {
            let tabs = tabs(files, in: window, sourcePaneID: \.sourcePaneID)
            Group {
                if tabs.count > 1 {
                    Menu {
                        ForEach(tabs) { tab in
                            Button(tab.title) { choose(.selectFiles(tab.id)) }
                        }
                    } label: {
                        Label("Open Files", symbol: .folder)
                    }
                } else {
                    Button {
                        if let tab = tabs.first {
                            choose(.selectFiles(tab.id))
                        }
                    } label: {
                        Label("Open Files", symbol: .folder)
                    }
                }
            }
            .disabled(!isConnected || tabs.isEmpty)
            .accessibilityHint("Choose an existing Files tab.")
            .accessibilityIdentifier("window-open-files-\(window?.stableId ?? "independent")")
        }

        @ViewBuilder
        private func openBrowserButton(_ window: TmuxWindow?) -> some View {
            let tabs = tabs(browsers, in: window, sourcePaneID: \.sourcePaneID)
            Group {
                if tabs.count > 1 {
                    Menu {
                        ForEach(tabs) { tab in
                            Button(tab.title.isEmpty ? "Browser" : tab.title) { choose(.selectBrowser(tab.id)) }
                        }
                    } label: {
                        Label("Open Browser", symbol: .globe)
                    }
                } else {
                    Button {
                        if let tab = tabs.first {
                            choose(.selectBrowser(tab.id))
                        }
                    } label: {
                        Label("Open Browser", symbol: .globe)
                    }
                }
            }
            .disabled(!isConnected || tabs.isEmpty)
            .accessibilityHint("Choose an existing Browser tab.")
            .accessibilityIdentifier("window-open-browser-\(window?.stableId ?? "independent")")
        }

        @ViewBuilder
        private func openSimulatorButton(_ window: TmuxWindow?) -> some View {
            let tabs = tabs(simulators, in: window, sourcePaneID: \.sourcePaneID)
            Group {
                if tabs.count > 1 {
                    Menu {
                        ForEach(tabs) { tab in
                            Button(tab.title) { choose(.selectSimulator(tab.id)) }
                        }
                    } label: {
                        Label("Open iOS Simulator", symbol: .iphone)
                    }
                } else {
                    Button {
                        if let tab = tabs.first {
                            choose(.selectSimulator(tab.id))
                        }
                    } label: {
                        Label("Open iOS Simulator", symbol: .iphone)
                    }
                }
            }
            .disabled(!isConnected || !canOpenSimulator || tabs.isEmpty)
            .accessibilityHint("Choose an existing iOS simulator.")
            .accessibilityIdentifier("window-open-simulator-\(window?.stableId ?? "independent")")
        }

        private func forkMenu(_ window: TmuxWindow) -> some View {
            AgentForkMenu(
                sources: AgentForkConfiguration.orderedSources(panes: window.panes, focusedPaneID: focusedPaneID),
                unavailableReason: forkUnavailableReason,
                sourceUnavailableReason: AgentForkSource.unavailableReason(panes: window.panes),
                allowsOtherDirectory: canForkOtherDirectory
            ) { destination in
                choose(.window(stableID: window.stableId, operation: .fork(destination: destination)))
            }
            .disabled(!isConnected || isCreatingWindow)
            .accessibilityIdentifier("window-fork-\(window.stableId)")
        }
    }
#endif
