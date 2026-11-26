import CtrlxCommon
import CtrlxNetworking
import Foundation
import Observation

struct PendingFolderLayout: Sendable {
    var snapshot: SavedFolderLayout
    var needsSavedLayout: Bool
    var waitsForDetachedTabs = false
    var browserEdits: [UUID: LayoutSnapshotMapper.BrowserEdit] = [:]
    var privateTabOrder: SavedFolderLayout?
    var appliedTerminalRevision: UInt64?
    var detachedRightTerminals: (ids: [String], selected: String?) = ([], nil)
    var updatesTerminalPlacement = false
    var updatesTabOrder = false
    var terminalSelectionSides: Set<Bool> = []
    var splitRatio: CGFloat?
}

/// Per-native-window presentation state; the terminal and browser services remain shared.
@MainActor @Observable
final class WorkbenchTabStore {
    struct Selection: Equatable {
        var hostID: String?
        var sessionName: String
        var windowID: String?
    }

    var local: [String: SessionFileTabsState] = [:]
    var remote: [RemoteSessionTabsKey: SessionFileTabsState] = [:]
    var remoteRecoveryReferences: [RemoteSessionTabsKey: ViewerWorkspaceReference] = [:]
    var restoredRemoteSessions: Set<RemoteSessionTabsKey> = []
    var unavailableRemoteFileIDs: Set<UUID> = []
    var recoverySelection: Selection?
    var restoredSelection: Selection?
    var pendingPaneSelection: DetachedTerminalWindows.SourcePaneRequest?
    var restorationRevision = 0
    @ObservationIgnored private(set) var userSelectionRevision = 0
    @ObservationIgnored private var remoteTabSelectionRevisions: [RemoteSessionTabsKey: Int] = [:]
    var restoredLocalSessions: Set<String> = []
    var seededFolders: [String: String] = [:]
    @ObservationIgnored var pendingFolderLayouts: [String: [String: PendingFolderLayout]] = [:]
    @ObservationIgnored var closedEditorPaths: [String: [String: Set<String>]] = [:]
    var recoveryFileTrees: [String: SavedFileTree] = [:]
    var recoveryGitPaths: [String: String] = [:]
    var recoveryGitStates: [String: WorkspaceGitState] = [:]
    var pendingGitRecoverySessions: Set<String> = []
    var restoredRecoveryWindowIDs: [UUID: Set<UUID>] = [:]
    var restoredRecoveryFileIDs: Set<UUID> = []
    @ObservationIgnored var capturePresentation: (() -> Void)?
    @ObservationIgnored var onResourceTransferred: ((String?, String, Bool) -> Void)?

    /// Automatic fallbacks and Host snapshots must not cancel a pending restore.
    func userDidSelectSession() {
        userSelectionRevision += 1
        restoredSelection = nil
        pendingPaneSelection = nil
    }

    func requestPaneSelection(hostID: String?, pane: PaneState) {
        userDidSelectTab(hostID: hostID, session: pane.sessionName)
        pendingPaneSelection = .init(hostID: hostID, pane: pane)
    }

    func takePaneSelection(in session: SidebarSessionSelection?) -> DetachedTerminalWindows.SourcePaneRequest? {
        guard let request = pendingPaneSelection else { return nil }
        let target: SidebarSessionSelection = if let hostID = request.hostID {
            .remote(hostID: hostID, sessionName: request.pane.sessionName)
        } else {
            .local(sessionName: request.pane.sessionName)
        }
        guard session == target else { return nil }
        pendingPaneSelection = nil
        return request
    }

    func userDidSelectTab(hostID: String?, session: String, onRight: Bool? = nil) {
        userDidSelectSession()
        if let hostID {
            remoteTabSelectionRevisions[.init(hostId: hostID, sessionName: session), default: 0] += 1
        } else if let tabs = local[session] {
            tabs.recordTabSelection(onRight: onRight)
        }
    }

    func tabSelectionRevision(hostID: String, session: String) -> Int {
        remoteTabSelectionRevisions[.init(hostId: hostID, sessionName: session), default: 0]
    }

    func takeGitRecovery(for session: String) -> WorkspaceGitState? {
        guard pendingGitRecoverySessions.remove(session) != nil else { return nil }
        return recoveryGitStates[session]
    }

