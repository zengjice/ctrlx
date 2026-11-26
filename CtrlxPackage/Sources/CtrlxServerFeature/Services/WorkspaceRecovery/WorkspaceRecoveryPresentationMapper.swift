import AppKit
import CtrlxCommon
import CtrlxNetworking

@MainActor
enum WorkspaceRecoveryPresentationMapper {
    /// Presentation metadata only; resource sessions are never sent to tmux reconstruction.
    static func includingResources(_ resources: [ResourceSession], in sessions: [WorkspaceRecoverySession]) -> [WorkspaceRecoverySession] {
        sessions + resources.filter { resource in !sessions.contains { $0.id == resource.id } }.map {
            .init(id: $0.id, runtimeID: "", name: $0.name, windows: [])
        }
    }

    static func captureLocal(
        windows: DetachedTerminalWindows, sessions: [WorkspaceRecoverySession], mainID: UUID,
        sharedLayouts: [String: SharedTerminalLayout] = [:], modelPreferences: AgentModelPreferences? = nil, serverID: String? = nil
    ) -> [WorkspaceRecoveryScene] {
        let main = scene(
            id: mainID,
            main: true,
            frame: windows.mainFrame,
            store: windows.mainTabs,
            sessions: sessions,
            sharedLayouts: sharedLayouts,
            owns: { !windows.contains(hostID: nil, windowID: $0) }
        )
        let detached = windows.workspaces.values.filter { $0.hostID == nil }.sorted { $0.id.uuidString < $1.id.uuidString }.map { workspace in
            scene(
                id: workspace.id,
                main: false,
                frame: windows.frame(for: workspace.id),
                store: workspace.tabs,
                sessions: sessions.filter { $0.name == workspace.sessionName },
                isSessionWindow: workspace.isSessionWindow,
                owns: { runtime in workspace.members.contains { $0.windowID == runtime } }
            )
        }
        var result = [main] + detached
        for scene in result.indices {
            for session in result[scene].sessions.indices {
                result[scene].sessions[session].modelShortcuts = modelPreferences?.capture(
                    hostID: "local", serverID: serverID, windowIDs: result[scene].sessions[session].ownedWindowIDs
                )
            }
        }
        return result
    }

