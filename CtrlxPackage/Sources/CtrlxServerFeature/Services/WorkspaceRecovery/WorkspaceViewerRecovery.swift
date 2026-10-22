import CtrlxCommon
import CtrlxNetworking
import Foundation
import Observation

/// Viewer-owned presentation only. All runtime routes come from fresh Host
/// catalogs; this adapter never creates tmux objects or resumes Agents.
@MainActor @Observable
final class WorkspaceViewerRecovery {
    private(set) var scenes: [WorkspaceRecoveryScene] = []
    private(set) var catalogs: [String: ViewerWorkspaceCatalog] = [:]
    @ObservationIgnored private var states: [String: SessionStateMessage] = [:]
    @ObservationIgnored private var applied: [UUID: Set<ViewerWorkspaceReference>] = [:]
    @ObservationIgnored private var appliedWindows: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private var appliedFiles: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private var materializedScenes: Set<UUID> = []
    @ObservationIgnored private var selectionRevisions: [UUID: Int] = [:]
    @ObservationIgnored private var tabSelectionRevisions: [UUID: [ViewerWorkspaceReference: Int]] = [:]
    private var loaded = false

    func restore(_ saved: [WorkspaceRecoveryScene]?, windows: DetachedTerminalWindows) {
        guard !loaded else { return }
        loaded = true
        scenes = saved ?? []
        // Display the saved Host/session while offline instead of choosing a
        // same-named session on whichever Host happens to connect first.
        for scene in scenes where scene.isMain {
            rememberSelectionRevisions(scene, store: windows.mainTabs)
            windows.mainSceneID = scene.id
            if let frame = scene.frame {
                windows.restoreMainFrame(frame)
            }
            for presentation in scene.sessions {
                if let reference = presentation.remoteReference {
                    windows.mainTabs.remoteRecoveryReferences[.init(hostId: reference.pairID, sessionName: presentation.sessionName)] = reference
                    windows.mainTabs.restoredRemoteSessions.insert(.init(hostId: reference.pairID, sessionName: presentation.sessionName))
                }
            }
            if let selected = scene.sessions.first(where: { $0.sessionID == scene.selectedSessionID && $0.hostID == scene.selectedHostID }) {
                windows.mainTabs.restoredSelection = .init(hostID: selected.hostID, sessionName: selected.sessionName, windowID: nil)
                windows.mainTabs.restorationRevision += 1
            }
        }
    }

    func allowsRendering(hostID: String, session: String, store: WorkbenchTabStore) -> Bool {
        guard let expected = store.remoteRecoveryReferences[.init(hostId: hostID, sessionName: session)] else { return true }
        return catalogs[hostID]?.resolve(expected)?.sessionName == session
    }

    func selectSession(hostID: String, session: String, store: WorkbenchTabStore) {
        store.userDidSelectSession()
        let key = RemoteSessionTabsKey(hostId: hostID, sessionName: session)
        guard states[hostID] != nil else { return }
        let current = catalogs[hostID]?.reference(sessionName: session)
        if let previous = store.remoteRecoveryReferences[key], previous != current {
            store.remote[key]?.cancelActiveBrowserDownloads()
            store.remote.removeValue(forKey: key)
            store.restoredRemoteSessions.remove(key)
        }
        store.remoteRecoveryReferences[key] = current
    }

    private func rememberSelectionRevisions(_ scene: WorkspaceRecoveryScene, store: WorkbenchTabStore) {
        if selectionRevisions[scene.id] == nil {
            selectionRevisions[scene.id] = store.userSelectionRevision
        }
        for saved in scene.sessions {
            guard let reference = saved.remoteReference, tabSelectionRevisions[scene.id]?[reference] == nil else { continue }
            tabSelectionRevisions[scene.id, default: [:]][reference] = store.tabSelectionRevision(hostID: reference.pairID, session: saved.sessionName)
        }
    }

    private func canRestoreTabSelection(_ reference: ViewerWorkspaceReference, session: String, sceneID: UUID, store: WorkbenchTabStore) -> Bool {
        store.tabSelectionRevision(hostID: reference.pairID, session: session) == (tabSelectionRevisions[sceneID]?[reference] ?? 0)
    }

