import CtrlxCommon
import CtrlxNetworking
import SwiftUI
import UniformTypeIdentifiers

/// Horizontal tab bar for remote session windows, mirroring `WindowTabBar` for
/// local sessions, with Host-backed directory tabs and client-private browser tabs.
///
/// Supports the same affordances as the local bar:
/// - Leading "+" menu opens Agent, Terminal and Browser tabs.
/// - Window context menus open Files rooted in that window's pane.
/// - Drag-to-reorder for tmux windows (pushed to the host via
///   `MoveTmuxWindows`) and client-private file/browser tabs.
/// - Cross-divider drag/split toggle so any tab can be sent
///   to a right pane and back.
/// - Trailing drop zone for "drop past the last tab".
struct RemoteWindowTabBar: View {
    @Environment(AppSettings.self) private var settings

    let windows: [TmuxWindow]
    let selectedWindow: TmuxWindow
    let isHostConnected: Bool
    /// In-app browser tabs scoped to this remote session. Empty when no
    /// terminal-link click has spawned a tab yet.
    let openBrowserTabs: [BrowserTab]
    /// When set, the matching browser tab in `openBrowserTabs` is the active
    /// detail view. The parent renders `BrowserTabContentView` in place of
    /// `RemoteWindowPaneLayoutView` while non-nil.
    let selectedBrowserTabId: UUID?
    /// Per-session tab state (browser tabs, split layout, selections).
    /// `nil` while a session hasn't materialised any tabs yet — the bar
    /// renders as if the lists were empty and `isSplit` were `false`.
    let sessionTabs: SessionFileTabsState?
    let onSelectWindow: (TmuxWindow) -> Void
    let onCloseWindow: (TmuxWindow) -> Void
    let onNewWindow: () -> Void
    let agentConfiguration: NewAgentTabConfiguration
    let forkUnavailableReason: String?
    let onForkWindow: (TmuxWindow, Bool) -> Void
    /// Creates a new in-app browser tab (selected, address bar focused). Called
    /// from the "+" menu's "New Browser" option.
    let onNewBrowser: () -> Void
    let onRenameWindow: (TmuxWindow, String) -> Void
    let onSelectBrowserTab: (UUID) -> Void
    let onCloseBrowserTab: (UUID) -> Void
    /// Toggles which side of the split a tab strip entry lives on.
    let onToggleSplit: (TabDragPayload) -> Void
    /// Rearranges the tmux windows to match the supplied id order. Invoked
    /// when the user drops a window tab into a new slot. The caller persists
    /// the new order via `MoveTmuxWindows`.
    let onReorderWindows: (_ stableWindowIds: [String], _ rollbackOrder: [TabDragPayload]) -> Void
    /// Reorders the open browser tabs.
    let onReorderBrowserTabs: ([UUID]) -> Void
    var onSelectFileTab: ((UUID) -> Void)?
    var onCloseFileTab: ((UUID) -> Void)?
    let onOpenFiles: (TmuxWindow) -> Void

    /// Cached width of the split-mode tab strip. Measured via the background
    /// `onGeometryChange` so the HStack can drive intrinsic height instead of
    /// being pinned by a `GeometryReader` parent — keeps the split and
    /// non-split rows the same height under Dynamic Type and padding tweaks.
    @State private var splitRowWidth: CGFloat = 0

    @State private var hoveredWindowId: String?

    /// Currently-displayed drop indicator: nil while nothing is being dragged.
    /// The bar shows a vertical accent line to the left of the matching tab
    /// while a compatible drag is hovering, giving the user a clear preview
    /// of where the drop will land.
    @State private var dropIndicator: TabDragPayload?

    /// Which section's trailing drop zone is currently hovered, if any. Drawn
    /// separately from `dropIndicator` because the zone isn't a tab and has
    /// its own visual treatment.
    @State private var trailingDropTargetedSection: TabSection?

    private var selectedRight: TabDragPayload? {
        sessionTabs?.selectedRight
    }

    private var isSplit: Bool {
        sessionTabs?.isSplit ?? false
    }

    private var splitRatio: CGFloat {
        sessionTabs?.splitRatio ?? 0.5
    }

    /// True when the given payload currently lives in the right pane.
    private func isOnRight(_ payload: TabDragPayload) -> Bool {
        sessionTabs?.rightSide.contains(payload) ?? false
    }