    private static func scene(
        id: UUID, main: Bool, frame: CGRect?, store: WorkbenchTabStore,
        sessions: [WorkspaceRecoverySession], isSessionWindow: Bool = false, sharedLayouts: [String: SharedTerminalLayout] = [:], owns: (String) -> Bool
    ) -> WorkspaceRecoveryScene {
        let presentations = sessions.map { session in
            let tabs = store.local[session.name] ?? SessionFileTabsState()
            var layout = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, includeHostFiles: true, includeUnavailableFiles: true) { runtime in
                session.windows.first { $0.runtimeID == runtime }?.index
            }
            let owned = session.windows.filter { owns($0.runtimeID) }
            let ownedIndices = Set(owned.map(\.index))
            func belongs(_ ref: SavedTabRef) -> Bool {
                if case let .window(index) = ref {
                    return ownedIndices.contains(index)
                }
                return true
            }
            layout.tabOrder = layout.tabOrder.filter(belongs)
            for window in owned where !layout.tabOrder.contains(.window(index: window.index)) {
                layout.tabOrder.append(.window(index: window.index))
            }
            layout.rightSide = layout.tabOrder.filter { layout.rightSide.contains($0) }
            if tabs.isGitSelected {
                layout.selectedLeft = .git
            }
            if layout.selectedLeft == nil {
                let selected = (store.restoredSelection ?? store.recoverySelection).flatMap { selection in
                    selection.hostID == nil && selection.sessionName == session.name
                        ? owned.first { $0.runtimeID == selection.windowID } : nil
                } ?? owned.first { $0.id == session.selectedWindowID } ?? owned.first
                layout.selectedLeft = selected.map { .window(index: $0.index) }
            }
            layout.fileTree = store.recoveryFileTrees[session.name]
            let selection = store.restoredSelection ?? store.recoverySelection
            let selectedWindow = owned.first { window in
                selection?.hostID == nil && selection?.sessionName == session.name && selection?.windowID == window.runtimeID
            }
            let folder = recoveryFolder(in: session)
            var privateTabFolders: [UUID: Set<String>] = [:]
            for file in layout.fileTabs where file.browser?.hostOwned != true {
                privateTabFolders[file.id] = tabs.tabFolders[.file(file.id)] ?? folder.map { [$0] }
            }
            for browser in layout.browserTabs {
                privateTabFolders[browser.id] = tabs.tabFolders[.browser(browser.id)] ?? folder.map { [$0] }
            }
            return WorkspaceRecoveryPresentation(
                hostID: nil, sessionID: session.id, sessionName: session.name, layout: layout,
                windowIDs: Dictionary(uniqueKeysWithValues: session.windows.map { ($0.index, $0.id) }),
                ownedWindowIDs: owned.map(\.id), focusedRight: tabs.isRightPaneFocused,
                fileScrollOffsets: tabs.scrollOffsets, gitDirectory: store.recoveryGitPaths[session.name],
                gitState: store.recoveryGitStates[session.name], selectedWindowID: selectedWindow?.id,
                privateTabFolders: privateTabFolders.isEmpty ? nil : privateTabFolders,
                sharedTerminalLayout: sharedLayouts[session.name].flatMap { captureSharedTerminalLayout($0, windows: session.windows) }
            )
        }
        let selection = store.restoredSelection ?? store.recoverySelection
        let selected = selection?.hostID == nil ? sessions.first { $0.name == selection?.sessionName }?.id : nil
        return WorkspaceRecoveryScene(
            id: id,
            isMain: main,
            frame: frame,
            sessions: presentations,
            selectedSessionID: selected,
            selectedHostID: selection?.hostID,
            isSessionWindow: isSessionWindow ? true : nil
        )
    }

    private static func recoveryFolder(in session: WorkspaceRecoverySession) -> String? {
        let window = session.windows.first { $0.id == session.selectedWindowID } ?? session.windows.first
        guard let window, let pane = window.panes.first(where: { $0.id == window.selectedPaneID }) ?? window.panes.first else { return nil }
        return LayoutFolderKey.canonicalize(pane.agent?.projectPath ?? pane.directory)
    }

    private static func captureSharedTerminalLayout(
        _ shared: SharedTerminalLayout, windows: [WorkspaceRecoveryWindow]
    ) -> WorkspaceRecoveryTerminalLayout? {
        let ids = Dictionary(uniqueKeysWithValues: windows.map { ($0.runtimeID, $0.id) })
        guard let left = ids[shared.leftWindowId] else { return nil }
        return .init(
            leftWindowID: left, rightWindowIDs: shared.rightWindowIds.compactMap { ids[$0] },
            selectedRightWindowID: shared.selectedRightWindowId.flatMap { ids[$0] }, splitRatio: shared.splitRatio
        )
    }

    static func sharedTerminalRequest(
        from saved: WorkspaceRecoveryTerminalLayout, sessionName: String, windows: [WorkspaceRecoveryWindow]
    ) -> SetSharedTerminalLayout? {
        let routes = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.runtimeID) })
        var right = saved.rightWindowIDs.compactMap { routes[$0] }
        guard
            let left = routes[saved.leftWindowID] ?? windows.first(where: { !right.contains($0.runtimeID) })?.runtimeID ?? windows.first?.runtimeID
        else { return nil }
        right.removeAll { $0 == left }
        let selected = saved.selectedRightWindowID.flatMap { routes[$0] }.flatMap { right.contains($0) ? $0 : nil } ?? right.first
        return .init(sessionName: sessionName, leftWindowId: left, rightWindowIds: right, selectedRightWindowId: selected, splitRatio: saved.splitRatio)
    }

    static func restoredSharedTerminalRequest(
        from presentation: WorkspaceRecoveryPresentation?, session: WorkspaceRecoverySession, tabs: SessionFileTabsState,
        current: SharedTerminalLayout?, previouslyPresented: Set<UUID>, preferredLeft: String?
    ) -> SetSharedTerminalLayout? {
        if var saved = presentation?.sharedTerminalLayout {
            if let current {
                let actual = SetSharedTerminalLayout(
                    sessionName: session.name, leftWindowId: current.leftWindowId, rightWindowIds: current.rightWindowIds,
                    selectedRightWindowId: current.selectedRightWindowId, splitRatio: current.splitRatio
                )
                guard
                    let merged = mergingSharedTerminalSelections(
                        saved, with: actual, windows: session.windows, previouslyPresented: previouslyPresented
                    )
                else { return nil }
                saved = merged
            }
            return sharedTerminalRequest(from: saved, sessionName: session.name, windows: session.windows)
        }

        var layout = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, includeHostFiles: true) { runtime in
            session.windows.first { $0.runtimeID == runtime }?.index
        }
        if
            layout.selectedRightTerminalIndex == nil, tabs.tabSelectionRevision(onRight: true) == 0,
            let index = presentation?.layout.selectedRightTerminalIndex, let id = presentation?.windowIDs[index] {
            layout.selectedRightTerminalIndex = session.windows.first { $0.id == id }?.index
        }
        let resolved = session.windows.map {
            LayoutSnapshotMapper.TerminalWindow(index: $0.index, stableId: $0.runtimeID, isActive: session.selectedWindowID == $0.id)
        }
        return LayoutSnapshotMapper.sharedTerminalLayoutRequest(from: layout, sessionName: session.name, windows: resolved, preferredLeftWindowId: preferredLeft)
    }

    private static func mergingSharedTerminalSelections(
        _ saved: WorkspaceRecoveryTerminalLayout, with actual: SetSharedTerminalLayout, windows: [WorkspaceRecoveryWindow],
        previouslyPresented: Set<UUID>? = nil
    ) -> WorkspaceRecoveryTerminalLayout? {
        let presented = windows.filter { previouslyPresented?.contains($0.id) ?? true }
        guard
            let projected = sharedTerminalRequest(from: saved, sessionName: actual.sessionName, windows: presented)
        else { return nil }
        var merged = saved
        if actual.leftWindowId != projected.leftWindowId {
            guard let left = windows.first(where: { $0.runtimeID == actual.leftWindowId }) else { return nil }
            merged.leftWindowID = left.id
        }
        if actual.selectedRightWindowId != projected.selectedRightWindowId {
            merged.selectedRightWindowID = windows.first { $0.runtimeID == actual.selectedRightWindowId }?.id
        }
        let actualRight = actual.rightWindowIds.compactMap { runtime in windows.first { $0.runtimeID == runtime }?.id }
        let projectedLeftID = presented.first { $0.runtimeID == projected.leftWindowId }?.id
        let deferredRight = saved.deferredRightWindowID ?? projectedLeftID
        if actual.rightWindowIds != projected.rightWindowIds {
            let presentedIDs = Set(presented.map(\.id))
            merged.rightWindowIDs = actualRight
            var next = merged.rightWindowIDs.endIndex
            for id in saved.rightWindowIDs.reversed() {
                if let index = merged.rightWindowIDs.firstIndex(of: id) {
                    next = index
                } else if !presentedIDs.contains(id) || id == deferredRight, id != merged.leftWindowID {
                    merged.rightWindowIDs.insert(id, at: next)
                }
            }
        }
        merged.rightWindowIDs.removeAll { $0 == merged.leftWindowID }
        merged.deferredRightWindowID = deferredRight.flatMap { merged.rightWindowIDs.contains($0) && !actualRight.contains($0) ? $0 : nil }
        merged.splitRatio = actual.splitRatio
        return merged
    }

    static func captureFiles(_ files: [HostFileTab], sessions: [WorkspaceRecoverySession]) -> [WorkspaceRecoveryFileTab] {
        files.compactMap { file in
            guard
                let session = sessions.first(where: { $0.name == file.sessionName }),
                let window = session.windows.first(where: { $0.runtimeID == file.windowID }),
                let pane = window.panes.first(where: { $0.runtimeID == file.sourcePaneID }) else { return nil }
            return WorkspaceRecoveryFileTab(
                id: file.id,
                sessionID: session.id,
                windowID: window.id,
                paneID: pane.id,
                group: file.group,
                isPrimary: file.isPrimary,
                initialDirectory: file.initialDirectory
            )
        }
    }

    static func restoreLocal(
        _ scenes: [WorkspaceRecoveryScene], live: WorkspaceTmuxState, savedSessions: [WorkspaceRecoverySession] = [],
        windows: DetachedTerminalWindows, files: [HostFileTab], modelPreferences: AgentModelPreferences? = nil
    ) {
        // Reserve detached ownership first; the main scene must not temporarily
        // render a second copy of terminals that belong to another native window.
        for saved in scenes where !saved.isMain {
            guard
                let presentation = saved.sessions.first(where: { $0.hostID == nil }),
                let session = live.sessions.first(where: { $0.id == presentation.sessionID }) else { continue }
            let members = presentation.ownedWindowIDs.compactMap { id in
                session.windows.first { $0.id == id }.flatMap { DetachedTerminalTarget(hostID: nil, windowID: $0.runtimeID) }
            }
            let fallback = session.windows.first.flatMap { DetachedTerminalTarget(hostID: nil, windowID: $0.runtimeID) }
            if let workspace = windows.restoreWorkspace(id: saved.id, members: members, session: session.name, frame: saved.frame, fallbackAnchor: fallback) {
                workspace.isSessionWindow = saved.isSessionWindow == true
                for (id, member) in presentation.ownedWindowIDs.compactMap({ id -> (UUID, DetachedTerminalTarget)? in
                    guard
                        let window = session.windows.first(where: { $0.id == id }),
                        let target = DetachedTerminalTarget(hostID: nil, windowID: window.runtimeID) else { return nil }
                    return (id, target)
                }) where workspace.tabs.restoredRecoveryWindowIDs[session.id]?.contains(id) != true && !windows.targets.contains(member) {
                    workspace.members.append(member)
                }
            }
        }
        for saved in scenes {
            guard let store = saved.isMain ? windows.mainTabs : windows.workspaces[saved.id]?.tabs else { continue }
            for presentation in saved.sessions where presentation.hostID == nil {
                guard let session = live.sessions.first(where: { $0.id == presentation.sessionID }) else { continue }
                modelPreferences?.restore(presentation.modelShortcuts, hostID: "local", serverID: live.serverID, windowIDs: session.windows.map(\.id))
                let tabs = store.tabs(hostID: nil, session: session.name)
                var availableLayout = presentation.layout
                availableLayout.fileTabs.removeAll { saved in saved.browser?.hostOwned == true && !files.contains { $0.id == saved.id } }
                let windowForIndex: (Int) -> String? = { index in
                    guard let id = presentation.windowIDs[index] else { return nil }
                    return session.windows.first { $0.id == id }?.runtimeID
                }
                if !store.restoredLocalSessions.contains(session.name) {
                    LayoutSnapshotMapper.apply(
                        availableLayout,
                        to: tabs,
                        fileBrowser: nil,
                        includeHostFiles: true,
                        windowIdForIndex: windowForIndex,
                        makeBrowserState: { BrowserTabState(initialURL: $0.url) }
                    )
                    let folder = savedSessions.first { $0.id == presentation.sessionID }.flatMap { recoveryFolder(in: $0) }
                    let fallbackFolders: Set<String> = folder.map { [$0] } ?? []
                    for file in tabs.openFileTabs where tabs.directoryTabs[file.id]?.hostTab == nil {
                        tabs.tabFolders[.file(file.id)] = presentation.privateTabFolders?[file.id] ?? fallbackFolders
                    }
                    for browser in tabs.openBrowserTabs where !browser.isTransient {
                        tabs.tabFolders[.browser(browser.id)] = presentation.privateTabFolders?[browser.id] ?? fallbackFolders
                    }
                    if saved.isMain {
                        tabs.restoreLocalOnlySplit(windowIDs: session.windows.map(\.runtimeID), savedLocalRightTerminalID: tabs.locallySplitTerminalID)
                    }
                    tabs.isGitSelected = presentation.layout.selectedLeft == .git
                    tabs.isRightPaneFocused = presentation.focusedRight
                    store.restoredLocalSessions.insert(session.name)
                    store.recoveryFileTrees[session.name] = presentation.layout.fileTree
                    store.recoveryGitPaths[session.name] = presentation.gitState?.directory ?? presentation.gitDirectory
                    store.recoveryGitStates[session.name] = presentation.gitState
                    if presentation.gitState != nil {
                        store.pendingGitRecoverySessions.insert(session.name)
                    }
                    tabs.scrollOffsets = presentation.fileScrollOffsets
                    if saved.selectedHostID == nil, saved.selectedSessionID == session.id {
                        let selected: String? = if let id = presentation.selectedWindowID {
                            session.windows.first { $0.id == id }?.runtimeID
                        } else if case let .window(index) = presentation.layout.selectedLeft {
                            windowForIndex(index)
                        } else {
                            nil
                        }
                        store.restoredSelection = .init(hostID: nil, sessionName: session.name, windowID: selected)
                    }
                } else {
                    var restoredLeftFile = false
                    for savedFile in availableLayout.fileTabs where !store.restoredRecoveryFileIDs.contains(savedFile.id) {
                        tabs.openFileTabs.append(.init(id: savedFile.id, path: savedFile.path, directoryPath: savedFile.directoryPath, isDirectory: savedFile.browser != nil))
                        if let browser = savedFile.browser {
                            tabs.directoryTabs[savedFile.id] = FileBrowserTab(snapshot: browser)
                        }
                        let payload = TabDragPayload.file(savedFile.id)
                        tabs.tabOrder.append(payload)
                        if presentation.layout.rightSide.contains(.file(id: savedFile.id)) {
                            tabs.rightSide.insert(payload)
                        } else if presentation.layout.selectedLeft == .file(id: savedFile.id), tabs.tabSelectionRevision(onRight: false) == 0 {
                            tabs.selectedFileTabId = savedFile.id
                            tabs.selectedBrowserTabId = nil
                            restoredLeftFile = true
                        }
                        if
                            presentation.layout.selectedRight == .file(id: savedFile.id),
                            tabs.rightSide.contains(payload),
                            tabs.tabSelectionRevision(onRight: true) == 0 {
                            tabs.selectedRight = payload
                        }
                        tabs.scrollOffsets[savedFile.id] = presentation.fileScrollOffsets[savedFile.id]
                    }
                    // Retry adds only newly available terminals. Never replay old
                    // selection, ordering or private tabs over the user's edits.
                    var addedRightTerminal = false
                    for ref in presentation.layout.tabOrder {
                        guard
                            case let .window(index) = ref, let id = presentation.windowIDs[index],
                            store.restoredRecoveryWindowIDs[session.id]?.contains(id) != true, let runtime = windowForIndex(index) else { continue }
                        let payload = TabDragPayload.window(runtime)
                        if !tabs.tabOrder.contains(payload) {
                            tabs.tabOrder.append(payload)
                        }
                        if presentation.layout.rightSide.contains(ref), tabs.rightSide.insert(payload).inserted {
                            addedRightTerminal = true
                        }
                        if tabs.selectedRight == nil, presentation.layout.selectedRight == ref {
                            tabs.selectedRight = payload
                        }
                    }
                    if saved.isMain, restoredLeftFile || addedRightTerminal {
                        let windowIDs = session.windows.map(\.runtimeID)
                        if restoredLeftFile, tabs.tabSelectionRevision(onRight: true) == 0, !windowIDs.isEmpty {
                            let savedRightWindows = Set(presentation.layout.rightSide.compactMap { ref -> String? in
                                guard case let .window(index) = ref else { return nil }
                                return windowForIndex(index)
                            })
                            if windowIDs.allSatisfy(savedRightWindows.contains) {
                                tabs.rightSide.formUnion(windowIDs.map(TabDragPayload.window))
                                if tabs.selectedRight == nil, case let .window(index) = presentation.layout.selectedRight {
                                    tabs.selectedRight = windowForIndex(index).map(TabDragPayload.window)
                                }
                                addedRightTerminal = true
                            }
                        }
                        if addedRightTerminal {
                            tabs.restoreLocalOnlySplit(
                                windowIDs: windowIDs, savedLocalRightTerminalID: presentation.layout.localRightTerminalIndex.flatMap(windowForIndex)
                            )
                        }
                    }
                }
                store.restoredRecoveryWindowIDs[session.id, default: []].formUnion(
                    presentation.ownedWindowIDs.filter { id in session.windows.contains { $0.id == id } }
                )
                store.restoredRecoveryFileIDs.formUnion(availableLayout.fileTabs.map(\.id))
                for file in files where file.sessionName == session.name {
                    tabs.directoryTabs[file.id]?.updateHostTab(file)
                }
            }
            if saved.isMain {
                windows.mainSceneID = saved.id
            }
            if saved.isMain, store.restorationRevision == 0, let frame = saved.frame {
                windows.restoreMainFrame(frame)
            }
            store.restorationRevision += 1
        }
    }
}