    func capture(windows: DetachedTerminalWindows) -> [WorkspaceRecoveryScene] {
        guard loaded else { return scenes }
        let stores = [(windows.mainSceneID, true, windows.mainTabs, windows.mainFrame)]
            + windows.workspaces.values.filter { $0.anchor.hostID != nil }.map { ($0.id, false, $0.tabs, windows.frame(for: $0.id)) }
        let visibleScenes = Set(stores.map { $0.0 })
        for closed in scenes where materializedScenes.contains(closed.id) && !visibleScenes.contains(closed.id) {
            returnPendingToMain(closed, mainID: windows.mainSceneID)
        }
        scenes.removeAll { materializedScenes.contains($0.id) && !visibleScenes.contains($0.id) }
        for (id, main, store, frame) in stores {
            store.capturePresentation?()
            var scene = scenes.first { $0.id == id } ?? .init(id: id, isMain: main, sessions: [])
            rememberSelectionRevisions(scene, store: store)
            scene.frame = frame ?? scene.frame
            let selection = store.restoredSelection ?? store.recoverySelection
            if let selection {
                scene.selectedHostID = selection.hostID
                scene.selectedSessionID = selection.hostID.flatMap { host in
                    store.remoteRecoveryReferences[.init(hostId: host, sessionName: selection.sessionName)]?.sessionID
                        ?? catalogs[host]?.reference(sessionName: selection.sessionName)?.sessionID
                        ?? scene.sessions.first { $0.hostID == host && $0.sessionName == selection.sessionName }?.sessionID
                }
            }
            for (key, tabs) in store.remote {
                guard
                    let catalog = catalogs[key.hostId], let reference = catalog.reference(sessionName: key.sessionName),
                    allowsRendering(hostID: key.hostId, session: key.sessionName, store: store), let state = states[key.hostId] else { continue }
                let remoteWindows = TmuxWindow.groupPanes(Array(state.paneStates.values)).filter { $0.sessionName == key.sessionName }
                let owned = remoteWindows.filter { windows.owner(hostID: key.hostId, windowID: $0.stableId) == (main ? nil : id) }
                var layout = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, includeHostFiles: true, includeUnavailableFiles: true) { runtime in
                    remoteWindows.first { $0.stableId == runtime }?.windowIndex
                }
                let indices = Set(owned.map(\.windowIndex))
                func unowned(_ ref: SavedTabRef) -> Bool {
                    if case let .window(index) = ref {
                        return !indices.contains(index)
                    }
                    return false
                }
                layout.tabOrder.removeAll(where: unowned)
                layout.rightSide.removeAll(where: unowned)
                if let selected = layout.selectedLeft, unowned(selected) {
                    layout.selectedLeft = nil
                }
                if let selected = layout.selectedRight, unowned(selected) {
                    layout.selectedRight = nil
                }
                for window in owned where !layout.tabOrder.contains(.window(index: window.windowIndex)) {
                    layout.tabOrder.append(.window(index: window.windowIndex))
                }
                let windowIDs = Dictionary(uniqueKeysWithValues: remoteWindows.compactMap { window -> (Int, UUID)? in
                    catalog.reference(sessionName: key.sessionName, windowID: window.stableId)?.windowID.map { (window.windowIndex, $0) }
                })
                let previous = scene.sessions.first { $0.remoteReference == reference }
                if previous == nil {
                    applied[id, default: []].insert(reference)
                }
                appliedFiles[id, default: []].formUnion(layout.fileTabs.map(\.id))
                appliedWindows[id, default: []].formUnion(owned.compactMap { windowIDs[$0.windowIndex] })
                let fileIDs = Set(layout.fileTabs.map(\.id))
                let sources = Dictionary(uniqueKeysWithValues: tabs.directoryTabs.values.compactMap { tab -> (UUID, ViewerWorkspaceReference)? in
                    guard fileIDs.contains(tab.id) else { return nil }
                    let live = tab.sourcePaneID.flatMap { catalog.reference(paneID: $0) }
                    let source = live?.sessionReference == reference ? live : previous?.fileSources?[tab.id]
                    return source.map { (tab.id, $0) }
                })
                let selectedWindow = selection.flatMap { selection -> UUID? in
                    guard
                        selection.hostID == key.hostId, selection.sessionName == key.sessionName,
                        let runtime = selection.windowID, owned.contains(where: { $0.stableId == runtime }) else { return nil }
                    return catalog.reference(sessionName: key.sessionName, windowID: runtime)?.windowID
                }
                var presentation = WorkspaceRecoveryPresentation(
                    hostID: key.hostId, sessionID: reference.sessionID, sessionName: key.sessionName, layout: layout,
                    windowIDs: windowIDs, ownedWindowIDs: owned.compactMap { windowIDs[$0.windowIndex] },
                    focusedRight: tabs.isRightPaneFocused, fileScrollOffsets: tabs.scrollOffsets,
                    selectedWindowID: selectedWindow, remoteReference: reference, fileSources: sources
                )
                if let previous {
                    preservePending(
                        from: previous, sceneID: id, into: &presentation,
                        selection: canRestoreTabSelection(reference, session: key.sessionName, sceneID: id, store: store),
                        nativeSelection: selectionRevisions[id] == store.userSelectionRevision
                    )
                }
                scene.sessions.removeAll { $0.remoteReference == reference }
                scene.sessions.append(presentation)
                store.remoteRecoveryReferences[key] = reference
            }
            scene.sessions.sort { ($0.hostID ?? "", $0.sessionID.uuidString) < ($1.hostID ?? "", $1.sessionID.uuidString) }
            scenes.removeAll { $0.id == id }
            scenes.append(scene)
            materializedScenes.insert(id)
        }
        scenes.sort { $0.id.uuidString < $1.id.uuidString }
        return scenes
    }

    /// Partial discovery must keep unopened slots while preserving subsequent
    /// user edits to the already restored tabs.
    private func preservePending(from saved: WorkspaceRecoveryPresentation, sceneID: UUID, into current: inout WorkspaceRecoveryPresentation, selection: Bool = true, nativeSelection: Bool = true) {
        var pending: [SavedTabRef] = []
        for file in saved.layout.fileTabs where !(appliedFiles[sceneID] ?? []).contains(file.id) && !current.layout.fileTabs.contains(where: { $0.id == file.id }) {
            current.layout.fileTabs.append(file)
            if current.fileSources == nil {
                current.fileSources = [:]
            }
            current.fileSources?[file.id] = saved.fileSources?[file.id]
            current.fileScrollOffsets[file.id] = saved.fileScrollOffsets[file.id]
            pending.append(.file(id: file.id))
        }
        for id in saved.ownedWindowIDs where !(appliedWindows[sceneID] ?? []).contains(id) && !current.ownedWindowIDs.contains(id) {
            guard let old = saved.windowIDs.first(where: { $0.value == id })?.key else { continue }
            let index = current.windowIDs.first(where: { $0.value == id })?.key
                ?? (current.windowIDs[old] == nil ? old : (current.windowIDs.keys.max() ?? 0) + 1)
            current.windowIDs[index] = id
            current.ownedWindowIDs.append(id)
            pending.append(.window(index: index))
        }
        func remap(_ ref: SavedTabRef) -> SavedTabRef? {
            guard case let .window(index) = ref else { return ref }
            guard let id = saved.windowIDs[index], let mapped = current.windowIDs.first(where: { $0.value == id })?.key else { return nil }
            return .window(index: mapped)
        }
        let order = saved.layout.tabOrder.compactMap(remap)
        let right = saved.layout.rightSide.compactMap(remap)
        let leftSelection = saved.layout.selectedLeft.flatMap(remap)
        let rightSelection = saved.layout.selectedRight.flatMap(remap)
        for ref in order.filter({ pending.contains($0) }) + pending.filter({ !order.contains($0) }) {
            Self.insertMissing(ref, order: order, into: &current.layout.tabOrder)
            if right.contains(ref), !current.layout.rightSide.contains(ref) {
                current.layout.rightSide.append(ref)
            }
            if selection, leftSelection == ref {
                current.layout.selectedLeft = ref
                if !saved.focusedRight {
                    current.focusedRight = false
                }
            }
            if selection, rightSelection == ref {
                current.layout.selectedRight = ref
                if saved.focusedRight {
                    current.focusedRight = true
                }
            }
        }
        if nativeSelection, let selected = saved.selectedWindowID, !(appliedWindows[sceneID] ?? []).contains(selected) {
            current.selectedWindowID = selected
            if !saved.focusedRight, saved.layout.selectedLeft == nil {
                current.focusedRight = false
            }
        }
    }

    private static func insertMissing<T: Equatable>(_ item: T, order: [T], into current: inout [T]) {
        guard !current.contains(item) else { return }
        let following = order.firstIndex(of: item).map { order.suffix(from: $0 + 1) } ?? []
        let index = following.compactMap { current.firstIndex(of: $0) }.first ?? current.endIndex
        current.insert(item, at: index)
    }

    private func returnPendingToMain(_ closed: WorkspaceRecoveryScene, mainID: UUID) {
        var main = scenes.first { $0.id == mainID } ?? .init(id: mainID, isMain: true, sessions: [])
        for saved in closed.sessions {
            var current = main.sessions.first { $0.remoteReference == saved.remoteReference }
                ?? .init(hostID: saved.hostID, sessionID: saved.sessionID, sessionName: saved.sessionName, layout: .init(), windowIDs: [:], ownedWindowIDs: [], focusedRight: false, remoteReference: saved.remoteReference)
            preservePending(from: saved, sceneID: closed.id, into: &current, selection: false, nativeSelection: false)
            main.sessions.removeAll { $0.remoteReference == saved.remoteReference }
            main.sessions.append(current)
        }
        scenes.removeAll { $0.id == mainID }
        scenes.append(main)
    }

    func update(_ state: SessionStateMessage, windows: DetachedTerminalWindows) {
        _ = capture(windows: windows)
        let catalog = ViewerWorkspaceCatalog(state: state)
        if let catalog, catalogs[state.pairId]?.scope == catalog.scope {
            for store in [windows.mainTabs] + windows.workspaces.values.map(\.tabs) {
                for (key, reference) in store.remoteRecoveryReferences where key.hostId == state.pairId {
                    if let route = catalog.resolve(reference), route.sessionName != key.sessionName {
                        windows.renameSession(hostID: state.pairId, from: key.sessionName, to: route.sessionName, windowIDs: [:])
                    } else if catalog.reference(sessionName: key.sessionName) != reference {
                        store.remote[key]?.cancelActiveBrowserDownloads()
                        store.remote.removeValue(forKey: key)
                    }
                }
            }
        }
        if let previous = catalogs[state.pairId], previous.scope != catalog?.scope {
            for scene in scenes {
                guard let store = scene.isMain ? windows.mainTabs : windows.workspaces[scene.id]?.tabs else { continue }
                // capture() has already retained the user's latest choice.
                if scene.selectedHostID == state.pairId {
                    selectionRevisions[scene.id] = store.userSelectionRevision
                }
                for saved in scene.sessions where saved.hostID == state.pairId {
                    guard let reference = saved.remoteReference else { continue }
                    tabSelectionRevisions[scene.id, default: [:]][reference] = store.tabSelectionRevision(hostID: state.pairId, session: saved.sessionName)
                }
            }
            for store in [windows.mainTabs] + windows.workspaces.values.map(\.tabs) {
                for key in store.remote.keys.filter({ $0.hostId == state.pairId }) {
                    store.remote[key]?.cancelActiveBrowserDownloads()
                    store.remote.removeValue(forKey: key)
                }
            }
            for workspace in windows.workspaces.values where workspace.anchor.hostID == state.pairId {
                workspace.members = []
            }
            for id in applied.keys {
                applied[id] = applied[id]?.filter { $0.pairID != state.pairId }
            }
            for scene in scenes {
                let records = scene.sessions.filter { $0.hostID == state.pairId }
                appliedWindows[scene.id]?.subtract(records.flatMap(\.ownedWindowIDs))
                appliedFiles[scene.id]?.subtract(records.flatMap { $0.layout.fileTabs.map(\.id) })
            }
        }
        states[state.pairId] = state
        catalogs[state.pairId] = catalog
        apply(hostID: state.pairId, windows: windows)
    }

    func suspend(_ hostID: String, windows: DetachedTerminalWindows) {
        _ = capture(windows: windows)
        // Keep the last catalog for offline presentation edits (including
        // returning a detached window to main). Only update() applies Host state.
    }

    func retainHosts(_ hostIDs: Set<String>, windows: DetachedTerminalWindows) {
        for index in scenes.indices {
            scenes[index].sessions.removeAll { $0.hostID.map { !hostIDs.contains($0) } ?? true }
            if let selected = scenes[index].selectedHostID, !hostIDs.contains(selected) {
                scenes[index].selectedHostID = nil
                scenes[index].selectedSessionID = nil
            }
        }
        scenes.removeAll { !$0.isMain && $0.sessions.isEmpty }
        catalogs = catalogs.filter { hostIDs.contains($0.key) }
        states = states.filter { hostIDs.contains($0.key) }
        for store in [windows.mainTabs] + windows.workspaces.values.map(\.tabs) {
            store.remoteRecoveryReferences = store.remoteRecoveryReferences.filter { hostIDs.contains($0.key.hostId) }
            store.restoredRemoteSessions = store.restoredRemoteSessions.filter { hostIDs.contains($0.hostId) }
        }
        for id in applied.keys {
            applied[id] = applied[id]?.filter { hostIDs.contains($0.pairID) }
        }
    }

    private func apply(hostID: String, windows: DetachedTerminalWindows) {
        guard let catalog = catalogs[hostID], let state = states[hostID] else { return }
        for scene in scenes.sorted(by: { !$0.isMain && $1.isMain }) {
            for saved in scene.sessions where saved.hostID == hostID {
                guard let reference = saved.remoteReference, let route = catalog.resolve(reference) else { continue }
                let runtime: (Int) -> String? = { index in
                    guard let id = saved.windowIDs[index] else { return nil }
                    var window = reference
                    window.windowID = id
                    return catalog.resolve(window)?.windowID
                }
                let members = saved.ownedWindowIDs.compactMap { id -> DetachedTerminalTarget? in
                    var window = reference
                    window.windowID = id
                    return catalog.resolve(window).flatMap { DetachedTerminalTarget(hostID: hostID, windowID: $0.windowID) }
                }
                let store: WorkbenchTabStore
                if scene.isMain {
                    store = windows.mainTabs
                } else {
                    let fallback = DetachedTerminalTarget(hostID: hostID, windowID: route.windowID)
                    guard let workspace = windows.restoreWorkspace(id: scene.id, members: members, session: route.sessionName, frame: scene.frame, fallbackAnchor: fallback) else { continue }
                    if !(applied[scene.id] ?? []).contains(reference) {
                        workspace.members = members
                        workspace.sessionName = route.sessionName
                        if let anchor = members.first ?? fallback {
                            workspace.anchor = anchor
                        }
                    } else {
                        for member in members where !workspace.members.contains(member) && !windows.targets.contains(member) {
                            workspace.members.append(member)
                        }
                    }
                    store = workspace.tabs
                }
                let key = RemoteSessionTabsKey(hostId: hostID, sessionName: route.sessionName)
                rememberSelectionRevisions(scene, store: store)
                let restoreTabSelection = canRestoreTabSelection(reference, session: route.sessionName, sceneID: scene.id, store: store)
                let firstApplication = !(applied[scene.id] ?? []).contains(reference)
                store.remoteRecoveryReferences[key] = reference
                let tabs = store.tabs(hostID: hostID, session: route.sessionName)
                store.restoredRemoteSessions.insert(key)
                let descriptors = (state.fileTabs ?? []).filter { $0.sessionName == route.sessionName }
                var layout = saved.layout
                layout.fileTabs.removeAll { file in file.browser?.hostOwned == true && !descriptors.contains { $0.id == file.id } }
                let mappedOrder = layout.tabOrder.compactMap {
                    LayoutSnapshotMapper.runtimePayload(for: $0, windowIdForIndex: runtime, restoredFileIds: Set(layout.fileTabs.map(\.id)), restoredBrowserIds: Set(layout.browserTabs.map(\.id)))
                }
                if firstApplication, restoreTabSelection {
                    // Shared terminal placement belongs to the Host. Detached
                    // placement is private to this Viewer native window.
                    let chosen = scene.isMain ? LayoutSnapshotMapper.viewerPrivateLayout(from: layout) : layout
                    LayoutSnapshotMapper.apply(chosen, to: tabs, fileBrowser: nil, includeHostFiles: true, windowIdForIndex: runtime, makeBrowserState: { BrowserTabState(initialURL: $0.url) })
                    // Tab order relative to private Files is Viewer-owned;
                    // the Host still supplies terminal split placement below.
                    tabs.tabOrder = mappedOrder.filter { $0.windowId != nil || tabs.tabOrder.contains($0) }
                    tabs.restoreLinkedTabOrder(layout.linkedTabOrder)
                    tabs.isRightPaneFocused = saved.focusedRight
                    tabs.scrollOffsets = saved.fileScrollOffsets
                } else {
                    for ref in layout.tabOrder {
                        guard
                            case let .window(index) = ref, let id = saved.windowIDs[index],
                            !(appliedWindows[scene.id] ?? []).contains(id), let windowID = runtime(index) else { continue }
                        let payload = TabDragPayload.window(windowID)
                        Self.insertMissing(payload, order: mappedOrder, into: &tabs.tabOrder)
                        if !scene.isMain {
                            if layout.rightSide.contains(ref) {
                                tabs.rightSide.insert(payload)
                            }
                            if restoreTabSelection, layout.selectedRight == ref {
                                tabs.selectedRight = payload
                                if saved.focusedRight {
                                    tabs.isRightPaneFocused = true
                                }
                            }
                        }
                    }
                    for file in layout.fileTabs where !(appliedFiles[scene.id] ?? []).contains(file.id) {
                        guard !tabs.openFileTabs.contains(where: { $0.id == file.id }) else { continue }
                        tabs.openFileTabs.append(.init(id: file.id, path: file.path, directoryPath: file.directoryPath, isDirectory: file.browser != nil))
                        if let browser = file.browser {
                            tabs.directoryTabs[file.id] = FileBrowserTab(snapshot: browser)
                        }
                        let ref = SavedTabRef.file(id: file.id)
                        let payload = TabDragPayload.file(file.id)
                        Self.insertMissing(payload, order: mappedOrder, into: &tabs.tabOrder)
                        if saved.layout.rightSide.contains(ref) {
                            tabs.rightSide.insert(payload)
                        }
                        if restoreTabSelection, saved.layout.selectedLeft == ref {
                            tabs.selectedFileTabId = file.id
                            tabs.selectedBrowserTabId = nil
                            if !saved.focusedRight {
                                tabs.isRightPaneFocused = false
                            }
                        }
                        if restoreTabSelection, saved.layout.selectedRight == ref {
                            tabs.selectedRight = payload
                            if saved.focusedRight {
                                tabs.isRightPaneFocused = true
                            }
                        }
                    }
                    if firstApplication {
                        for saved in layout.browserTabs where !tabs.openBrowserTabs.contains(where: { $0.id == saved.id }) {
                            let tab = BrowserTab(id: saved.id, url: saved.url, displayTitle: saved.displayTitle, parentTabId: saved.parentId)
                            tabs.openBrowserTabs.append(tab)
                            tabs.browserStates[tab.id] = BrowserTabState(initialURL: tab.url)
                            let payload = TabDragPayload.browser(tab.id)
                            Self.insertMissing(payload, order: mappedOrder, into: &tabs.tabOrder)
                            if layout.rightSide.contains(.browser(id: tab.id)) {
                                tabs.rightSide.insert(payload)
                            }
                        }
                    }
                }
                applied[scene.id, default: []].insert(reference)
                var selected = reference
                selected.windowID = saved.selectedWindowID
                let resolvedWindowID = catalog.resolve(selected)?.windowID
                let selectedWindowArrived = saved.selectedWindowID.map {
                    !(appliedWindows[scene.id] ?? []).contains($0) && resolvedWindowID != nil
                } ?? false
                if
                    firstApplication || selectedWindowArrived, selectionRevisions[scene.id] == store.userSelectionRevision,
                    scene.selectedHostID == hostID, scene.selectedSessionID == reference.sessionID {
                    var windowID = resolvedWindowID
                    if scene.isMain, let shared = state.sharedTerminalLayouts?[route.sessionName], members.contains(where: { $0.windowID == shared.leftWindowId }) {
                        windowID = shared.leftWindowId
                    }
                    store.restoredSelection = .init(hostID: hostID, sessionName: route.sessionName, windowID: windowID)
                    if restoreTabSelection, !saved.focusedRight {
                        tabs.isRightPaneFocused = false
                    }
                    store.restorationRevision += 1
                } else if firstApplication {
                    store.restorationRevision += 1
                }
                for file in descriptors {
                    tabs.directoryTabs[file.id]?.updateHostTab(file)
                }
                for (id, source) in saved.fileSources ?? [:] {
                    let pane = catalog.resolve(source)?.paneID
                    tabs.directoryTabs[id]?.restoreSourcePane(pane)
                    if pane == nil {
                        store.unavailableRemoteFileIDs.insert(id)
                    } else {
                        store.unavailableRemoteFileIDs.remove(id)
                    }
                }
                if scene.isMain, let shared = state.sharedTerminalLayouts?[route.sessionName] {
                    let ids = Set(catalog.routes.values.filter { $0.sessionName == route.sessionName && !windows.contains(hostID: hostID, windowID: $0.windowID) }.map(\.windowID))
                    if ids.contains(shared.leftWindowId) {
                        tabs.applySharedTerminalLayout(shared, liveWindowIds: ids)
                    }
                }
                appliedFiles[scene.id, default: []].formUnion(layout.fileTabs.map(\.id))
                appliedWindows[scene.id, default: []].formUnion(members.compactMap { catalog.reference(sessionName: route.sessionName, windowID: $0.windowID)?.windowID })
                materializedScenes.insert(scene.id)
            }
        }
    }
}
