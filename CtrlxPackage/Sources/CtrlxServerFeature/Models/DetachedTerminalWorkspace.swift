import CtrlxCommon
import Foundation
import Observation

/// Per-native-window presentation state; the terminal and browser services remain shared.
@MainActor @Observable
final class WorkbenchTabStore {
    var local: [String: SessionFileTabsState] = [:]
    var remote: [RemoteSessionTabsKey: SessionFileTabsState] = [:]

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
            guard let tabs = remote.removeValue(forKey: .init(hostId: hostID, sessionName: oldName)) else { return }
            tabs.remapWindowIDs(windowIDs)
            remote[.init(hostId: hostID, sessionName: newName)] = tabs
        } else {
            guard let tabs = local.removeValue(forKey: oldName) else { return }
            tabs.remapWindowIDs(windowIDs)
            local[newName] = tabs
        }
    }

    var isEmpty: Bool {
        (Array(local.values) + Array(remote.values)).allSatisfy { $0.openFileTabs.isEmpty && $0.openBrowserTabs.isEmpty }
    }
}

@MainActor @Observable
final class DetachedTerminalWorkspace {
    let id = UUID()
    let anchor: DetachedTerminalTarget
    var sessionName: String?
    var members: [DetachedTerminalTarget]
    var selection: TabDragPayload
    var selectionRevision = 0
    let tabs = WorkbenchTabStore()
    @ObservationIgnored var onClose: () -> Void = { }

    init(target: DetachedTerminalTarget, sessionName: String? = nil) {
        self.anchor = target
        self.sessionName = sessionName
        self.members = [target]
        self.selection = .window(target.windowID)
    }

    /// Keep the workbench's session after its last terminal exits or moves away.
    func resolvedSession(using session: (DetachedTerminalTarget) -> String?) -> String? {
        members.compactMap(session).first ?? sessionName ?? session(anchor)
    }

    func renameSession(hostID: String?, from oldName: String, to newName: String, windowIDs: [String: String]) {
        guard anchor.hostID == hostID, sessionName == oldName else { return }
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
    static func leftWindowID(
        current: String?, orderedIDs: [String], activeID: String?,
        rightSide: Set<String>, followsActive: Bool = false,
        owns: (String) -> Bool
    ) -> String? {
        let eligible = orderedIDs.filter { owns($0) && !rightSide.contains($0) }
        let active = activeID.flatMap { eligible.contains($0) ? $0 : nil }
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
            storedOrder: tabOrder, includeFileExplorer: false, includeGit: false
        )
        switch order.first(where: { !rightSide.contains($0) }) {
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
            guard let index = openBrowserTabs.firstIndex(where: { $0.id == id }), !openBrowserTabs[index].isSimulator else { return false }
            destination.openBrowserTabs.append(openBrowserTabs.remove(at: index))
            destination.browserStates[id] = browserStates.removeValue(forKey: id)
            destination.agentBrowserStates[id] = agentBrowserStates.removeValue(forKey: id)
            destination.remoteBrowserTabs[id] = remoteBrowserTabs.removeValue(forKey: id)
        default: return false
        }
        tabOrder.removeAll { $0 == tab }
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