    func recordGitState(_ state: WorkspaceGitState, for session: String) {
        // The scene can still hold its pre-move store until the snapshot is consumed.
        guard !pendingGitRecoverySessions.contains(session) else { return }
        recoveryGitPaths[session] = state.directory
        recoveryGitStates[session] = state
    }

    func existing(hostID: String?, session: String) -> SessionFileTabsState? {
        if let hostID {
            return remote[RemoteSessionTabsKey(hostId: hostID, sessionName: session)]
        }
        return local[session]
    }

    func tabs(hostID: String?, session: String) -> SessionFileTabsState {
        if let hostID {
            let key = RemoteSessionTabsKey(hostId: hostID, sessionName: session)
            if let tabs = remote[key] {
                return tabs
            }
            let tabs = SessionFileTabsState()
            remote[key] = tabs
            return tabs
        }
        if let tabs = local[session] {
            return tabs
        }
        let tabs = SessionFileTabsState()
        local[session] = tabs
        return tabs
    }

    func renameSession(hostID: String?, from oldName: String, to newName: String, windowIDs: [String: String]) {
        if let hostID {
            let oldKey = RemoteSessionTabsKey(hostId: hostID, sessionName: oldName)
            let newKey = RemoteSessionTabsKey(hostId: hostID, sessionName: newName)
            if let revision = remoteTabSelectionRevisions.removeValue(forKey: oldKey) {
                remoteTabSelectionRevisions[newKey] = revision
            }
            if let reference = remoteRecoveryReferences.removeValue(forKey: oldKey) {
                remoteRecoveryReferences[newKey] = reference
            }
            if restoredRemoteSessions.remove(oldKey) != nil {
                restoredRemoteSessions.insert(newKey)
            }
            if recoverySelection?.hostID == hostID, recoverySelection?.sessionName == oldName {
                recoverySelection?.sessionName = newName
                if restoredSelection == nil {
                    restoredSelection = recoverySelection
                    restorationRevision += 1
                }
            }
            if restoredSelection?.hostID == hostID, restoredSelection?.sessionName == oldName {
                restoredSelection?.sessionName = newName
                restorationRevision += 1
            }
            guard let tabs = remote.removeValue(forKey: oldKey) else { return }
            tabs.remapWindowIDs(windowIDs)
            remote[.init(hostId: hostID, sessionName: newName)] = tabs
        } else {
            guard let tabs = local.removeValue(forKey: oldName) else { return }
            tabs.remapWindowIDs(windowIDs)
            local[newName] = tabs
            if restoredLocalSessions.remove(oldName) != nil {
                restoredLocalSessions.insert(newName)
            }
            recoveryGitStates[newName] = recoveryGitStates.removeValue(forKey: oldName)
            recoveryGitPaths[newName] = recoveryGitPaths.removeValue(forKey: oldName)
            if pendingGitRecoverySessions.remove(oldName) != nil {
                pendingGitRecoverySessions.insert(newName)
            }
        }
    }

    /// Move the live layout as a unit; merge tabs opened in the destination meanwhile.
    func moveSession(hostID: String?, session: String, to destination: WorkbenchTabStore, selection: Selection? = nil) {
        guard self !== destination, let source = existing(hostID: hostID, session: session) else { return }
        if let previous = destination.existing(hostID: hostID, session: session), previous !== source {
            let previousOrder = previous.tabOrder
            let previousRight = previous.rightSide
            let previousSelectedRight = previous.selectedRight
            let owned = Set(source.tabOrder)
            for tab in previous.openFileTabs {
                previous.move(.file(tab.id), to: source)
            }
            for tab in previous.openBrowserTabs {
                previous.move(.browser(tab.id), to: source)
            }
            source.tabOrder += previousOrder.filter { !source.tabOrder.contains($0) }
            source.rightSide.formUnion(previousRight.subtracting(owned))
            if source.selectedRight == nil, let previousSelectedRight, source.rightSide.contains(previousSelectedRight) {
                source.selectedRight = previousSelectedRight
            }
        }
        if let hostID {
            let key = RemoteSessionTabsKey(hostId: hostID, sessionName: session)
            remote.removeValue(forKey: key)
            destination.remote[key] = source
            if let reference = remoteRecoveryReferences.removeValue(forKey: key) {
                destination.remoteRecoveryReferences[key] = reference
            }
            if restoredRemoteSessions.remove(key) != nil {
                destination.restoredRemoteSessions.insert(key)
            }
        } else {
            local.removeValue(forKey: session)
            destination.local[session] = source
            destination.recoveryFileTrees[session] = recoveryFileTrees.removeValue(forKey: session)
            destination.recoveryGitPaths[session] = recoveryGitPaths.removeValue(forKey: session)
            destination.recoveryGitStates[session] = recoveryGitStates.removeValue(forKey: session)
            pendingGitRecoverySessions.remove(session)
            if destination.recoveryGitStates[session] != nil {
                destination.pendingGitRecoverySessions.insert(session)
            } else {
                destination.pendingGitRecoverySessions.remove(session)
            }
        }
        if let selection {
            destination.recoverySelection = selection
            destination.restoredSelection = selection
            destination.restorationRevision += 1
        }
    }

