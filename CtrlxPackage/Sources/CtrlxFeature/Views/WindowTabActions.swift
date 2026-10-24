#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftUI

    struct WindowTabActions: View {
        let window: TmuxWindow
        let focusedPaneID: String?
        let files: [FileBrowserTab]
        let browsers: [RemoteBrowserTab]
        let simulators: [RemoteSimulatorTab]
        let activeTab: WindowTabKind
        let isConnected: Bool
        let canOpenFiles: Bool
        let canOpenBrowser: Bool
        let canOpenSimulator: Bool
        let canCreateSimulator: Bool
        let canCreateNewSimulator: Bool
        let isCreatingWindow: Bool
        let forkUnavailableReason: String?
        let canForkOtherDirectory: Bool
        var includesWindowManagement = false
        var includesFork = true
        let choose: (WindowTabAction) -> Void

        var body: some View {
            if includesWindowManagement {
                Button { choose(.window(stableID: window.stableId, operation: .rename)) } label: {
                    Label("Rename Window", symbol: .pencil)
                }
                .disabled(!isConnected)
                Button(role: .destructive) { choose(.window(stableID: window.stableId, operation: .close)) } label: {
                    Label("Close Tab", symbol: .rectangleBadgeMinus)
                }
                .disabled(!isConnected)
                Divider()
            }
            newAgentButton(window)
            newTerminalButton(window)
            openFilesButton(window)
            if includesWindowManagement {
                Button { choose(.window(stableID: window.stableId, operation: .openAnotherFiles)) } label: {
                    shortcutLabel("Open Another Files Tab", symbol: .folder, showsNewBadge: true)
                }
                .disabled(!isConnected || !canOpenFiles || window.panes.isEmpty)
            }
            openBrowserButton(window)
            openSimulatorButton(window)
            if includesFork {
                forkMenu(window)
            }
        }

        private func newAgentButton(_ window: TmuxWindow) -> some View {
            Button { choose(.newAgent) } label: {
                Label("New Agent…", symbol: .sparkles)
            }
            .disabled(!isConnected || isCreatingWindow)
            .accessibilityIdentifier("window-new-agent-\(window.stableId)")
        }

        private func newTerminalButton(_ window: TmuxWindow) -> some View {
            Button { choose(.newTerminal) } label: {
                Label("New Terminal", symbol: .terminal)
            }
            .disabled(!isConnected || isCreatingWindow)
            .accessibilityIdentifier("window-new-terminal-\(window.stableId)")
        }

        private func shortcutLabel(_ title: String, symbol: Symbols, showsNewBadge: Bool) -> some View {
            Label {
                Text(title)
            } icon: {
                symbol.image
                    .overlay(alignment: .topTrailing) {
                        if showsNewBadge {
                            Symbols.plus.image
                                .font(.system(size: 8, weight: .bold))
                                .offset(x: 4, y: -4)
                                .accessibilityHidden(true)
                        }
                    }
            }
        }

        private func tabs<T>(_ values: [T], in window: TmuxWindow, sourcePaneID: (T) -> String?) -> [T] {
            let paneIDs = Set(window.panes.map(\.paneId))
            return values.filter { sourcePaneID($0).map(paneIDs.contains) == true }
        }

        @ViewBuilder
        private func openFilesButton(_ window: TmuxWindow) -> some View {
            let mode = WindowTabKind.files.shortcutMode(whenActive: activeTab)
            let tabs = tabs(files, in: window, sourcePaneID: \.sourcePaneID)
            Group {
                if mode == .create {
                    Button { choose(.window(stableID: window.stableId, operation: .openAnotherFiles)) } label: {
                        shortcutLabel("New Files Tab", symbol: .folder, showsNewBadge: true)
                    }
                    .disabled(!isConnected || !canOpenFiles || window.panes.isEmpty)
                    .accessibilityHint("Create another Files tab for this window.")
                } else if tabs.count > 1 {
                    Menu {
                        ForEach(tabs) { tab in
                            Button(tab.title) { choose(.selectFiles(tab.id)) }
                        }
                    } label: {
                        shortcutLabel("Open Files", symbol: .folder, showsNewBadge: false)
                    }
                    .disabled(!isConnected)
                } else {
                    Button {
                        if let tab = tabs.first {
                            choose(.selectFiles(tab.id))
                        } else {
                            choose(.window(stableID: window.stableId, operation: .openFiles))
                        }
                    } label: {
                        shortcutLabel("Open Files", symbol: .folder, showsNewBadge: false)
                    }
                    .disabled(!isConnected || (tabs.isEmpty && (!canOpenFiles || window.panes.isEmpty)))
                    .accessibilityHint(tabs.isEmpty ? "Open Files for this window." : "Show this window's Files tab.")
                }
            }
            .accessibilityIdentifier("window-open-files-\(window.stableId)")
        }

        @ViewBuilder
        private func openBrowserButton(_ window: TmuxWindow) -> some View {
            let mode = WindowTabKind.browser.shortcutMode(whenActive: activeTab)
            let tabs = tabs(browsers, in: window, sourcePaneID: \.sourcePaneID)
            Group {
                if mode == .create {
                    Button { choose(.window(stableID: window.stableId, operation: .openBrowser)) } label: {
                        shortcutLabel("New Browser Tab", symbol: .globe, showsNewBadge: true)
                    }
                    .disabled(!isConnected || !canOpenBrowser || window.panes.isEmpty)
                    .accessibilityHint("Create another Browser tab for this window.")
                } else if tabs.count > 1 {
                    Menu {
                        ForEach(tabs) { tab in
                            Button(tab.title.isEmpty ? "Browser" : tab.title) { choose(.selectBrowser(tab.id)) }
                        }
                    } label: {
                        shortcutLabel("Open Browser", symbol: .globe, showsNewBadge: false)
                    }
                    .disabled(!isConnected)
                } else {
                    Button {
                        if let tab = tabs.first {
                            choose(.selectBrowser(tab.id))
                        } else {
                            choose(.window(stableID: window.stableId, operation: .openBrowser))
                        }
                    } label: {
                        shortcutLabel("Open Browser", symbol: .globe, showsNewBadge: false)
                    }
                    .disabled(!isConnected || (tabs.isEmpty && (!canOpenBrowser || window.panes.isEmpty)))
                    .accessibilityHint(tabs.isEmpty ? "Open Browser on Host." : "Show this window's Browser tab.")
                }
            }
            .accessibilityIdentifier("window-open-browser-\(window.stableId)")
        }

        @ViewBuilder
        private func openSimulatorButton(_ window: TmuxWindow) -> some View {
            let mode = WindowTabKind.simulator.shortcutMode(whenActive: activeTab, canCreate: canCreateNewSimulator)
            let tabs = tabs(simulators, in: window, sourcePaneID: \.sourcePaneID)
            Group {
                if mode == .unavailable {
                    Button { } label: {
                        shortcutLabel("New iOS Simulator", symbol: .iphone, showsNewBadge: false)
                    }
                    .disabled(true)
                    .accessibilityLabel("New iOS Simulator Unavailable")
                    .accessibilityHint("Update the Host Mac to create another iOS simulator.")
                } else if mode == .create {
                    Button { choose(.window(stableID: window.stableId, operation: .openNewSimulator)) } label: {
                        shortcutLabel("New iOS Simulator", symbol: .iphone, showsNewBadge: true)
                    }
                    .disabled(!isConnected || !canCreateSimulator || window.panes.isEmpty)
                    .accessibilityHint("Create another iOS simulator for this window.")
                } else if tabs.count > 1 {
                    Menu {
                        ForEach(tabs) { tab in
                            Button(tab.title) { choose(.selectSimulator(tab.id)) }
                        }
                    } label: {
                        shortcutLabel("Open iOS Simulator", symbol: .iphone, showsNewBadge: false)
                    }
                    .disabled(!isConnected || !canOpenSimulator)
                    .accessibilityHint("Choose this window's iOS simulator on the Host.")
                } else {
                    Button {
                        if let tab = tabs.first {
                            choose(.selectSimulator(tab.id))
                        } else {
                            choose(.window(stableID: window.stableId, operation: .openSimulator))
                        }
                    } label: {
                        shortcutLabel("Open iOS Simulator", symbol: .iphone, showsNewBadge: false)
                    }
                    .disabled(!isConnected || (tabs.isEmpty ? !canCreateSimulator || window.panes.isEmpty : !canOpenSimulator))
                    .accessibilityHint(tabs.isEmpty ? "Create and open an iOS simulator on the Host." : "View this window's iOS simulator on the Host.")
                }
            }
            .accessibilityIdentifier("window-open-simulator-\(window.stableId)")
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
