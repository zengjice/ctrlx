import CtrlxCommon
import CtrlxNetworking
import SwiftUI
import UniformTypeIdentifiers

/// Horizontal tab bar showing windows in a tmux session.
/// Always visible, even for single-window sessions. The leading "+" button
/// pops up a menu for Agent cards or a terminal window. Browsers belong to panes.
struct WindowTabBar: View {
    @Environment(\.workbenchTabContext) private var workbenchContext
    let session: LocalTmuxSession
    let selectedWindow: LocalTmuxWindow?
    /// True only when the Files (tree) tab is the active view — i.e. the file browser
    /// is open and no file tab is currently selected.
    let isFileBrowserSelected: Bool
    /// True only when the Git tab is the active view (issue #258).
    let isGitBrowserSelected: Bool
    /// Number of changed files in the session's repository (issue #573). When
    /// greater than zero a small badge is shown on the Git tab button so the
    /// user can see there are uncommitted changes without opening the tab.
    let gitChangedFileCount: Int
    /// True when any non-terminal view is showing (file tree, a file tab, or a
    /// browser tab). Used to deselect the underlying tmux window tab so it
    /// doesn't render as concurrently selected with another tab.
    let isAnyFileViewActive: Bool
    /// Per-session tab state (terminal order, file/browser tabs, split layout,
    /// selections). `MainView` creates it as soon as the session is selected,
    /// before the bar can accept a drag.
    let sessionTabs: SessionFileTabsState
    let onSelectWindow: (LocalTmuxWindow) -> Void
    let onCloseWindow: (LocalTmuxWindow) -> Void
    let onNewWindow: () -> Void
    @Binding var isNewTabMenuPresented: Bool
    let agentConfiguration: NewAgentTabConfiguration
    let windowMenuItems: (LocalTmuxWindow) -> [ContextMenuItem]
    let onRenameWindow: (LocalTmuxWindow) -> Void
    let onSelectFileBrowser: () -> Void
    /// Activates the Git tab for the current window (issue #258).
    let onSelectGitBrowser: () -> Void
    let onCloseGitBrowser: () -> Void
    let onSelectFileTab: (UUID) -> Void
    let onCloseFileTab: (UUID) -> Void
    let onSelectBrowserTab: (UUID) -> Void
    let onCloseBrowserTab: (UUID) -> Void
    /// Toggles which side of the split a tab strip entry lives on. If the
    /// entry is on the left, sends it to the right (opening the split). If
    /// on the right, sends it back to the left (and collapses the split if
    /// the right side becomes empty). The host dispatches on the payload's
    /// case to update the matching state.
    let onToggleSplit: (TabDragPayload) -> Void
    let onMoveTab: (TabDragPayload) -> Void
    let onShowInFileExplorer: (String) -> Void
    let onAcceptOpenSuggestion: (MarkdownOpenSuggestion) -> Void
    /// Rearranges the tmux windows in the session to match the supplied id
    /// order. Invoked when the user drops a window tab into a new slot. The
    /// caller persists the new order via `tmux move-window`.
    let onReorderWindows: (_ stableWindowIds: [String], _ rollbackOrder: [TabDragPayload]) -> Void
    /// Reorders the open file tabs. The caller mutates the `openFileTabs`
    /// array on `SessionFileTabsState` so the new layout survives session
    /// switches like every other tab-list mutation.
    let onReorderFileTabs: ([UUID]) -> Void
    /// Reorders the open browser tabs.
    let onReorderBrowserTabs: ([UUID]) -> Void
    let linkedTabActions: LinkedTabSourceActions
    var onNewResource: ((ResourceTabKind) -> Void)?
    var onDetachWindow: ((LocalTmuxWindow, CGPoint?) -> Void)?

    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(MarkdownOpenSuggestionStore.self) private var openSuggestionStore
    @Environment(AppSettings.self) private var settings

    /// Cached width of the split-mode tab strip. Measured via the background
    /// `onGeometryChange` so the HStack can drive intrinsic height instead of
    /// being pinned by a `GeometryReader` parent — keeps the split and
    /// non-split rows the same height under Dynamic Type and padding tweaks.
    @State private var splitRowWidth: CGFloat = 0

