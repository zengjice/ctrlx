#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftUI

    struct WindowTabsPanel: View {
        let windows: [TmuxWindow]
        let files: [FileBrowserTab]
        var browsers: [RemoteBrowserTab] = []
        let selectedWindowID: String?
        let selectedFileID: UUID?
        var selectedBrowserID: UUID?
        let isConnected: Bool
        let canOpenFiles: Bool
        var canOpenBrowser: Bool = false
        let isCreatingWindow: Bool
        let forkUnavailableReason: String?
        let onChoose: (WindowTabAction) -> Void
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Text("Tabs").font(.headline)
                    Spacer()
                    Button("Done") { dismiss() }
                }
                .padding()

                List {
                    Section("Windows") {
                        ForEach(windows, id: \.stableId) { window in
                            windowRow(window)
                        }
                    }
                    if !files.isEmpty {
                        Section("Files") {
                            ForEach(files) { tab in
                                fileRow(tab)
                            }
                        }
                    }
                    if !browsers.isEmpty {
                        Section("Browsers on Host") {
                            ForEach(browsers) { tab in
                                HStack {
                                    Button { choose(.selectBrowser(tab.id)) } label: {
                                        HStack {
                                            Label(tab.title.isEmpty ? "Browser" : tab.title, symbol: .globe).lineLimit(1)
                                            Spacer()
                                            if selectedBrowserID == tab.id { Symbols.checkmark.image }
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    Menu {
                                        Button("Close Browser on Host", role: .destructive) { choose(.closeBrowser(tab.id)) }
                                            .disabled(!isConnected)
                                    } label: {
                                        Label("Browser Actions", symbol: .ellipsisCircle).labelStyle(.iconOnly)
                                            .frame(minWidth: 44, minHeight: 44)
                                    }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                    Section {
                        Button { choose(.newTerminal) } label: {
                            Label("New Terminal", symbol: .terminal)
                        }
                        .disabled(!isConnected || isCreatingWindow)
                        Button { choose(.newAgent) } label: {
                            Label("New Agent…", symbol: .sparkles)
                        }
                        .disabled(!isConnected || isCreatingWindow)
                        .accessibilityIdentifier("new-agent-window")
                        Button { choose(.newBrowser) } label: {
                            Label("New Browser on Host", symbol: .globe)
                        }
                        .disabled(!isConnected || !canOpenBrowser || isCreatingWindow)
                        Text("Chromium pages run on the Host. WebKit pages are local-only.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("window-tabs-panel")
        }

        private func windowRow(_ window: TmuxWindow) -> some View {
            let name = window.windowName.isEmpty ? "Window \(window.windowIndex)" : window.windowName
            return HStack {
                Button { choose(.window(stableID: window.stableId, operation: .select)) } label: {
                    HStack {
                        Label(name, symbol: window.hasClaude ? .sparkles : .terminal)
                            .lineLimit(1)
                        Spacer()
                        if selectedWindowID == window.stableId, selectedFileID == nil, selectedBrowserID == nil {
                            Symbols.checkmark.image
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("select-window-\(window.stableId)")

                Menu {
                    Button { choose(.window(stableID: window.stableId, operation: .openFiles)) } label: {
                        Label("Open Files", symbol: .folderBadgePlus)
                    }
                    .disabled(!canOpenFiles || window.panes.isEmpty)

                    AgentForkMenu(
                        sources: AgentForkConfiguration.orderedSources(panes: window.panes, focusedPaneID: nil),
                        unavailableReason: forkUnavailableReason,
                        sourceUnavailableReason: AgentForkSource.unavailableReason(panes: window.panes)
                    ) { usingWorktree in
                        choose(.window(stableID: window.stableId, operation: .fork(usingWorktree: usingWorktree)))
                    }
                    .disabled(isCreatingWindow)

                    Divider()
                    Button { choose(.window(stableID: window.stableId, operation: .rename)) } label: {
                        Label("Rename Window", symbol: .pencil)
                    }
                    .disabled(!isConnected)
                    if windows.count > 1 {
                        Button(role: .destructive) { choose(.window(stableID: window.stableId, operation: .close)) } label: {
                            Label("Close Window", symbol: .rectangleBadgeMinus)
                        }
                        .disabled(!isConnected)
                    }
                } label: {
                    Label("Actions for \(name)", symbol: .ellipsisCircle)
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("window-actions-\(window.stableId)")
            }
        }

        private func fileRow(_ tab: FileBrowserTab) -> some View {
            HStack {
                Button { choose(.selectFiles(tab.id)) } label: {
                    HStack {
                        Label(tab.title, symbol: .folder).lineLimit(1)
                        Spacer()
                        if selectedFileID == tab.id { Symbols.checkmark.image }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Menu {
                    Button("Close Files Tab", role: .destructive) { choose(.closeFiles(tab.id)) }
                } label: {
                    Label("Actions for \(tab.title)", symbol: .ellipsisCircle)
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
            }
        }

        private func choose(_ action: WindowTabAction) {
            onChoose(action)
            dismiss()
        }
    }
#endif