extension WorkspaceRecoveryPresentationMapper {
    /// Keep slots whose tmux objects have not recovered; edits to available slots
    /// come from the live workbench, including explicit tab closure and movement.
    static func preservingUnavailable(
        captured: [WorkspaceRecoveryScene], source: WorkspaceRecoverySnapshot, live: WorkspaceTmuxState,
        windows: DetachedTerminalWindows
    ) -> [WorkspaceRecoveryScene] {
        guard source.recovery != nil else { return captured }
        let liveSessions = Set(live.sessions.map(\.id))
        let retainedSessions = Set(source.sessions.map(\.id))
        let liveWindows = Dictionary(uniqueKeysWithValues: live.sessions.map { ($0.id, Set($0.windows.map(\.id))) })
        let missingWindows = Dictionary(uniqueKeysWithValues: source.sessions.map { session in
            (session.id, Set(session.windows.map(\.id)).subtracting(liveWindows[session.id] ?? []))
        })
        let livePanes = Set(live.sessions.flatMap(\.windows).flatMap(\.panes).map(\.id))
        let missingFileIDs = Set(source.fileTabs.filter { !livePanes.contains($0.paneID) }.map(\.id))
        var result = captured
        for oldScene in source.scenes {
            var scene = oldScene
            scene.sessions.removeAll { $0.hostID == nil && !retainedSessions.contains($0.sessionID) }
            guard let sceneIndex = result.firstIndex(where: { $0.id == scene.id }) else {
                if
                    scene.sessions.contains(where: { session in
                        !liveSessions.contains(session.sessionID)
                            || session.ownedWindowIDs.contains { missingWindows[session.sessionID]?.contains($0) == true }
                    }) {
                    result.append(scene)
                }
                continue
            }
            for saved in scene.sessions {
                guard let index = result[sceneIndex].sessions.firstIndex(where: { $0.sessionID == saved.sessionID && $0.hostID == saved.hostID }) else {
                    if !liveSessions.contains(saved.sessionID) {
                        result[sceneIndex].sessions.append(saved)
                    }
                    continue
                }
                var current = result[sceneIndex].sessions[index]
                if let previous = saved.sharedTerminalLayout, let session = live.sessions.first(where: { $0.id == current.sessionID }) {
                    let actual = current.sharedTerminalLayout.flatMap { sharedTerminalRequest(from: $0, sessionName: session.name, windows: session.windows) }
                    if let actual {
                        if let merged = mergingSharedTerminalSelections(previous, with: actual, windows: session.windows) {
                            current.sharedTerminalLayout = merged
                        }
                    } else {
                        current.sharedTerminalLayout = previous
                    }
                }
                for file in saved.layout.fileTabs where missingFileIDs.contains(file.id) && !current.layout.fileTabs.contains(where: { $0.id == file.id }) {
                    current.layout.fileTabs.append(file)
                    let ref = SavedTabRef.file(id: file.id)
                    current.layout.tabOrder.append(ref)
                    if saved.layout.rightSide.contains(ref) {
                        current.layout.rightSide.append(ref)
                    }
                    current.fileScrollOffsets[file.id] = saved.fileScrollOffsets[file.id]
                }
                for id in saved.ownedWindowIDs where missingWindows[saved.sessionID]?.contains(id) == true {
                    guard let oldIndex = saved.windowIDs.first(where: { $0.value == id })?.key else { continue }
                    // A live window may have reused the old index. The recovery
                    // format has its own index map; assign an unused key locally.
                    let key = current.windowIDs[oldIndex] == nil ? oldIndex : (current.windowIDs.keys.max() ?? 0) + 1
                    current.windowIDs[key] = id
                    current.ownedWindowIDs.append(id)
                    if let shortcuts = saved.modelShortcuts?[id] {
                        if current.modelShortcuts == nil {
                            current.modelShortcuts = [:]
                        }
                        current.modelShortcuts?[id] = shortcuts
                    }
                    let ref = SavedTabRef.window(index: key)
                    current.layout.tabOrder.append(ref)
                    if saved.layout.rightSide.contains(.window(index: oldIndex)) {
                        current.layout.rightSide.append(ref)
                        if current.layout.localRightTerminalIndex == nil, saved.layout.localRightTerminalIndex == oldIndex {
                            current.layout.localRightTerminalIndex = key
                        }
                    }
                }
                let store = scene.isMain ? windows.mainTabs : windows.workspaces[scene.id]?.tabs
                let tabs = store?.local[current.sessionName]
                let leftUnchanged = (tabs?.tabSelectionRevision(onRight: false) ?? 0) == 0
                let rightUnchanged = (tabs?.tabSelectionRevision(onRight: true) ?? 0) == 0
                if
                    case let .file(id) = saved.layout.selectedLeft, missingFileIDs.contains(id),
                    current.layout.selectedLeft?.isWindow != false, leftUnchanged {
                    current.layout.selectedLeft = saved.layout.selectedLeft
                    if rightUnchanged {
                        restoreSplitWaitingForFiles(saved: saved, current: &current)
                    }
                }
                if
                    case let .file(id) = saved.layout.selectedRight, missingFileIDs.contains(id),
                    current.layout.rightSide.contains(.file(id: id)), rightUnchanged {
                    current.layout.selectedRight = saved.layout.selectedRight
                }
                result[sceneIndex].sessions[index] = current
            }
        }
        return result
    }

