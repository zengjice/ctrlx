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
        var canCloseSimulator = false
        let isConnected: Bool
        let isCreatingWindow: Bool
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
                    HStack {
                        Button { choose(.selectSimulator(id)) } label: {
                            HStack {
                                Label(tab.title, symbol: .iphone).lineLimit(1)
                                Spacer()
                                if selectedSimulatorID == id {
                                    Symbols.checkmark.image
                                }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Menu {
                            Button("Close Tab", role: .destructive) { choose(.closeSimulator(id)) }
                                .disabled(!isConnected || !canCloseSimulator)
                        } label: {
                            Label("Simulator Actions", symbol: .ellipsisCircle).labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 44)
                        }.buttonStyle(.borderless)
                    }
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
                            Button("Close Tab", role: .destructive) { choose(.closeBrowser(id)) }.disabled(!isConnected)
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
            return windowSelection(window, name: name)
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
                    Button("Close Tab", role: .destructive) { choose(.closeFiles(tab.id)) }
                        .disabled(tab.hostTab != nil && !isConnected)
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
