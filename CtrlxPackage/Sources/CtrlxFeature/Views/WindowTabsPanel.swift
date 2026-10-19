#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftUI

    struct WindowTabsPanel: View {
        let windows: [TmuxWindow]
        let files: [FileBrowserTab]
        var browsers: [RemoteBrowserTab] = []
        var simulators: [RemoteSimulatorTab] = []
        let selectedWindowID: String?
        let selectedFileID: UUID?
        var selectedBrowserID: UUID?
        var selectedSimulatorID: UUID?
        let isConnected: Bool
        let canOpenFiles: Bool
        var canOpenBrowser = false
        let isCreatingWindow: Bool
        let forkUnavailableReason: String?
        let onChoose: (WindowTabAction) -> Void
        let onReorderWindows: ([String]) async throws -> Void
        let onReorderFiles: ([UUID]) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var pendingWindowOrder: [String]?
        @State private var reorderError: String?

        private var orderedWindows: [TmuxWindow] {
            guard let pendingWindowOrder else { return windows }
            return RemoteSessionOrder.applying(pendingWindowOrder, to: windows, sessionName: \.stableId)
        }

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
                        ForEach(orderedWindows, id: \.stableId) { window in
                            windowRow(window)
                                .moveDisabled(!isConnected || pendingWindowOrder != nil)
                        }
                        .onMove { source, destination in
                            guard isConnected, pendingWindowOrder == nil else { return }
                            let ids = windows.map(\.stableId)
                            let reordered = RemoteSessionOrder.moving(ids, fromOffsets: source, toOffset: destination)
                            if reordered != ids {
                                pendingWindowOrder = reordered
                            }
                        }
                    }
                    if !files.isEmpty {
                        Section("Files") {
                            ForEach(files) { tab in
                                fileRow(tab)
                            }
                            .onMove { source, destination in
                                var ids = files.map(\.id)
                                ids.move(fromOffsets: source, toOffset: destination)
                                onReorderFiles(ids)
                            }
                        }
                    }
                    if !simulators.isEmpty {
                        Section("iOS Simulators on Host") {
                            ForEach(simulators) { tab in
                                Button { choose(.selectSimulator(tab.id)) } label: {
                                    HStack {
                                        Label(tab.title, symbol: .iphone).lineLimit(1)
                                        Spacer()
                                        if selectedSimulatorID == tab.id {
                                            Symbols.checkmark.image
                                        }
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
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
                                            if selectedBrowserID == tab.id {
                                                Symbols.checkmark.image
                                            }
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
                    }
                }
            }
            .accessibilityIdentifier("window-tabs-panel")
            .task(id: pendingWindowOrder) {
                guard let order = pendingWindowOrder else { return }
                defer { pendingWindowOrder = nil }
                do {
                    try await onReorderWindows(order)
                } catch is CancellationError { }
                catch { reorderError = error.localizedDescription }
            }
            .alert("Could Not Reorder Tabs", isPresented: .init(
                get: { reorderError != nil },
                set: {
                    if !$0 {
                        reorderError = nil
                    }
                }
            )) {
                Button("OK") { reorderError = nil }
            } message: {
                Text(reorderError ?? "")
            }
        }

        private func windowRow(_ window: TmuxWindow) -> some View {
            let name = window.windowName.isEmpty ? "Window \(window.windowIndex)" : window.windowName
            return HStack {
                Button { choose(.window(stableID: window.stableId, operation: .select)) } label: {
                    HStack {
                        Label(name, symbol: window.hasClaude ? .sparkles : .terminal)
                            .lineLimit(1)
                        Spacer()
                        if selectedWindowID == window.stableId, selectedFileID == nil, selectedBrowserID == nil, selectedSimulatorID == nil {
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

                    Button { choose(.window(stableID: window.stableId, operation: .openAnotherFiles)) } label: {
                        Label("Open Another Files Tab", symbol: .folderBadgePlus)
                    }
                    .disabled(!canOpenFiles || window.panes.isEmpty)

                    Button { choose(.window(stableID: window.stableId, operation: .openBrowser)) } label: {
                        Label("Open Browser on Host", symbol: .globe)
                    }
                    .disabled(!isConnected || !canOpenBrowser || window.panes.isEmpty)
                    .accessibilityIdentifier("window-open-browser-\(window.stableId)")

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
                    Button(role: .destructive) { choose(.window(stableID: window.stableId, operation: .close)) } label: {
                        Label("Close Window", symbol: .rectangleBadgeMinus)
                    }
                    .disabled(!isConnected)
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
                        if selectedFileID == tab.id {
                            Symbols.checkmark.image
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Menu {
                    Button(tab.hostTab == nil ? "Close Files Tab" : "Close Files on Host", role: .destructive) { choose(.closeFiles(tab.id)) }
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