    /// The live view temporarily puts a terminal on the left while Files is unavailable.
    private static func restoreSplitWaitingForFiles(saved: WorkspaceRecoveryPresentation, current: inout WorkspaceRecoveryPresentation) {
        let rightIDs = Set(saved.layout.rightSide.compactMap { ref -> UUID? in
            guard case let .window(index) = ref else { return nil }
            return saved.windowIDs[index]
        })
        guard !saved.ownedWindowIDs.isEmpty, saved.ownedWindowIDs.allSatisfy(rightIDs.contains) else { return }
        let rightRefs = current.layout.tabOrder.filter { ref in
            guard case let .window(index) = ref, let id = current.windowIDs[index] else { return false }
            return rightIDs.contains(id)
        }
        current.layout.rightSide += rightRefs.filter { !current.layout.rightSide.contains($0) }
        if
            current.layout.selectedRight == nil || current.layout.selectedRight?.isWindow == true,
            case let .window(oldIndex) = saved.layout.selectedRight, let id = saved.windowIDs[oldIndex],
            let index = current.windowIDs.first(where: { $0.value == id })?.key,
            rightRefs.contains(.window(index: index)) {
            current.layout.selectedRight = .window(index: index)
        }
        current.layout.splitRatio = saved.layout.splitRatio
    }
}
