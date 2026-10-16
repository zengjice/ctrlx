import AppKit
import CtrlxCommon
import CtrlxNetworking

@MainActor
enum WorkspaceRecoveryPresentationMapper {
    static func captureLocal(windows: DetachedTerminalWindows, sessions: [WorkspaceRecoverySession], mainID: UUID) -> [WorkspaceRecoveryScene] {
        let main = scene(
            id: mainID,
            main: true,
            frame: windows.mainFrame,
            store: windows.mainTabs,
            sessions: sessions,
            owns: { !windows.contains(hostID: nil, windowID: $0) }
        )
        let detached = windows.workspaces.values.filter { $0.anchor.hostID == nil }.sorted { $0.id.uuidString < $1.id.uuidString }.map { workspace in
            scene(
                id: workspace.id,
                main: false,
                frame: windows.frame(for: workspace.id),
                store: workspace.tabs,
                sessions: sessions.filter { $0.name == workspace.sessionName },
                owns: { runtime in workspace.members.contains { $0.windowID == runtime } }
            )
        }
        return [main] + detached
    }

    private static func scene(
        id: UUID, main: Bool, frame: CGRect?, store: WorkbenchTabStore,
        sessions: [WorkspaceRecoverySession], owns: (String) -> Bool
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
            return WorkspaceRecoveryPresentation(
                hostID: nil, sessionID: session.id, sessionName: session.name, layout: layout,
                windowIDs: Dictionary(uniqueKeysWithValues: session.windows.map { ($0.index, $0.id) }),
                ownedWindowIDs: owned.map(\.id), focusedRight: tabs.isRightPaneFocused,
                fileScrollOffsets: tabs.scrollOffsets, gitDirectory: store.recoveryGitPaths[session.name],
                gitState: store.recoveryGitStates[session.name], selectedWindowID: selectedWindow?.id
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
            selectedHostID: selection?.hostID
        )
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

    static func restoreLocal(_ scenes: [WorkspaceRecoveryScene], live: WorkspaceTmuxState, windows: DetachedTerminalWindows, files: [HostFileTab]) {
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
                for (id, member) in presentation.ownedWindowIDs.compactMap({ id -> (UUID, DetachedTerminalTarget)? in
                    guard
                        let window = session.windows.first(where: { $0.id == id }),
                        let target = DetachedTerminalTarget(hostID: nil, windowID: window.runtimeID) else { return nil }
                    return (id, target)
                }) where !workspace.tabs.restoredRecoveryWindowIDs.contains(id) && !windows.targets.contains(member) {
                    workspace.members.append(member)
                }
            }
        }
        for saved in scenes {
            guard let store = saved.isMain ? windows.mainTabs : windows.workspaces[saved.id]?.tabs else { continue }
            for presentation in saved.sessions where presentation.hostID == nil {
                guard let session = live.sessions.first(where: { $0.id == presentation.sessionID }) else { continue }
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
                    for savedFile in availableLayout.fileTabs where !store.restoredRecoveryFileIDs.contains(savedFile.id) {
                        tabs.openFileTabs.append(.init(id: savedFile.id, path: savedFile.path, directoryPath: savedFile.directoryPath, isDirectory: savedFile.browser != nil))
                        if let browser = savedFile.browser {
                            tabs.directoryTabs[savedFile.id] = FileBrowserTab(snapshot: browser)
                        }
                        let payload = TabDragPayload.file(savedFile.id)
                        tabs.tabOrder.append(payload)
                        if presentation.layout.rightSide.contains(.file(id: savedFile.id)) {
                            tabs.rightSide.insert(payload)
                        }
                        if tabs.selectedRight == nil, presentation.layout.selectedRight == .file(id: savedFile.id) {
                            tabs.selectedRight = payload
                        }
                        tabs.scrollOffsets[savedFile.id] = presentation.fileScrollOffsets[savedFile.id]
                    }
                    // Retry adds only newly available terminals. Never replay old
                    // selection, ordering or private tabs over the user's edits.
                    for ref in presentation.layout.tabOrder {
                        guard
                            case let .window(index) = ref, let id = presentation.windowIDs[index],
                            !store.restoredRecoveryWindowIDs.contains(id), let runtime = windowForIndex(index) else { continue }
                        let payload = TabDragPayload.window(runtime)
                        if !tabs.tabOrder.contains(payload) {
                            tabs.tabOrder.append(payload)
                        }
                        if presentation.layout.rightSide.contains(ref) {
                            tabs.rightSide.insert(payload)
                        }
                        if tabs.selectedRight == nil, presentation.layout.selectedRight == ref {
                            tabs.selectedRight = payload
                        }
                    }
                }
                store.restoredRecoveryWindowIDs.formUnion(presentation.ownedWindowIDs.filter { id in session.windows.contains { $0.id == id } })
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
    static func preservingUnavailable(captured: [WorkspaceRecoveryScene], source: WorkspaceRecoverySnapshot, live: WorkspaceTmuxState) -> [WorkspaceRecoveryScene] {
        guard source.recovery != nil else { return captured }
        let liveSessions = Set(live.sessions.map(\.id))
        let retainedSessions = Set(source.sessions.map(\.id))
        let liveWindows = Set(live.sessions.flatMap(\.windows).map(\.id))
        let retainedWindows = Set(source.sessions.flatMap(\.windows).map(\.id))
        let missingWindows = retainedWindows.subtracting(liveWindows)
        let livePanes = Set(live.sessions.flatMap(\.windows).flatMap(\.panes).map(\.id))
        let missingFileIDs = Set(source.fileTabs.filter { !livePanes.contains($0.paneID) }.map(\.id))
        var result = captured
        for oldScene in source.scenes {
            var scene = oldScene
            scene.sessions.removeAll { $0.hostID == nil && !retainedSessions.contains($0.sessionID) }
            guard let sceneIndex = result.firstIndex(where: { $0.id == scene.id }) else {
                if scene.sessions.contains(where: { !liveSessions.contains($0.sessionID) || !$0.ownedWindowIDs.filter(missingWindows.contains).isEmpty }) {
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
                for file in saved.layout.fileTabs where missingFileIDs.contains(file.id) && !current.layout.fileTabs.contains(where: { $0.id == file.id }) {
                    current.layout.fileTabs.append(file)
                    let ref = SavedTabRef.file(id: file.id)
                    current.layout.tabOrder.append(ref)
                    if saved.layout.rightSide.contains(ref) {
                        current.layout.rightSide.append(ref)
                    }
                    current.fileScrollOffsets[file.id] = saved.fileScrollOffsets[file.id]
                }
                for id in saved.ownedWindowIDs where missingWindows.contains(id) {
                    guard let oldIndex = saved.windowIDs.first(where: { $0.value == id })?.key else { continue }
                    // A live window may have reused the old index. The recovery
                    // format has its own index map; assign an unused key locally.
                    let key = current.windowIDs[oldIndex] == nil ? oldIndex : (current.windowIDs.keys.max() ?? 0) + 1
                    current.windowIDs[key] = id
                    current.ownedWindowIDs.append(id)
                    let ref = SavedTabRef.window(index: key)
                    current.layout.tabOrder.append(ref)
                    if saved.layout.rightSide.contains(.window(index: oldIndex)) {
                        current.layout.rightSide.append(ref)
                    }
                }
                result[sceneIndex].sessions[index] = current
            }
        }
        return result
    }
}