    var isEmpty: Bool {
        (Array(local.values) + Array(remote.values)).allSatisfy { $0.openFileTabs.isEmpty && $0.openBrowserTabs.isEmpty }
    }
}

@MainActor @Observable
final class DetachedTerminalWorkspace {
    let id: UUID
    var anchor: DetachedTerminalTarget?
    let hostID: String?
    var sessionName: String?
    var isSessionWindow = false
    var members: [DetachedTerminalTarget]
    var selection: TabDragPayload
    var selectionRevision = 0
    let tabs = WorkbenchTabStore()
    @ObservationIgnored var onClose: () -> Void = { }

    init(id: UUID = UUID(), target: DetachedTerminalTarget, sessionName: String? = nil) {
        self.id = id
        self.anchor = target
        self.hostID = target.hostID
        self.sessionName = sessionName
        self.members = [target]
        self.selection = .window(target.windowID)
    }

    init(id: UUID = UUID(), hostID: String?, sessionName: String, selection: TabDragPayload) {
        self.id = id
        self.hostID = hostID
        self.sessionName = sessionName
        self.members = []
        self.selection = selection
    }

    /// Keep the workbench's session after its last terminal exits or moves away.
    func resolvedSession(using session: (DetachedTerminalTarget) -> String?) -> String? {
        members.compactMap(session).first ?? sessionName ?? anchor.flatMap(session)
    }

    func renameSession(hostID: String?, from oldName: String, to newName: String, windowIDs: [String: String]) {
        guard self.hostID == hostID, sessionName == oldName else { return }
        tabs.renameSession(hostID: hostID, from: oldName, to: newName, windowIDs: windowIDs)
        sessionName = newName
    }

    func select(_ target: DetachedTerminalTarget) {
        guard members.contains(target) else { return }
        selection = .window(target.windowID)
        selectionRevision += 1
    }
}

enum WorkspaceTerminalSelection {
    /// Edit session-wide placement before projecting it into the native windows.
    static func splitRequest(
        _ request: SetSharedTerminalLayout, windowID: String, onRight: Bool, select: Bool,
        windowIDs: [String], activeWindowID: String?, keepLocalSplit: Bool = false
    ) -> SetSharedTerminalLayout {
        var right = Set(request.rightWindowIds).intersection(windowIDs)
        if onRight {
            right.insert(windowID)
        } else {
            right.remove(windowID)
        }
        let preferredLeft = !onRight && select ? windowID : request.leftWindowId
        if windowIDs.allSatisfy(right.contains) {
            guard !keepLocalSplit else { return request }
            right.removeAll()
        }
        guard
            let left = leftWindowID(
                current: preferredLeft, orderedIDs: windowIDs, activeID: activeWindowID,
                rightSide: right, owns: { _ in true }
            ) else { return request }

        let orderedRight = right == Set(request.rightWindowIds)
            ? request.rightWindowIds : windowIDs.filter { right.remove($0) != nil }
        let selected = onRight && select ? windowID : request.selectedRightWindowId
        return SetSharedTerminalLayout(
            sessionName: request.sessionName, leftWindowId: left, rightWindowIds: orderedRight,
            selectedRightWindowId: selected.flatMap { orderedRight.contains($0) ? $0 : nil } ?? orderedRight.first,
            splitRatio: request.splitRatio
        )
    }

    struct Window: Equatable {
        let hostID: String
        let id: String
        let stableId: String
        let sessionName: String
        let isWindowActive: Bool

