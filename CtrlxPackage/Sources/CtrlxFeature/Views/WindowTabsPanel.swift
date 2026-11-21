#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftUI
    import UniformTypeIdentifiers

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
        var canCreateIndependentResources = false
        let isConnected: Bool
        let isCreatingWindow: Bool
        let onChoose: (WindowTabAction) -> Void
        let onReorderWindows: ([String]) async throws -> Void
        var topLevelTabOrder: [IOSTopLevelTabID] = []
        var onReorderTopLevel: ([IOSTopLevelTabID]) -> Void = { _ in }
        let linkedTabOrder: [PaneLinkedTabID]
        let onReorderLinkedTabs: ([PaneLinkedTabID]) -> Void
        var sharedSessionID: UUID?
        var sharedTabLayout: SessionTabLayout?
        var onEditSharedTabs: ((SessionTabLayout.Edit) async throws -> Void)?
        @Environment(\.dismiss) private var dismiss
        @State private var pendingWindowOrder: [String]?
        @State private var reorderError: String?
        @State private var expandedGroup: SessionTabGroup?

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

                if let layout = sharedTabLayout {
                    ScrollView {
                        VStack(spacing: 16) {
                            LazyVStack(spacing: 0) { sharedTabs(layout) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.background)
                            VStack(alignment: .leading, spacing: 0) { newTabButtons }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.background)
                        }
                        .padding(.bottom, 16)
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                } else {
                    List {
                        legacyTabs
                        Section { newTabButtons }
                    }
                    .listStyle(.grouped)
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

        @ViewBuilder private var newTabButtons: some View {
            Button { choose(.newTerminal) } label: {
                Label("New Terminal", symbol: .terminal).frame(minHeight: 34)
            }
            .disabled(!isConnected || isCreatingWindow)
            Button { choose(.newAgent) } label: {
                Label("New Agent…", symbol: .sparkles).frame(minHeight: 34)
            }
            .disabled(!isConnected || isCreatingWindow)
            .accessibilityIdentifier("new-agent-window")
            if canCreateIndependentResources {
                Group {
                    Button { choose(.newResource(.files)) } label: { Label("New Files", symbol: .folder).frame(minHeight: 34) }
                    Button { choose(.newResource(.browser)) } label: { Label("New Browser", symbol: .globe).frame(minHeight: 34) }
                    Button { choose(.newResource(.simulator)) } label: { Label("New iOS Simulator", symbol: .iphone).frame(minHeight: 34) }
                }.disabled(!isConnected)
            }
        }

        @ViewBuilder private var legacyTabs: some View {
            if canCreateIndependentResources {
                Section("Tabs") {
                    ForEach(linkedTabs.topLevel(stored: topLevelTabOrder), id: \.self) { item in
                        switch item {
                        case let .resource(id): linkedRow(id)
                        default:
                            if let window = orderedWindows.first(where: { IOSTopLevelTabID(window: $0) == item }) {
                                windowRow(window)
                            }
                        }
                    }
                    .onMove { source, destination in
                        onReorderTopLevel(linkedTabs.movingTopLevel(source, to: destination, stored: topLevelTabOrder))
                    }
                }
            } else {
                Section("Windows") {
                    ForEach(orderedWindows, id: \.stableId) { window in
                        windowRow(window).moveDisabled(!isConnected || pendingWindowOrder != nil)
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
                if let independent = linkedTabs.groups.first(where: { $0.id == nil }) {
                    Section("Resources") { ForEach(independent.items, id: \.self) { linkedRow($0) } }
                }
            }
            ForEach(linkedTabs.groups.filter { $0.id != nil }) { group in
                if let pane = group.id {
                    let id = SessionTabGroup.pane(pane)
                    DisclosureGroup(isExpanded: expansion(id)) {
                        ForEach(group.items, id: \.self) { linkedRow($0) }
                            .onMove { source, destination in
                                onReorderLinkedTabs(linkedTabs.moving(source, to: destination, in: group))
                            }
                    } label: {
                        groupLabel(linkedTabs.title(for: pane), count: group.items.count, colorKey: linkedTabs.colorKey(for: pane))
                    }
                }
            }
        }

        private var resources: [SessionTabID: PaneLinkedTabID] {
            Dictionary(linkedTabs.items.map { ($0.sessionTabID, $0) }, uniquingKeysWith: { first, _ in first })
        }

        private var sharedWindows: [SessionTabID: TmuxWindow] {
            Dictionary(orderedWindows.compactMap { window in
                window.sessionTabID.map { ($0, window) }
            }, uniquingKeysWith: { first, _ in first })
        }

        private func sharedTabs(_ layout: SessionTabLayout) -> some View {
            let windows = sharedWindows
            let resources = resources
            let entries = linkedTabs.sharedEntries(layout, topLevelOrder: topLevelTabOrder)
            let tabs = entries.flatMap(\.tabs)
            return Group {
                ForEach(orderedWindows.filter { $0.sessionTabID == nil }, id: \.stableId) { window in
                    windowRow(window).frame(minHeight: 44).padding(.horizontal, 14)
                }
                ForEach(entries) { entry in
                    switch entry {
                    case let .tab(tab):
                        editTarget(tab) { sharedRow(tab, windows: windows, resources: resources) }
                    case let .group(group, tabs):
                        if let first = tabs.first {
                            DisclosureGroup(isExpanded: expansion(group)) {
                                ForEach(tabs, id: \.self) { tab in
                                    editTarget(tab, members: tabs) { sharedRow(tab, windows: windows, resources: resources) }
                                }
                            } label: {
                                let title = group.paneID.map { linkedTabs.title(for: $0) } ?? tabTitle(first, windows: windows, resources: resources)
                                let key = group.paneID.flatMap { linkedTabs.colorKey(for: $0) } ?? String(describing: group)
                                groupLabel(title, count: tabs.count, colorKey: key).frame(minHeight: 44).contentShape(.rect)
                                    .dropDestination(for: SessionTabDrag.self) { values, _ in
                                        acceptDrop(values, targets: tabs, merge: true)
                                    }
                                    .contextMenu {
                                        if group.paneID == nil {
                                            Button("Ungroup Tabs") { edit(.ungroup(first)) }.disabled(!isConnected)
                                        }
                                    }
                            }
                            .padding(.horizontal, 14)
                        }
                    }
                }
                if
                    (isConnected && tabs.filter(isShareable).count > 1)
                    || (entries.count > 1 && entries.contains { entry in
                        if case let .tab(tab) = entry {
                            return linkedTabs.isPrivateFile(tab)
                        }
                        return false
                    }) {
                    Color.clear.frame(height: 14).contentShape(.rect)
                        .dropDestination(for: SessionTabDrag.self) { values, _ in
                            acceptDrop(values, targets: [], merge: false)
                        }
                        .accessibilityHidden(true)
                }
            }
        }

        @ViewBuilder
        private func editTarget<Content: View>(_ tab: SessionTabID, members: [SessionTabID]? = nil, @ViewBuilder content: () -> Content) -> some View {
            let row = content().frame(minHeight: 44).padding(.horizontal, 14).contentShape(.rect)
                .dropDestination(for: SessionTabDrag.self) { values, point in
                    acceptDrop(values, targets: [tab], merge: members == nil && point.y >= 12, members: members)
                }
            if let sessionID = sharedSessionID, linkedTabs.isPrivateFile(tab) || (isConnected && isShareable(tab)) {
                row.draggable(SessionTabDrag(sessionID: sessionID, tab: tab))
            } else {
                row
            }
        }

        @ViewBuilder
        private func sharedRow(_ tab: SessionTabID, windows: [SessionTabID: TmuxWindow], resources: [SessionTabID: PaneLinkedTabID]) -> some View {
            if let window = windows[tab] {
                windowRow(window)
            } else if let resource = resources[tab] {
                linkedRow(resource)
            }
        }

        private func tabTitle(_ tab: SessionTabID, windows: [SessionTabID: TmuxWindow], resources: [SessionTabID: PaneLinkedTabID]) -> String {
            if let window = windows[tab] {
                return window.windowName.isEmpty ? "Window \(window.windowIndex)" : window.windowName
            }
            switch resources[tab] {
            case let .file(id): return files.first { $0.id == id }?.title ?? "Files"
            case let .browser(id): return browsers.first { $0.id == id }?.title ?? "Browser"
            case let .simulator(id): return simulators.first { $0.id == id }?.title ?? "Simulator"
            case nil: return "Tabs"
            }
        }

        private func groupLabel(_ title: String, count: Int, colorKey: String?) -> some View {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                Text(count.formatted()).monospacedDigit()
            }
            .foregroundStyle(PaneTabGroupStyle.color(for: colorKey))
            .accessibilityElement(children: .combine)
        }

        private func expansion(_ group: SessionTabGroup) -> Binding<Bool> {
            Binding(get: { expandedGroup == group }, set: { expandedGroup = $0 ? group : nil })
        }

        private func acceptDrop(_ values: [SessionTabDrag], targets: [SessionTabID], merge: Bool, members: [SessionTabID]? = nil) -> Bool {
            guard
                values.count == 1, let drag = values.first, drag.sessionID == sharedSessionID,
                members?.contains(drag.tab) ?? true,
                !targets.contains(drag.tab) else { return false }
            if linkedTabs.isPrivateFile(drag.tab) || (!merge && targets.count == 1 && targets.contains(where: linkedTabs.isPrivateFile)) {
                guard let layout = sharedTabLayout else { return false }
                if members != nil {
                    guard
                        let target = targets.first,
                        let order = linkedTabs.movingPrivateMember(drag.tab, before: target, layout: layout) else { return false }
                    onReorderLinkedTabs(order)
                } else {
                    guard let order = linkedTabs.movingPrivateTab(drag.tab, before: targets, layout: layout, stored: topLevelTabOrder) else { return false }
                    onReorderTopLevel(order)
                }
                return true
            }
            guard isConnected, isShareable(drag.tab), targets.allSatisfy(isShareable) else { return false }
            if merge {
                edit(.group(drag.tab, with: targets))
            } else {
                guard
                    let layout = sharedTabLayout,
                    let move = linkedTabs.sharedMove(drag.tab, before: targets.first, layout: layout, topLevelOrder: topLevelTabOrder) else { return false }
                edit(move)
            }
            return true
        }

        private func isShareable(_ tab: SessionTabID) -> Bool {
            if case let .file(id) = tab {
                return files.contains { $0.id == id && $0.hostTab != nil }
            }
            return true
        }

        private func edit(_ change: SessionTabLayout.Edit) {
            Task {
                do { try await onEditSharedTabs?(change) }
                catch { reorderError = error.localizedDescription }
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
            let progress = window.panes.effectiveProgress
            return Button { choose(.window(stableID: window.stableId, operation: .select)) } label: {
                HStack {
                    Label(name, symbol: window.hasClaude ? .sparkles : .terminal)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if window.needsAttention {
                        Symbols.bellBadgeFill.image
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Needs attention")
                            .padding(.leading, 6)
                    }
                    if selectedWindowID == window.stableId, selectedFileID == nil, selectedBrowserID == nil, selectedSimulatorID == nil {
                        Symbols.checkmark.image
                            .padding(.leading, 6)
                    }
                }
                .frame(minHeight: 44)
                .overlay(alignment: .bottom) {
                    if let progress {
                        TerminalProgressBar(state: progress)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(progress.map { "Terminal progress \($0.accessibilityValueString)" } ?? "")
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

    private struct SessionTabDrag: Codable, Transferable {
        let sessionID: UUID
        let tab: SessionTabID

        static var transferRepresentation: some TransferRepresentation {
            CodableRepresentation(contentType: UTType(exportedAs: "com.jicezeng.ctrlx.session-tab"))
        }
    }
#endif
