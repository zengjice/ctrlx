#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftUI

    struct WindowTabActions: View {
        let window: TmuxWindow
        let focusedPaneID: String?
        let simulators: [RemoteSimulatorTab]
        let isConnected: Bool
        let canOpenFiles: Bool
        let canOpenBrowser: Bool
        let canOpenSimulator: Bool
        let canCreateSimulator: Bool
        let isCreatingWindow: Bool
        let forkUnavailableReason: String?
        var includesWindowManagement = false
        let choose: (WindowTabAction) -> Void

        var body: some View {
            if includesWindowManagement {
                Button { choose(.window(stableID: window.stableId, operation: .rename)) } label: {
                    Label("Rename Window", symbol: .pencil)
                }
                .disabled(!isConnected)
                Button(role: .destructive) { choose(.window(stableID: window.stableId, operation: .close)) } label: {
                    Label("Close Window", symbol: .rectangleBadgeMinus)
                }
                .disabled(!isConnected)
                Divider()
            }
            openFilesButton(window)
            if includesWindowManagement {
                Button { choose(.window(stableID: window.stableId, operation: .openAnotherFiles)) } label: {
                    Label("Open Another Files Tab", symbol: .folderBadgePlus)
                }
                .disabled(!isConnected || !canOpenFiles || window.panes.isEmpty)
            }
            openBrowserButton(window)
            openSimulatorButton(window)
            forkMenu(window)
        }

        private func openFilesButton(_ window: TmuxWindow) -> some View {
            Button { choose(.window(stableID: window.stableId, operation: .openFiles)) } label: {
                Label("Open Files", symbol: .folderBadgePlus)
            }
            .disabled(!isConnected || !canOpenFiles || window.panes.isEmpty)
            .accessibilityIdentifier("window-open-files-\(window.stableId)")
        }

        private func openBrowserButton(_ window: TmuxWindow) -> some View {
            Button { choose(.window(stableID: window.stableId, operation: .openBrowser)) } label: {
                Label("Open Browser on Host", symbol: .globe)
            }
            .disabled(!isConnected || !canOpenBrowser || window.panes.isEmpty)
            .accessibilityIdentifier("window-open-browser-\(window.stableId)")
        }

        @ViewBuilder
        private func openSimulatorButton(_ window: TmuxWindow) -> some View {
            let tabs = simulators.filter { tab in window.panes.contains { $0.paneId == tab.sourcePaneID } }
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
                        } else {
                            choose(.window(stableID: window.stableId, operation: .openSimulator))
                        }
                    } label: {
                        Label("Open iOS Simulator", symbol: .iphone)
                    }
                }
            }
            .disabled(!isConnected || (tabs.isEmpty ? !canCreateSimulator || window.panes.isEmpty : !canOpenSimulator))
            .accessibilityHint(tabs.isEmpty ? "Create and open an iOS simulator on the Host." : "View this window's iOS simulator on the Host.")
            .accessibilityIdentifier("window-open-simulator-\(window.stableId)")
        }

        private func forkMenu(_ window: TmuxWindow) -> some View {
            AgentForkMenu(
                sources: AgentForkConfiguration.orderedSources(panes: window.panes, focusedPaneID: focusedPaneID),
                unavailableReason: forkUnavailableReason,
                sourceUnavailableReason: AgentForkSource.unavailableReason(panes: window.panes)
            ) { usingWorktree in
                choose(.window(stableID: window.stableId, operation: .fork(usingWorktree: usingWorktree)))
            }
            .disabled(!isConnected || isCreatingWindow)
            .accessibilityIdentifier("window-fork-\(window.stableId)")
        }
    }
#endif