        init(_ window: TmuxWindow, hostID: String) {
            self.hostID = hostID
            self.id = window.id
            self.stableId = window.stableId
            self.sessionName = window.sessionName
            self.isWindowActive = window.isWindowActive
        }
    }

    static func leftWindowID(
        current: String?, orderedIDs: [String], activeID: String?,
        rightSide: Set<String>, followsActive: Bool = false,
        owns: (String) -> Bool
    ) -> String? {
        let eligible = orderedIDs.filter { owns($0) && !rightSide.contains($0) }
        let active = activeID.flatMap { eligible.contains($0) ? $0 : nil }
        if let current, !orderedIDs.contains(current) {
            return eligible.first
        }
        if followsActive, let active {
            return active
        }
        if let current, eligible.contains(current) {
            return current
        }
        return active ?? eligible.first
    }
}

extension SessionFileTabsState {
    func remoteRightWindowIDs(in layout: SharedTerminalLayout, sessionWindowIDs: [String]) -> [String] {
        let members = layout.sessionWindowIds ?? sessionWindowIDs
        var right = layout.rightWindowIds.filter { remoteTerminalPlacements[$0] != false }
        for id in members
            where remoteTerminalPlacements[id] == true && !right.contains(id) {
            right.append(id)
        }
        guard pendingRemoteTerminalOrder != nil || remoteTerminalPlacements.contains(where: { id, onRight in onRight || layout.rightWindowIds.contains(id) }) else { return right }
        // Fallback selection must not depend on how moves were batched into requests.
        return Self.orderedRightWindowIDs(right, by: pendingRemoteTerminalOrder ?? members)
    }