    /// Source-of-truth ordering for the tab strip — reconciles the persisted
    /// `sessionTabs.tabOrder` with the live windows / browser tabs so newly-
    /// discovered entries are slotted in and removed entries drop out without
    /// rewriting the array elsewhere. New windows insert at the end of the
    /// windows subsequence (right before the first browser tab); new browser
    /// tabs append at the very end. Remote sessions have no file explorer, file
    /// tabs, or Git tab, hence `includeFileExplorer: false` and
    /// `includeGit: false`.
    ///
    /// Shares `TabDragPayload.reconciledOrder` with the local strip and both
    /// keyboard cyclers so all four surfaces stay in lockstep (issue #566).
    private var effectiveTabOrder: [TabDragPayload] {
        TabDragPayload.reconciledOrder(
            windowIds: windows.map(\.stableId),
            fileTabIds: sessionTabs?.openFileTabs.map(\.id) ?? [],
            browserTabIds: openBrowserTabs.map(\.id),
            storedOrder: sessionTabs?.tabOrder ?? [],
            includeFileExplorer: false,
            includeGit: false
        )
    }

    /// Effective order restricted to entries visible on the left section in
    /// split mode (everything that hasn't been dragged into the right pane).
    private var leftSectionOrder: [TabDragPayload] {
        effectiveTabOrder.filter { !isOnRight($0) }
    }

    /// Effective order restricted to entries visible on the right section in
    /// split mode.
    private var rightSectionOrder: [TabDragPayload] {
        effectiveTabOrder.filter { isOnRight($0) }
    }

