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
        var canOpenSimulator = false
        var canCreateSimulator = false
        let isCreatingWindow: Bool
        let forkUnavailableReason: String?
        let onChoose: (WindowTabAction) -> Void
        let onReorderWindows: ([String]) async throws -> Void
        let linkedTabOrder: [PaneLinkedTabID]
        let onReorderLinkedTabs: ([PaneLinkedTabID]) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var pendingWindowOrder: [String]?
        @State private var reorderError: String?

        private var orderedWindows: [TmuxWindow] {
            guard let pendingWindowOrder else { return windows }
            return RemoteSessionOrder.applying(pendingWindowOrder, to: windows, sessionName: \.stableId)
        }

        private var linkedTabs: IOSPaneLinkedTabs {
            IOSPaneLinkedTabs(files: files, browsers: browsers, simulators: simulators, windows: orderedWindows, storedOrder: linkedTabOrder)
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
                    ForEach(linkedTabs.groups) { group in
                        let color = PaneTabGroupStyle.color(for: linkedTabs.colorKey(for: group.id))
                        Section {
                            ForEach(group.items, id: \.self) { item in
                                linkedRow(item)
                                    .listRowBackground(
                                        PaneTabGroupRowBorder(first: item == group.items.first, last: item == group.items.last)
                                            .stroke(color.opacity(0.65), lineWidth: 1)
                                            .background(Color(uiColor: .secondarySystemGroupedBackground))
                                    )
                            }
                            .onMove { source, destination in
                                onReorderLinkedTabs(linkedTabs.moving(source, to: destination, in: group))
                            }
                        } header: {
                            Text(linkedTabs.title(for: group.id)).foregroundStyle(color)
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

        @ViewBuilder
        private func linkedRow(_ item: PaneLinkedTabID) -> some View {
            switch item {
            case let .file(id):
                if let tab = files.first(where: { $0.id == id }) {
                    fileRow(tab)
                }
            case let .simulator(id):
                if let tab = simulators.first(where: { $0.id == id }) {
                    Button { choose(.selectSimulator(id)) } label: {
                        HStack {
                            Label(tab.title, symbol: .iphone).lineLimit(1)
                            Spacer()
                            if selectedSimulatorID == id {
                                Symbols.checkmark.image
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            case let .browser(id):
                if let tab = browsers.first(where: { $0.id == id }) {
                    HStack {
                        Button { choose(.selectBrowser(id)) } label: {
                            HStack {
                                Label(tab.title.isEmpty ? "Browser" : tab.title, symbol: .globe).lineLimit(1)
                                Spacer()
                                if selectedBrowserID == id {
                                    Symbols.checkmark.image
                                }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Menu {
                            Button("Close Browser on Host", role: .destructive) { choose(.closeBrowser(id)) }.disabled(!isConnected)
                        } label: {
                            Label("Browser Actions", symbol: .ellipsisCircle).labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 44)
                        }.buttonStyle(.borderless)
                    }
                }
            }
        }

        private func windowRow(_ window: TmuxWindow) -> some View {
            let name = window.windowName.isEmpty ? "Window \(window.windowIndex)" : window.windowName
            return ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    windowSelection(window, name: name)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    windowShortcuts(window)
                    windowMenu(window, name: name)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        windowSelection(window, name: name)
                        windowMenu(window, name: name)
                    }
                    windowShortcuts(window)
                }
            }
        }

        private func windowSelection(_ window: TmuxWindow, name: String) -> some View {
            Button { choose(.window(stableID: window.stableId, operation: .select)) } label: {
                HStack {
                    Label(name, symbol: window.hasClaude ? .sparkles : .terminal)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if selectedWindowID == window.stableId, selectedFileID == nil, selectedBrowserID == nil, selectedSimulatorID == nil {
                        Symbols.checkmark.image
                            .padding(.leading, 6)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("select-window-\(window.stableId)")
        }

        private func windowShortcuts(_ window: TmuxWindow) -> some View {
            HStack(spacing: 4) {
                Group {
                    openFilesButton(window)
                    openBrowserButton(window)
                    openSimulatorButton(window)
                    forkMenu(window)
                }
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
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
                sources: AgentForkConfiguration.orderedSources(panes: window.panes, focusedPaneID: nil),
                unavailableReason: forkUnavailableReason,
                sourceUnavailableReason: AgentForkSource.unavailableReason(panes: window.panes)
            ) { usingWorktree in
                choose(.window(stableID: window.stableId, operation: .fork(usingWorktree: usingWorktree)))
            }
            .disabled(!isConnected || isCreatingWindow)
            .accessibilityIdentifier("window-fork-\(window.stableId)")
        }

        private func windowMenu(_ window: TmuxWindow, name: String) -> some View {
            Menu {
                Button { choose(.window(stableID: window.stableId, operation: .rename)) } label: {
                    Label("Rename Window", symbol: .pencil)
                }
                .disabled(!isConnected)
                Button(role: .destructive) { choose(.window(stableID: window.stableId, operation: .close)) } label: {
                    Label("Close Window", symbol: .rectangleBadgeMinus)
                }
                .disabled(!isConnected)
                Divider()
                openFilesButton(window)
                Button { choose(.window(stableID: window.stableId, operation: .openAnotherFiles)) } label: {
                    Label("Open Another Files Tab", symbol: .folderBadgePlus)
                }
                .disabled(!isConnected || !canOpenFiles || window.panes.isEmpty)
                openBrowserButton(window)
                openSimulatorButton(window)
                forkMenu(window)
            } label: {
                Label("Actions for \(name)", symbol: .ellipsisCircle)
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .menuOrder(.fixed)
            .accessibilityIdentifier("window-actions-\(window.stableId)")
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