    static func orderedRightWindowIDs(_ ids: [String], by order: [String]) -> [String] {
        ids.sorted {
            let lhs = order.firstIndex(of: $0) ?? order.count
            let rhs = order.firstIndex(of: $1) ?? order.count
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
    }

    func hasRemoteSplitAlternative(to id: String, sessionWindowIDs: [String]) -> Bool {
        guard let layout = appliedSharedTerminalLayout else { return sessionWindowIDs.contains { $0 != id } }
        let right = Set(remoteRightWindowIDs(in: layout, sessionWindowIDs: sessionWindowIDs))
        let members = layout.sessionWindowIds ?? sessionWindowIDs
        return members.contains { $0 != id && !right.contains($0) }
            || (layout.leftWindowId != id && !right.contains(layout.leftWindowId))
    }

    func remoteTerminalLayoutRequest(
        sessionName: String, sessionWindowIDs: [String], visibleWindowIDs: [String],
        selectedLeftWindowID: String?, shared: SharedTerminalLayout
    ) -> SetSharedTerminalLayout? {
        guard appliedSharedTerminalLayout == shared else { return nil }
        let visible = Set(visibleWindowIDs)
        let right = remoteRightWindowIDs(in: shared, sessionWindowIDs: sessionWindowIDs)
        let members = shared.sessionWindowIds ?? sessionWindowIDs
        let explicitLeft = explicitRemoteLeftTerminalID.flatMap { members.contains($0) ? $0 : nil }
        var left = shared.leftWindowId
        if visible.contains(left) {
            left = explicitLeft ?? selectedLeftWindowID ?? left
        }
        if right.contains(left) {
            guard
                let candidate = explicitLeft.flatMap({ right.contains($0) ? nil : $0 })
                ?? members.first(where: { !right.contains($0) }) else { return nil }
            left = candidate
        }
        let localRight = rightSideWindowIds
        let removed = remoteTerminalPlacements.filter { !$0.value }.keys.sorted()
        let displayedRatio = visible.isDisjoint(with: localRight) ? shared.splitRatio : Double(splitRatio)
        let ratio = pendingRemoteSplitRatio.map { Double($0) } ?? displayedRatio
        let previousSelection = shared.selectedRightWindowId.flatMap { right.contains($0) ? $0 : nil }
        let selected = if let explicit = explicitRemoteRightTerminalID, right.contains(explicit) {
            explicit
        } else if let previousSelection, !visible.contains(previousSelection) {
            previousSelection
        } else {
            selectedRight?.windowId.flatMap { right.contains($0) ? $0 : nil } ?? previousSelection ?? right.first
        }
        return SetSharedTerminalLayout(
            sessionName: sessionName, leftWindowId: left, rightWindowIds: right, selectedRightWindowId: selected,
            splitRatio: ratio,
            removedRightWindowIds: removed.isEmpty ? nil : removed
        )
    }

    func selectedDirectoryPath(onRight: Bool = false) -> String? {
        let id: UUID
        if onRight {
            guard case let .file(rightID) = selectedRight else { return nil }
            id = rightID
        } else {
            guard let selectedFileTabId else { return nil }
            id = selectedFileTabId
        }
        return directoryTabs[id]?.path
            ?? openFileTabs.first(where: { $0.id == id && !$0.isDirectory })?.directoryPath
    }

    func focusContentSearch(createIfNeeded: () -> FileBrowserTab?) {
        guard let tab = selectedFileTabId.flatMap({ directoryTabs[$0] }) ?? createIfNeeded() else { return }
        tab.searchMode = .content
        tab.searchFocusRequest += 1
    }

    func repairLeftContent(hasTerminal: Bool) {
        if
            let id = selectedFileTabId,
            openFileTabs.contains(where: { $0.id == id }), !rightSide.contains(.file(id)) {
            return
        }
        selectedFileTabId = nil
        if
            let id = selectedBrowserTabId,
            openBrowserTabs.contains(where: { $0.id == id }), !rightSide.contains(.browser(id)) {
            return
        }
        selectedBrowserTabId = nil
        if isGitSelected, !rightSide.contains(.git) {
            return
        }
        isGitSelected = false
        guard !hasTerminal else { return }
        let order = TabDragPayload.reconciledOrder(
            windowIds: [], fileTabIds: openFileTabs.map(\.id), browserTabIds: openBrowserTabs.map(\.id),
            storedOrder: tabOrder, includeFileExplorer: false, includeGit: isGitOpen
        )
        switch order.first(where: { !rightSide.contains($0) }) {
        case .git: selectLeftGit()
        case let .file(id): selectedFileTabId = id
        case let .browser(id): selectedBrowserTabId = id
        default: break
        }
    }

    /// Move live state, not a snapshot: directory selection, WebKit history and CEF identity survive.
    @discardableResult
    func move(_ tab: TabDragPayload, to destination: SessionFileTabsState) -> Bool {
        guard self !== destination else { return true }
        switch tab {
        case .window: break
        case let .file(id):
            guard let index = openFileTabs.firstIndex(where: { $0.id == id }) else { return false }
            cancelClosingHostFileTab(id)
            destination.openFileTabs.append(openFileTabs.remove(at: index))
            destination.directoryTabs[id] = directoryTabs.removeValue(forKey: id)
            destination.scrollOffsets[id] = scrollOffsets.removeValue(forKey: id)
        case let .browser(id):
            guard let index = openBrowserTabs.firstIndex(where: { $0.id == id }) else { return false }
            destination.openBrowserTabs.append(openBrowserTabs.remove(at: index))
            destination.browserStates[id] = browserStates.removeValue(forKey: id)
            destination.agentBrowserStates[id] = agentBrowserStates.removeValue(forKey: id)
            destination.remoteBrowserTabs[id] = remoteBrowserTabs.removeValue(forKey: id)
            destination.simulatorStates[id] = simulatorStates.removeValue(forKey: id)
            destination.remoteSimulatorTabs[id] = remoteSimulatorTabs.removeValue(forKey: id)
        default: return false
        }
        destination.tabFolders[tab] = tabFolders.removeValue(forKey: tab)
        tabOrder.removeAll { $0 == tab }
        manualTabGroups.removeValue(forKey: tab)
        rightSide.remove(tab)
        if selectedRight == tab {
            selectedRight = nil
        }
        if selectedRight == nil {
            selectedRight = tabOrder.first { rightSide.contains($0) }
        }
        if case let .file(id) = tab, selectedFileTabId == id {
            selectedFileTabId = nil
        }
        if case let .browser(id) = tab, selectedBrowserTabId == id {
            selectedBrowserTabId = nil
        }
        if !destination.tabOrder.contains(tab) {
            destination.tabOrder.append(tab)
        }
        return true
    }
}

enum WorkbenchDirectoryContext {
    @MainActor
    static func resolve(
        terminalPath: String?, tabs: SessionFileTabsState?, retainedGitPath: String?, homeDirectory: String,
        onRight: Bool = false
    ) -> String {
        terminalPath ?? tabs?.selectedDirectoryPath(onRight: onRight) ?? retainedGitPath ?? homeDirectory
    }
}