    var body: some View {
        Group {
            if isSplit {
                HStack(spacing: SplitLayout.dividerWidth) {
                    leftSection
                        .frame(width: max(0, splitRowWidth * splitRatio - SplitLayout.dividerWidth / 2))
                    rightSection
                        .frame(maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { newWidth in
                    splitRowWidth = newWidth
                }
                .background(settings.theme.chromeBackgroundColor)
                .overlay(alignment: .bottom) {
                    tabBarDivider
                }
            } else {
                singleSection
                    .background(settings.theme.chromeBackgroundColor)
                    .overlay(alignment: .bottom) {
                        tabBarDivider
                    }
            }
        }
        // Persist the reconciled order so newly-appended windows / browsers
        // and pruned entries survive view rebuilds and session switches. The
        // computed value is idempotent so this can't loop.
        .onChange(of: effectiveTabOrder) { _, new in
            if sessionTabs?.tabOrder != new {
                sessionTabs?.tabOrder = new
            }
        }
        .onAppear {
            let computed = effectiveTabOrder
            if sessionTabs?.tabOrder != computed {
                sessionTabs?.tabOrder = computed
            }
        }
    }

    @ViewBuilder
    private var tabBarDivider: some View {
        if settings.theme == .anysphereDark {
            Rectangle()
                .fill(settings.theme.workspaceBorderColor)
                .frame(height: 1)
        } else {
            Divider()
        }
    }

    private var singleSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                newWindowButton
                ForEach(effectiveTabOrder, id: \.self) { ref in
                    tabView(for: ref)
                }
                trailingDropZone(for: .single)
            }
            .padding(.horizontal, 8)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var leftSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                newWindowButton
                ForEach(leftSectionOrder, id: \.self) { ref in
                    tabView(for: ref)
                }
                trailingDropZone(for: .left)
            }
            .padding(.leading, 8)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rightSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(rightSectionOrder, id: \.self) { ref in
                    tabView(for: ref)
                }
                trailingDropZone(for: .right)
            }
            .padding(.trailing, 8)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Trailing drop target that fills the rest of the tab strip so users can
    /// drop a tab "past the last tab" to move it to the end of the section.
    private func trailingDropZone(for section: TabSection) -> some View {
        let isTargeted = trailingDropTargetedSection == section
        let identifier = switch section {
        case .single: "remote-tab-trailing-drop-single"
        case .left: "remote-tab-trailing-drop-left"
        case .right: "remote-tab-trailing-drop-right"
        }
        return Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                DropIndicator(visible: isTargeted)
                    .padding(.leading, 4)
            }
            .dropDestination(for: TabDragPayload.self) { payloads, _ in
                handleEndDrop(payloads: payloads, section: section)
            } isTargeted: { hovering in
                trailingDropTargetedSection = hovering ? section : (
                    trailingDropTargetedSection == section ? nil : trailingDropTargetedSection
                )
            }
            .accessibilityElement()
            .accessibilityIdentifier(identifier)
            .accessibilityLabel("Tab strip trailing drop zone")
    }

    /// Dispatches a unified-order entry to the right view. Returns `EmptyView`
    /// for entries whose underlying data has gone away between reconciliation
    /// and this render pass (extremely rare; the next body cycle prunes it).
    /// File-explorer and file-tab payloads are silently ignored — they can't
    /// arrive from this bar in practice (no source view emits them) but the
    /// shared `TabDragPayload` makes them syntactically possible.
    @ViewBuilder
    private func tabView(for ref: TabDragPayload) -> some View {
        switch ref {
        case let .window(id):
            if let window = windows.first(where: { $0.stableId == id }) {
                windowTab(window)
            }
        case let .browser(id):
            if let tab = openBrowserTabs.first(where: { $0.id == id }) {
                openBrowserTabView(tab)
            }
        case let .file(id):
            if let tab = sessionTabs?.directoryTabs[id] { fileTab(tab) }
        case .fileExplorer,
             .git:
            EmptyView()
        }
    }

    private var newWindowButton: some View {
        NewTabMenuButton(
            helpText: "New agent, terminal or browser tab",
            agentConfiguration: agentConfiguration,
            isTerminalDisabled: !isHostConnected,
            onNewTerminal: onNewWindow,
            onNewBrowser: onNewBrowser
        )
    }

    private func fileTab(_ tab: FileBrowserTab) -> some View {
        let payload = TabDragPayload.file(tab.id)
        let onRight = isOnRight(payload)
        let selected = onRight ? selectedRight == payload : sessionTabs?.selectedFileTabId == tab.id
        return HStack(spacing: 0) {
            Button { onSelectFileTab?(tab.id) } label: {
                Label(tab.title, symbol: .folder).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 6)
            }.buttonStyle(.plain)
            TabSplitToggleButton(isSplit: isSplit, isOnRight: onRight, tabKind: "file tab", tabName: tab.title,
                                 action: { onToggleSplit(payload) })
            TabCloseButton(isVisible: true, accessibilityLabel: "Close \(tab.title)", action: { onCloseFileTab?(tab.id) })
                .padding(.trailing, 6)
        }
        .tabStripItemStyle(isSelected: selected, isOnRightSplit: onRight, isSplit: isSplit)
        .overlay(alignment: .leading) { DropIndicator(visible: dropIndicator == payload) }
        .draggable(payload) { TabDragPreview(label: tab.title, symbol: .folder) }
        .dropDestination(for: TabDragPayload.self) { payloads, _ in
            handleDrop(payloads: payloads, target: payload)
        } isTargeted: { targeted in
            updateDropIndicator(target: targeted ? payload : nil, for: .file)
        }
    }

    private func windowTab(_ window: TmuxWindow) -> some View {
        let payload = TabDragPayload.window(window.stableId)
        let tabIsOnRight = isOnRight(payload)
        // Match the local `WindowTabBar` styling: when a browser tab is the
        // active detail view, deselect the window tab visually so the user
        // sees at a glance that the in-app browser — not the terminal — owns
        // the content area. Right-side windows are "selected" only when the
        // right-pane selection points at them.
        let isSelected = tabIsOnRight
            ? selectedRight == payload
            : window.id == selectedWindow.id && selectedBrowserTabId == nil && sessionTabs?.selectedFileTabId == nil
        let isHovered = hoveredWindowId == window.id
        let windowName = windowTabLabel(windowName: window.windowName, windowIndex: window.windowIndex)

        return HStack(spacing: 0) {
            Button {
                onSelectWindow(window)
            } label: {
                HStack(spacing: 4) {
                    if window.hasClaude {
                        Symbols.sparkles.image
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }

                    Text(windowName)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(window.id) \(windowName)")
            .accessibilityValue(isSelected ? "selected" : "")
            .modifier(WindowRenamingModifier(
                currentName: window.windowName,
                isDisabled: !isHostConnected,
                onRename: { newName in
                    onRenameWindow(window, newName)
                },
                additionalMenu: {
                    Button { onOpenFiles(window) } label: {
                        Label("Open Files", symbol: .folderBadgePlus)
                    }
                    .disabled(!isHostConnected)
                    .accessibilityIdentifier("window-open-files-\(window.stableId)")

                    AgentForkMenu(
                        sources: window.panes.compactMap(AgentForkSource.init(pane:)),
                        unavailableReason: forkUnavailableReason,
                        sourceUnavailableReason: AgentForkSource.unavailableReason(panes: window.panes),
                        choose: { onForkWindow(window, $0) }
                    )
                }
            ))

            TabSplitToggleButton(
                isSplit: isSplit,
                isOnRight: tabIsOnRight,
                tabKind: "terminal",
                tabName: windowName,
                action: { onToggleSplit(payload) }
            )

            TabCloseButton(
                isVisible: isSelected || isHovered,
                isDisabled: !isHostConnected,
                accessibilityLabel: "Close window: \(windowName)",
                helpText: "Close window",
                action: { onCloseWindow(window) }
            )
            .padding(.trailing, 6)
        }
        .tabStripItemStyle(isSelected: isSelected, isOnRightSplit: tabIsOnRight, isSplit: isSplit)
        .overlay(alignment: .leading) {
            DropIndicator(visible: dropIndicator == payload)
        }
        .onHover { hovering in
            hoveredWindowId = hovering ? window.id : nil
        }
        .draggable(payload) {
            TabDragPreview(label: windowName, symbol: window.hasClaude ? .sparkles : .terminal)
        }
        .dropDestination(for: TabDragPayload.self) { payloads, _ in
            handleDrop(payloads: payloads, target: payload)
        } isTargeted: { isTargeted in
            updateDropIndicator(target: isTargeted ? payload : nil, for: .window)
        }
    }

    private func openBrowserTabView(_ tab: BrowserTab) -> some View {
        let payload = TabDragPayload.browser(tab.id)
        let isOnRight = isOnRight(payload)
        let isSelected = isOnRight
            ? selectedRight == payload
            : tab.id == selectedBrowserTabId

        return BrowserTabStripItem(
            tab: tab,
            isSelected: isSelected,
            isOnRight: isOnRight,
            isSplit: isSplit,
            showsDropIndicator: dropIndicator == payload,
            onSelect: { onSelectBrowserTab(tab.id) },
            onClose: { onCloseBrowserTab(tab.id) },
            onToggleSplit: { onToggleSplit(payload) },
            onDrop: { payloads in handleDrop(payloads: payloads, target: payload) },
            onTargetedChanged: { isTargeted in
                updateDropIndicator(target: isTargeted ? payload : nil, for: .browser)
            }
        )
    }

    // MARK: - Drag and Drop

    private func updateDropIndicator(target: TabDragPayload?, for kind: TabDragPayload.Kind) {
        if let target {
            dropIndicator = target
        } else if dropIndicator?.kind == kind {
            dropIndicator = nil
        }
    }

    private func handleDrop(payloads: [TabDragPayload], target: TabDragPayload) -> Bool {
        defer { dropIndicator = nil }
        guard let source = payloads.first, source != target else { return false }

        let previousOrder = effectiveTabOrder
        guard let order = TabDragPayload.moving(source, before: target, in: previousOrder) else { return false }
        let windowOrderChanged = order.compactMap(\.windowId) != windows.map(\.stableId)
        guard !windowOrderChanged || sessionTabs?.isWindowReorderPending != true else { return false }

        sessionTabs?.tabOrder = order

        adjustSplitSideIfNeeded(source: source, to: sectionOf(target))
        syncSubsequences(from: order, rollbackOrder: previousOrder)

        return true
    }

    private func handleEndDrop(payloads: [TabDragPayload], section: TabSection) -> Bool {
        defer { trailingDropTargetedSection = nil }
        guard let source = payloads.first else { return false }

        let previousOrder = effectiveTabOrder
        var order = previousOrder
        guard let sourceIndex = order.firstIndex(of: source) else { return false }

        let moved = order.remove(at: sourceIndex)

        let insertIndex: Int
        switch section {
        case .single,
             .right:
            insertIndex = order.count
        case .left:
            insertIndex = (order.lastIndex { !isOnRight($0) } ?? -1) + 1
        }

        order.insert(moved, at: min(insertIndex, order.count))
        let windowOrderChanged = order.compactMap(\.windowId) != windows.map(\.stableId)
        guard !windowOrderChanged || sessionTabs?.isWindowReorderPending != true else { return false }
        sessionTabs?.tabOrder = order
        adjustSplitSideIfNeeded(source: source, to: section)
        syncSubsequences(from: order, rollbackOrder: previousOrder)
        return true
    }

    private func sectionOf(_ ref: TabDragPayload) -> TabSection {
        if isOnRight(ref) { return .right }
        return isSplit ? .left : .single
    }

    private func adjustSplitSideIfNeeded(source: TabDragPayload, to section: TabSection) {
        if isOnRight(source) != (section == .right) {
            onToggleSplit(source)
        }
    }

    private func syncSubsequences(from order: [TabDragPayload], rollbackOrder: [TabDragPayload]) {
        if let tabs = sessionTabs {
            let files = Dictionary(uniqueKeysWithValues: tabs.openFileTabs.map { ($0.id, $0) })
            tabs.openFileTabs = order.compactMap { if case let .file(id) = $0 { files[id] } else { nil } }
        }
        let windowIds = order.compactMap(\.windowId)
        let browserIds: [UUID] = order.compactMap { ref in
            if case let .browser(id) = ref { return id } else { return nil }
        }

        if windowIds != windows.map(\.stableId), !windowIds.isEmpty {
            sessionTabs?.isWindowReorderPending = true
            onReorderWindows(windowIds, rollbackOrder)
        }
        if browserIds != openBrowserTabs.map(\.id) {
            onReorderBrowserTabs(browserIds)
        }
    }
}