    @State private var hoveredWindowId: String?
    @State private var hoveredFileTabId: UUID?
    @State private var isGitHovered = false

    /// Read-only accessors that mirror `SessionFileTabsState`. Defined as
    /// computed properties (not stored) so observation tracking happens on
    /// every `body` evaluation.
    private var openFileTabs: [OpenFileTab] {
        sessionTabs.openFileTabs
    }

    private var openBrowserTabs: [BrowserTab] {
        sessionTabs.openBrowserTabs
    }

    private var selectedFileTabId: UUID? {
        sessionTabs.selectedFileTabId
    }

    private var selectedBrowserTabId: UUID? {
        sessionTabs.selectedBrowserTabId
    }

    private var selectedRight: TabDragPayload? {
        sessionTabs.selectedRight
    }

    private var isSplit: Bool {
        sessionTabs.isSplit
    }

    private var splitRatio: CGFloat {
        sessionTabs.splitRatio
    }

    /// True when the given payload currently lives in the right pane.
    private func isOnRight(_ payload: TabDragPayload) -> Bool {
        sessionTabs.rightSide.contains(payload)
    }

    /// Keep source labels for children whose terminal is in another workbench.
    private var groupPanes: [PaneState] {
        sessionTabs.localTabPanes(sessionName: session.sessionName, windows: session.windows, paneStates: windowManager.paneStates)
    }

    private var effectiveTabOrder: [TabDragPayload] {
        sessionTabs.localPresentedTabOrder(
            windows: session.windows, panes: groupPanes, layout: workbenchContext?.sharedTabLayout?.snapshot
        )
    }

    /// Effective order restricted to entries visible on the left section in
    /// split mode (everything that hasn't been dragged into the right pane).
    private var leftSectionOrder: [TabDragPayload] {
        effectiveTabOrder.filter { !isOnRight($0) }
    }

    /// Effective order restricted to entries visible on the right section in
    /// split mode (anything flipped to the right side — windows, the file
    /// explorer, file tabs, or browser tabs).
    private var rightSectionOrder: [TabDragPayload] {
        effectiveTabOrder.filter { isOnRight($0) }
    }

    var body: some View {
        Group {
            if isSplit {
                // Use `spacing:` for the visual gap so the row's height is
                // driven by the `ScrollView(.horizontal)` siblings' intrinsic
                // (content-based) vertical size instead of being inflated by
                // a greedy spacer view. `fixedSize(vertical: true)` ensures
                // the HStack reports that intrinsic height upward so the
                // VStack parent still gives the detail area the remainder.
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
        .onChange(of: workbenchContext?.sharedTabLayout?.snapshot, initial: true) { _, snapshot in
            sessionTabs.sharedManualTabGroups = snapshot?.groups ?? [:]
        }
        // Persist the reconciled order so newly-appended windows / tabs and
        // pruned entries survive view rebuilds and session switches. The
        // computed value is idempotent (`reconcile(reconcile(x)) == reconcile(x)`)
        // so this can't loop.
        .onChange(of: effectiveTabOrder, initial: true) { _, order in
            sessionTabs.reconcileLocalTabGroups(visible: order)
            sessionTabs.recordVisibleTabOrder(order)
        }
    }

    @ViewBuilder private var tabBarDivider: some View {
        if settings.theme.usesSubtleTabBorder {
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
                tabStrip(order: effectiveTabOrder, section: .single)
            }
            .padding(.horizontal, 8)
            // Without this, the trailing drop zone's `maxWidth: .infinity`
            // also propagates an unbounded vertical preference upward and
            // the whole tab strip stretches to fill the parent VStack.
            // Pinning the row to its natural ideal height keeps the strip
            // the same compact size it was before drag-and-drop landed.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Left section of the split-aware tab strip: the "+" button plus every
    /// entry in the unified order that hasn't been sent to the right pane.
    private var leftSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                newWindowButton
                tabStrip(order: leftSectionOrder, section: .left)
            }
            .padding(.leading, 8)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Right section of the split-aware tab strip: file / browser tabs that
    /// have been flipped to the right pane, in their unified-order position.
    private var rightSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                tabStrip(order: rightSectionOrder, section: .right)
            }
            .padding(.trailing, 8)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tabStrip(order: [TabDragPayload], section: TabSection) -> some View {
        let rightSide = section == .right
        let leftSelection: TabDragPayload? = sessionTabs.selectedFileTabId.map(TabDragPayload.file)
            ?? selectedBrowserTabId.map(TabDragPayload.browser) ?? (isGitBrowserSelected ? .git : nil) ?? (!isAnyFileViewActive ? selectedWindow.map { .window($0.stableId) } : nil)
        return PaneLinkedTabStrip(
            order: order, sessionOrder: effectiveTabOrder, tabs: sessionTabs, panes: groupPanes,
            paneOrder: SessionFileTabsState.paneOrder(for: effectiveTabOrder, panes: groupPanes), selection: rightSide ? selectedRight : leftSelection,
            rightSide: rightSide, title: tabTitle, onDrop: handleDrop,
            onEndDrop: { handleEndDrop(payloads: $0, section: section, placement: $1) },
            onUngroup: ungroup, trailingDropID: "tab-trailing-drop-\(section.rawValue)"
        ) {
            tabView(for: $0)
        } accessory: {
            if section != .right, let suggestion = openSuggestionStore.suggestionsBySession[session.sessionName] {
                openSuggestionBar(suggestion)
            }
        }
    }

    private func tabTitle(_ tab: TabDragPayload) -> String {
        switch tab {
        case let .window(id):
            session.windows.first(where: { $0.stableId == id }).map { windowTabLabel(windowName: $0.windowName, windowIndex: $0.windowIndex) } ?? "Window"
        case let .file(id): openFileTabs.first(where: { $0.id == id })?.name ?? "Files"
        case let .browser(id): openBrowserTabs.first(where: { $0.id == id })?.tabLabel ?? "Browser"
        case .git: "Git"
        case .fileExplorer: "Files"
        }
    }

    private func ungroup(_ tab: TabDragPayload) {
        if let id = sessionTabs.manualTabGroups[tab] {
            sessionTabs.manualTabGroups = sessionTabs.manualTabGroups.filter { $0.value != id }
        } else {
            workbenchContext?.sharedTabLayout?.ungroup(tab)
        }
    }

    @ViewBuilder
    private func tabView(for ref: TabDragPayload) -> some View {
        switch ref {
        case let .window(id):
            if let window = session.windows.first(where: { $0.stableId == id }) {
                windowTab(window)
            }
        case .fileExplorer:
            fileBrowserButton
        case .git:
            gitBrowserButton
        case let .file(id):
            if let tab = openFileTabs.first(where: { $0.id == id }) {
                openFileTabView(tab)
            }
        case let .browser(id):
            if let tab = openBrowserTabs.first(where: { $0.id == id }) {
                openBrowserTabView(tab)
            }
        }
    }

    private var newWindowButton: some View {
        NewTabMenuButton(
            helpText: "New agent or terminal in \(session.sessionName)",
            agentConfiguration: agentConfiguration,
            isPresented: $isNewTabMenuPresented,
            onNewTerminal: onNewWindow,
            onOpenGit: onSelectGitBrowser,
            onNewResource: onNewResource
        )
    }

    private var fileBrowserButton: some View {
        let tabIsOnRight = isOnRight(.fileExplorer)
        // The button is "selected" when it drives the visible content of
        // whichever pane it currently lives in — the left pane via the
        // existing `isFileBrowserSelected` flag, or the right pane when
        // `selectedRight == .fileExplorer`.
        let isSelected = tabIsOnRight
            ? selectedRight == .fileExplorer
            : isFileBrowserSelected
        return HStack(spacing: 0) {
            Button(action: onSelectFileBrowser) {
                Symbols.folderFill.image
                    .font(.caption)
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Browse files in \(session.sessionName)")
            .accessibilityLabel("Files")
            .accessibilityValue(isSelected ? "selected" : "")

            TabSplitToggleButton(
                isSplit: isSplit,
                isOnRight: tabIsOnRight,
                tabKind: "file explorer",
                tabName: "Files",
                action: { onToggleSplit(.fileExplorer) }
            )
            .padding(.trailing, 6)
        }
        .tabStripItemStyle(isSelected: isSelected, isOnRightSplit: tabIsOnRight, isSplit: isSplit)
        .workbenchDraggable(TabDragPayload.fileExplorer) {
            TabDragPreview(label: "Files", symbol: .folderFill)
        }
    }

    /// Accessibility value for the Git tab button, combining its selection
    /// state with the changed-file count badge (issue #573) so E2E scenarios can
    /// assert both from one element.
    private func gitAccessibilityValue(isSelected: Bool) -> String {
        var parts: [String] = []
        if isSelected {
            parts.append("selected")
        }
        if gitChangedFileCount > 0 {
            parts.append("\(gitChangedFileCount) changed files")
        }
        return parts.joined(separator: ", ")
    }

    /// One Git tab per session, opened from the "+" menu.
    private var gitBrowserButton: some View {
        let tabIsOnRight = isOnRight(.git)
        let isSelected = tabIsOnRight
            ? selectedRight == .git
            : isGitBrowserSelected
        return HStack(spacing: 0) {
            Button(action: onSelectGitBrowser) {
                HStack(spacing: 4) {
                    CustomSymbol.gitLogo.image
                        .font(.caption)

                    if gitChangedFileCount > 0 {
                        Text("\(gitChangedFileCount)")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                            .accessibilityHidden(true)
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Git changes for \(session.sessionName)")
            .accessibilityLabel("Git")
            .accessibilityIdentifier("git-tab")
            .accessibilityValue(gitAccessibilityValue(isSelected: isSelected))

            TabSplitToggleButton(
                isSplit: isSplit,
                isOnRight: tabIsOnRight,
                tabKind: "git",
                tabName: "Git",
                action: { onToggleSplit(.git) }
            )
            TabCloseButton(
                isVisible: isSelected || isGitHovered,
                accessibilityLabel: "Close Git tab",
                helpText: "Close Git tab",
                action: onCloseGitBrowser
            )
            .padding(.trailing, 6)
        }
        .tabStripItemStyle(isSelected: isSelected, isOnRightSplit: tabIsOnRight, isSplit: isSplit)
        .onHover { isGitHovered = $0 }
        .workbenchDraggable(TabDragPayload.git) {
            TabDragPreview(label: "Git", image: CustomSymbol.gitLogo.image)
        }
    }

    private func windowTab(_ window: LocalTmuxWindow) -> some View {
        // A window on the right pane is "selected" when it's the currently-
        // rendered right-side content. On the left (or in single mode) the
        // existing rule applies: the tab is the active terminal and no
        // file/browser/explorer is occupying the left pane.
        let payload = TabDragPayload.window(window.stableId)
        let tabIsOnRight = isOnRight(payload)
        let isSelected = tabIsOnRight
            ? selectedRight == payload
            : window.id == selectedWindow?.id && !isAnyFileViewActive
        let isHovered = hoveredWindowId == window.id
        let panes = window.panes.compactMap { windowManager.paneStates[$0.paneId] }
        let hasClaude = panes.contains { $0.agentSession != nil }
        let attention = AgentAttention(panes: panes)
        let progress = panes.effectiveProgress
        let windowName = windowTabLabel(windowName: window.windowName, windowIndex: window.windowIndex)

        return HStack(spacing: 0) {
            Button {
                onSelectWindow(window)
            } label: {
                TerminalWindowTabLabel(name: windowName, hasAgent: hasClaude, attention: attention, progress: progress)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(window.id) \(windowName)")
            .accessibilityValue(windowTabAccessibilityValue(isSelected: isSelected, attention: attention, progress: progress))
            .background(WindowTabDragSource(windowID: window.stableId, label: windowName) { point in
                onDetachWindow?(window, point)
            })
            .stableContextMenu { windowMenuItems(window) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { onRenameWindow(window) })

            TabReturnToMainButton(tab: payload, name: windowName)

            TabSplitToggleButton(
                isSplit: isSplit,
                isOnRight: tabIsOnRight,
                tabKind: "terminal",
                tabName: windowName,
                action: { onToggleSplit(payload) }
            )

            TabCloseButton(
                isVisible: isSelected || isHovered,
                accessibilityLabel: "Close tab: \(windowName)",
                helpText: "Close tab",
                action: { onCloseWindow(window) }
            )
            .padding(.trailing, 6)
        }
        .tabStripItemStyle(isSelected: isSelected, isOnRightSplit: tabIsOnRight, isSplit: isSplit)
        .onHover { hovering in
            hoveredWindowId = hovering ? window.id : nil
        }
    }

    @ViewBuilder
    private func openFileTabView(_ tab: OpenFileTab) -> some View {
        let payload = TabDragPayload.file(tab.id)
        let tabIsOnRight = isOnRight(payload)
        let isSelected = tabIsOnRight
            ? selectedRight == payload
            : tab.id == selectedFileTabId
        let isHovered = hoveredFileTabId == tab.id

        HStack(spacing: 0) {
            Button {
                onSelectFileTab(tab.id)
            } label: {
                HStack(spacing: 4) {
                    (tab.isDirectory ? Symbols.folder : Symbols.docPlaintextFill).image
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(sessionTabs.directoryTabs[tab.id]?.title ?? tab.name)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .leading)
                        .strikethrough(tab.isDeleted, color: .secondary)
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("File tab: \(tab.name)")
            .accessibilityValue(isSelected ? "selected" : "")

            TabReturnToMainButton(tab: payload, name: tab.name)

            TabSplitToggleButton(
                isSplit: isSplit,
                isOnRight: tabIsOnRight,
                tabKind: "file tab",
                tabName: tab.name,
                action: { onToggleSplit(payload) }
            )

            TabCloseButton(
                isVisible: isSelected || isHovered,
                accessibilityLabel: "Close file tab: \(tab.name)",
                action: { onCloseFileTab(tab.id) }
            )
            .padding(.trailing, 6)
        }
        .tabStripItemStyle(isSelected: isSelected, isOnRightSplit: tabIsOnRight, isSplit: isSplit)
        .fileContextMenu(
            fullPath: sessionTabs.directoryTabs[tab.id]?.path ?? tab.path,
            directoryPath: sessionTabs.directoryTabs[tab.id]?.path ?? tab.directoryPath,
            isDirectory: tab.isDirectory,
            onOpenFileInNewTab: nil,
            onShowInFileExplorer: { path in
                if tab.isDirectory {
                    onSelectFileTab(tab.id)
                } else {
                    onShowInFileExplorer(path)
                }
            },
            additionalItems: linkedTabMenuItems(for: payload)
        )
        .onHover { hovering in
            hoveredFileTabId = hovering ? tab.id : nil
        }
        .workbenchDraggable(payload, label: tab.name) {
            TabDragPreview(label: tab.name, symbol: .docPlaintextFill)
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
            onSelect: { onSelectBrowserTab(tab.id) },
            onClose: { onCloseBrowserTab(tab.id) },
            onToggleSplit: { onToggleSplit(payload) }
        )
        .stableContextMenu {
            linkedTabMenuItems(for: payload)
        }
    }

    private func linkedTabMenuItems(for payload: TabDragPayload) -> [ContextMenuItem] {
        let sourcePaneID = sessionTabs.sourcePaneID(for: payload)
        let isSourceAvailable = sourcePaneID.map { paneID in
            groupPanes.contains { $0.paneId == paneID }
        } ?? false
        let isAgentSource = sourcePaneID.flatMap { paneID in
            groupPanes.first { $0.paneId == paneID }
        }?.agentSession != nil
        return (workbenchContext?.detachmentMenuItems(for: payload) ?? []) + linkedTabActions.menuItems(
            paneID: sourcePaneID,
            isSourceAvailable: isSourceAvailable,
            isAgentSource: isAgentSource
        )
    }

    @ViewBuilder
    private func openSuggestionBar(_ suggestion: MarkdownOpenSuggestion) -> some View {
        let label = suggestion.isPlan
            ? "Want to open the plan?"
            : "Want to open \(suggestion.fileName)?"
        HStack(spacing: 6) {
            Symbols.docPlaintextFill.image
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 240)
            Button("Yes") {
                onAcceptOpenSuggestion(suggestion)
            }
            .controlSize(.mini)
            .accessibilityLabel("Open suggested file: Yes")
            Button("No") {
                openSuggestionStore.dismiss(sessionName: session.sessionName)
            }
            .controlSize(.mini)
            .accessibilityLabel("Open suggested file: No")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
        )
        .padding(.leading, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    // MARK: - Drag and Drop

    private func handleDrop(payloads: [TabDragPayload], placement: WorkbenchTabDropPlacement) -> Bool {
        let targets = placement.targets
        guard let source = payloads.first, let target = targets.first, !targets.contains(source), effectiveTabOrder.contains(source), effectiveTabOrder.contains(target) else { return false }
        let section = sectionOf(target)
        let applyPlacement: @MainActor () -> Void = {
            sessionTabs.recordTabDrop(source, at: placement)
            finishTabPlacement(source: source, in: section)
        }
        if workbenchContext?.sharedTabLayout?.drop(source, at: placement, order: effectiveTabOrder, onSuccess: applyPlacement) == true {
            return true
        }
        if case .group = placement {
            guard sessionTabs.mergeTab(source, into: targets, visible: effectiveTabOrder) else { return false }
            applyPlacement()
            return true
        }
        guard sessionTabs.canReorder(source, before: target) else { return false }

        let previousOrder = effectiveTabOrder
        let order = placement.placing(source, in: previousOrder)
        if order == previousOrder, isOnRight(source) == (section == .right) {
            sessionTabs.updateLocalGroup(for: source, at: placement)
            return true
        }
        let windowOrderChanged = order.windowIds != session.windows.map(\.stableId)
        guard !windowOrderChanged || !sessionTabs.isWindowReorderPending else { return false }

        sessionTabs.recordVisibleTabOrder(order)
        sessionTabs.updateLocalGroup(for: source, at: placement)

        // If the drop crosses the split, also flip the source tab's side
        // membership so it shows up in the pane the user dropped it into.
        finishTabPlacement(source: source, in: section)

        // Sync the per-kind subsequences out to the rest of the app so
        // anything still iterating the old arrays (keyboard nav, tmux's
        // own window indices) sees the new order.
        syncSubsequences(from: order, rollbackOrder: previousOrder)

        return true
    }

    /// Apply the resolved trailing placement and move the tab to the destination section.
    private func handleEndDrop(payloads: [TabDragPayload], section: TabSection, placement: WorkbenchTabDropPlacement) -> Bool {
        guard let source = payloads.first, effectiveTabOrder.contains(source) else { return false }
        if
            workbenchContext?.sharedTabLayout?.drop(source, at: placement, order: effectiveTabOrder, onSuccess: {
                sessionTabs.recordTabDrop(source, at: placement)
                finishTabPlacement(source: source, in: section)
            }) == true {
            return true
        }

        let previousOrder = effectiveTabOrder
        let order = placement.placing(source, in: previousOrder)
        let windowOrderChanged = order.windowIds != session.windows.map(\.stableId)
        guard !windowOrderChanged || !sessionTabs.isWindowReorderPending else { return false }
        sessionTabs.recordVisibleTabOrder(order)
        sessionTabs.updateLocalGroup(for: source, at: placement)
        if order != previousOrder || isOnRight(source) != (section == .right) {
            finishTabPlacement(source: source, in: section)
        }
        syncSubsequences(from: order, rollbackOrder: previousOrder)
        return true
    }

    /// Which section a unified-order entry currently lives in. Every kind
    /// can land on either side now — windows render their terminal on the
    /// right pane, the file explorer renders the file tree on the right.
    private func sectionOf(_ ref: TabDragPayload) -> TabSection {
        if isOnRight(ref) {
            return .right
        }
        return isSplit ? .left : .single
    }

    private func finishTabPlacement(source: TabDragPayload, in section: TabSection) {
        let changesSide = isOnRight(source) != (section == .right)
        if changesSide {
            onToggleSplit(source)
        }
        switch source {
        case .browser,
             .file where !changesSide:
            onMoveTab(source)
        default:
            break
        }
    }

    /// Derives the windows / files / browsers subsequences from the unified
    /// `tabOrder` and pushes each one out to the matching reorder callback
    /// when it differs from the live data. Idempotent — re-invoking with the
    /// same order is a no-op.
    private func syncSubsequences(from order: [TabDragPayload], rollbackOrder: [TabDragPayload]) {
        let windowIds = order.windowIds
        let fileIds: [UUID] = order.compactMap { ref in
            if case let .file(id) = ref {
                return id
            } else {
                return nil
            }
        }
        let browserIds: [UUID] = order.compactMap { ref in
            if case let .browser(id) = ref {
                return id
            } else {
                return nil
            }
        }

        if windowIds != session.windows.map(\.stableId), !windowIds.isEmpty {
            sessionTabs.isWindowReorderPending = true
            onReorderWindows(windowIds, rollbackOrder)
        }
        if fileIds != openFileTabs.map(\.id) {
            onReorderFileTabs(fileIds)
        }
        if browserIds != openBrowserTabs.map(\.id) {
            onReorderBrowserTabs(browserIds)
        }
    }
}

// MARK: - Drag Payload

/// Transferable identifier for every entry in the unified tab strip — tmux
/// windows, the file-explorer button, open file tabs, and open browser tabs.
/// Doubles as the storage element for `SessionFileTabsState.tabOrder`, so the
/// session can persist a free-form ordering where the four kinds intermix in
/// any sequence the user has dragged them into.
enum TabDragPayload: Codable, Hashable, Transferable {
    case window(String)
    case fileExplorer
    /// The Git tab (issue #258). A singleton like `.fileExplorer` — one per
    /// session, no associated id.
    case git
    case file(UUID)
    case browser(UUID)

    /// Coarse category, used to clear a stale drop indicator when the cursor
    /// leaves a tab of one kind and enters another. Without this, an
    /// out-of-order `isTargeted=false` from a peer would wipe out the
    /// indicator that the new target just set.
    enum Kind: Hashable {
        case window
        case fileExplorer
        case git
        case file
        case browser
    }

    var kind: Kind {
        switch self {
        case .window: .window
        case .fileExplorer: .fileExplorer
        case .git: .git
        case .file: .file
        case .browser: .browser
        }
    }

    func remappingWindowID(using mapping: [String: String]) -> TabDragPayload {
        guard case let .window(windowID) = self else { return self }
        return .window(mapping[windowID] ?? windowID)
    }

    var windowId: String? {
        guard case let .window(id) = self else { return nil }
        return id
    }

    /// Reorder this native window's subset without moving tabs owned by another scene.
    static func mergingWindowOrder(_ subset: [String], into all: [String]) -> [String]? {
        let members = Set(subset)
        guard members.count == subset.count, members.isSubset(of: Set(all)) else { return nil }
        var replacement = subset.makeIterator()
        return all.map { members.contains($0) ? (replacement.next() ?? $0) : $0 }
    }

    /// Moves one entry immediately before another. Re-finding the target after
    /// removing the source keeps left-to-right and right-to-left drops
    /// symmetric and makes the result match the leading-edge indicator.
    static func moving(
        _ source: TabDragPayload,
        before target: TabDragPayload,
        in order: [TabDragPayload]
    ) -> [TabDragPayload]? {
        guard source != target, let sourceIndex = order.firstIndex(of: source) else { return nil }
        var result = order
        let moved = result.remove(at: sourceIndex)
        guard let targetIndex = result.firstIndex(of: target) else { return nil }
        result.insert(moved, at: targetIndex)
        return result == order ? nil : result
    }

    /// Restores only the window subsequence after a failed asynchronous tmux
    /// reorder. Non-window entries keep their latest positions so a file or
    /// browser drag completed while the request was pending is not lost.
    static func restoringWindowOrder(
        from previousOrder: [TabDragPayload],
        in currentOrder: [TabDragPayload]
    ) -> [TabDragPayload] {
        let previousWindowIds = previousOrder.windowIds
        let currentWindowIds = currentOrder.windowIds
        guard
            previousWindowIds.count == currentWindowIds.count,
            Set(previousWindowIds) == Set(currentWindowIds)
        else { return currentOrder }

        var iterator = previousWindowIds.makeIterator()
        return currentOrder.map { payload in
            guard payload.windowId != nil, let windowId = iterator.next() else { return payload }
            return .window(windowId)
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .ctrlxTabDrag)
    }

    /// Source-of-truth ordering for a session's tab strip. Reconciles the
    /// persisted free-form `storedOrder` (what the user dragged into place)
    /// with the live windows / file tabs / browser tabs so newly-discovered
    /// entries are slotted in and removed entries drop out, while every
    /// surviving entry keeps the user's interleaved position.
    ///
    /// Shared by the visible `WindowTabBar`, the visible `RemoteWindowTabBar`,
    /// and the Cmd-Option-Left / Cmd-Option-Right keyboard navigation (both local and
    /// remote) so every surface walks the strip in the exact same order — see
    /// issue #566, where the keyboard path used a fixed kind-grouped order and
    /// ignored reordering.
    ///
    /// Remote sessions have no file explorer or file tabs; pass
    /// `includeFileExplorer: false` for them so the synthetic `.fileExplorer`
    /// entry is neither kept nor inserted and new windows slot in before the
    /// first browser tab instead of before the (absent) explorer.
    ///
    /// Git is a local-only, explicitly opened tab. Preserve it when present
    /// in the stored order; never synthesize it. Remote sessions exclude it.
    static func reconciledOrder(
        windowIds: [String],
        fileTabIds: [UUID],
        browserTabIds: [UUID],
        storedOrder: [TabDragPayload],
        includeFileExplorer: Bool = true,
        includeGit: Bool = true
    ) -> [TabDragPayload] {
        let liveWindows = windowIds.map { TabDragPayload.window($0) }
        let liveFiles = fileTabIds.map { TabDragPayload.file($0) }
        let liveBrowsers = browserTabIds.map { TabDragPayload.browser($0) }
        var live: Set<TabDragPayload> = Set(liveWindows + liveFiles + liveBrowsers)
        if includeFileExplorer {
            live.insert(.fileExplorer)
        }
        if includeGit {
            live.insert(.git)
        }

        // Keep stored entries whose underlying data still exists, dedup'd.
        var order: [TabDragPayload] = []
        var seen: Set<TabDragPayload> = []
        for ref in storedOrder where live.contains(ref) && seen.insert(ref).inserted {
            order.append(ref)
        }

        // New windows slot in just before the file-explorer button (or, on
        // remote sessions with no explorer, the first browser tab) — preserves
        // the default layout (windows, folder, git, files/browsers) for first
        // runs and late-joining tmux windows.
        var insertAt: Int
        if includeFileExplorer {
            insertAt = order.firstIndex(of: .fileExplorer) ?? order.count
        } else {
            insertAt = order.firstIndex {
                if case .browser = $0 {
                    true
                } else {
                    false
                }
            } ?? order.count
        }
        for window in liveWindows where seen.insert(window).inserted {
            order.insert(window, at: insertAt)
            insertAt += 1
        }
        if includeFileExplorer, seen.insert(.fileExplorer).inserted {
            order.insert(.fileExplorer, at: insertAt)
        }
        // New file/browser tabs append at the end.
        for tab in liveFiles + liveBrowsers where seen.insert(tab).inserted {
            order.append(tab)
        }
        return order
    }
}

private extension Array where Element == TabDragPayload {
    var windowIds: [String] {
        compactMap(\.windowId)
    }
}

extension UTType {
    /// Custom UTI used for tab-strip drags. The identifier is declared in
    /// `CtrlxServer/Info.plist` under `UTExportedTypeDeclarations` so
    /// the system can resolve it without a runtime warning and
    /// `.dropDestination(for:)` accepts the payload reliably.
    static var ctrlxTabDrag: UTType {
        UTType(exportedAs: "com.jicezeng.ctrlx.tab-drag")
    }
}
