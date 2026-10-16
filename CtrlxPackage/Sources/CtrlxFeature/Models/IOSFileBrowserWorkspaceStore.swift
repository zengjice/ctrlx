import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Observation

/// Client presentation cache. Only Host descriptors decide identity and lifetime.
@MainActor @Observable
final class IOSFileBrowserWorkspaceStore {
    private struct Key: Hashable {
        let hostID: String
        let sessionName: String
    }

    private var workspaces: [Key: IOSFileBrowserWorkspace] = [:]
    @ObservationIgnored private var clients: [String: ViewerRelayClient] = [:]
    private(set) var catalogs: [String: ViewerWorkspaceCatalog] = [:]
    private(set) var recovery = IOSWorkspaceRecoverySnapshot()
    private(set) var recoveryError: String?
    private var recoveryLoaded = false
    @ObservationIgnored @Dependency(IOSWorkspaceRecoveryStore.self) private var recoveryStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    func prepareRecovery() async {
        guard !recoveryLoaded else { return }
        do {
            recovery = try await recoveryStore.load() ?? .init()
            recoveryLoaded = true
            recoveryError = nil
        } catch { recoveryError = error.localizedDescription }
    }

    func flushRecovery() async {
        saveTask?.cancel()
        saveTask = nil
        guard recoveryLoaded else { return }
        do {
            try await recoveryStore.save(recovery)
            recoveryError = nil
        } catch { recoveryError = error.localizedDescription }
    }

    private func scheduleSave() {
        // Bound the checkpoint interval even when Host snapshots keep arriving.
        guard recoveryLoaded, saveTask == nil else { return }
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            guard let self else { return }
            // Do not cancel the task that is now performing the write.
            saveTask = nil
            await flushRecovery()
        }
    }

    func workspace(hostID: String, sessionName: String) -> IOSFileBrowserWorkspace? {
        workspaces[Key(hostID: hostID, sessionName: sessionName)]
    }

    func update(_ state: SessionStateMessage, client: ViewerRelayClient) {
        captureHost(state.pairId)
        let catalog = ViewerWorkspaceCatalog(state: state)
        // A rename retains its private presentation, but a new Host or tmux
        // incarnation gets fresh views and input endpoints.
        for key in workspaces.keys.filter({ $0.hostID == state.pairId }) {
            guard let workspace = workspaces[key] else { continue }
            if workspace.recoveryScope != catalog?.scope {
                remove(key, save: false)
            } else if
                let reference = workspace.recoveryReference,
                let route = catalog?.resolve(reference), route.sessionName != key.sessionName {
                workspaces.removeValue(forKey: key)
                workspaces[Key(hostID: key.hostID, sessionName: route.sessionName)] = workspace
            } else if workspace.recoveryReference != catalog?.reference(sessionName: key.sessionName) {
                // Do not retain a Files model from a replaced same-name session.
                remove(key, save: false)
            }
        }
        catalogs[state.pairId] = catalog
        clients[state.pairId] = client
        let retained = Dictionary(
            workspaces.filter { $0.key.hostID == state.pairId }.values
                .flatMap(\.tabs).filter { $0.hostTab != nil }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let sessions = Dictionary(grouping: TmuxWindow.groupPanes(Array(state.paneStates.values)), by: \.sessionName)
        for (sessionName, windows) in sessions where !sessionName.isEmpty {
            let key = Key(hostID: state.pairId, sessionName: sessionName)
            let workspace: IOSFileBrowserWorkspace
            let reference = catalog?.reference(sessionName: sessionName)
            if let existing = workspaces[key], existing.recoveryReference == reference {
                workspace = existing
            } else {
                remove(key, save: false)
                workspace = IOSFileBrowserWorkspace()
                workspaces[key] = workspace
                workspace.recoveryReference = reference
                workspace.recoveryScope = catalog?.scope
                if let reference {
                    workspace.restoresFolderDefaults = !recovery.sessions.contains {
                        $0.reference == reference || ($0.reference.pairID == reference.pairID && $0.reference.hostID != reference.hostID)
                    }
                }
            }
            workspace.syncHostTabs((state.fileTabs ?? []).filter { $0.sessionName == sessionName }, retained: retained)
            workspace.restoredFileIDs.formIntersection(Set(workspace.tabs.map(\.id)))
            if let reference, let catalog {
                restore(workspace, reference: reference, catalog: catalog, windows: windows)
                workspace.onSaveRecovery = { [weak self, weak workspace] in
                    guard let self, let workspace else { return }
                    capture(workspace, key: key)
                    scheduleSave()
                }
            }
            for tab in workspace.tabs where tab.hostTab == nil {
                tab.reconcileSource(windows: windows)
            }
        }
        for key in workspaces.keys.filter({ $0.hostID == state.pairId && sessions[$0.sessionName] == nil }) {
            remove(key, save: false)
        }
        scheduleSave()
    }

    func suspendHost(_ hostID: String) {
        captureHost(hostID)
        for (key, workspace) in workspaces where key.hostID == hostID {
            for tab in workspace.tabs {
                tab.releasePreview()
            }
        }
        scheduleSave()
    }

    func removeHost(_ hostID: String) {
        for key in workspaces.keys.filter({ $0.hostID == hostID }) {
            remove(key)
        }
        clients.removeValue(forKey: hostID)
        catalogs.removeValue(forKey: hostID)
        recovery.sessions.removeAll { $0.reference.pairID == hostID }
        recovery.drafts.removeAll { $0.pane.pairID == hostID }
        if recovery.selectedSession?.pairID == hostID {
            recovery.selectedSession = nil
        }
        scheduleSave()
    }

    func retainHosts(_ hostIDs: Set<String>) {
        let known = Set(clients.keys).union(recovery.sessions.map { $0.reference.pairID }).union(recovery.drafts.map { $0.pane.pairID })
        for hostID in known.subtracting(hostIDs) {
            removeHost(hostID)
        }
    }

    func dismissRecoveryError() {
        recoveryError = nil
    }

    private func remove(_ key: Key, save: Bool = true) {
        guard let workspace = workspaces.removeValue(forKey: key) else { return }
        if save {
            workspace.save()
        }
        workspace.onSaveRecovery = nil
        for tab in workspace.tabs {
            if tab.hostTab == nil {
                tab.reconcileSource(windows: [])
            }
            tab.releasePreview()
        }
    }

    private func captureHost(_ hostID: String) {
        for (key, workspace) in workspaces where key.hostID == hostID {
            capture(workspace, key: key)
        }
    }

    private func capture(_ workspace: IOSFileBrowserWorkspace, key: Key) {
        guard
            recoveryLoaded, let reference = workspace.recoveryReference, let catalog = catalogs[key.hostID],
            workspace.recoveryScope == catalog.scope, catalog.resolve(reference) != nil else { return }
        let previous = recovery.sessions.first { $0.reference == reference }
        var record = previous ?? .init(reference: reference, name: key.sessionName)
        record.name = key.sessionName
        let snapshots = workspace.tabs.compactMap { tab -> IOSWorkspaceRecoveryFile? in
            guard let snapshot = tab.snapshot else { return nil }
            let source = tab.sourcePaneID.flatMap { catalog.reference(paneID: $0) }
                ?? previous?.files.first(where: { $0.snapshot.id == tab.id })?.source
            return .init(snapshot: snapshot, source: source)
        }
        let ids = Set(snapshots.map { $0.snapshot.id })
        record.files = snapshots + (previous?.files.filter { $0.snapshot.hostOwned == true && !ids.contains($0.snapshot.id) } ?? [])
        if let selectedID = workspace.selectedID {
            record.selectedFileID = selectedID
        } else if !record.files.contains(where: { $0.snapshot.id == record.selectedFileID && $0.snapshot.hostOwned == true && !ids.contains($0.snapshot.id) }) {
            record.selectedFileID = nil
        }
        recovery.sessions.removeAll { $0.reference == reference }
        recovery.sessions.append(record)
        recovery.sessions.sort {
            ($0.reference.pairID, $0.reference.hostID.uuidString, $0.reference.sessionID.uuidString)
                < ($1.reference.pairID, $1.reference.hostID.uuidString, $1.reference.sessionID.uuidString)
        }
    }

    private func restore(_ workspace: IOSFileBrowserWorkspace, reference: ViewerWorkspaceReference, catalog: ViewerWorkspaceCatalog, windows: [TmuxWindow]) {
        guard let saved = recovery.sessions.first(where: { $0.reference == reference }) else { return }
        for file in saved.files {
            let source = file.source.flatMap(catalog.resolve)?.paneID
            if let existing = workspace.tabs.first(where: { $0.id == file.snapshot.id }) {
                // Newly received Host descriptors still need their saved private
                // preview once. Existing live navigation must not be overwritten.
                if workspace.restoredFileIDs.insert(file.snapshot.id).inserted {
                    existing.restoreNavigation(file.snapshot)
                }
                if file.source != nil {
                    existing.restoreSourcePane(source)
                }
            } else if file.snapshot.hostOwned != true {
                workspace.tabs.append(FileBrowserTab(snapshot: file.snapshot, sourcePaneID: source))
                workspace.restoredFileIDs.insert(file.snapshot.id)
            }
            if file.source != nil && source == nil {
                workspace.unavailableFileSources.insert(file.snapshot.id)
            } else {
                workspace.unavailableFileSources.remove(file.snapshot.id)
            }
        }
        if let id = saved.selectedWindowID {
            let window = ViewerWorkspaceReference(pairID: reference.pairID, hostID: reference.hostID, sessionID: reference.sessionID, windowID: id)
            let runtimeID = catalog.resolve(window)?.windowID
            workspace.restoredWindowID = windows.first { $0.stableId == runtimeID }?.id
            workspace.restoredPaneID = nil
            if let paneID = saved.selectedPaneID {
                var pane = window
                pane.paneID = paneID
                workspace.restoredPaneID = catalog.resolve(pane)?.paneID
            }
            workspace.hasPendingTerminalSelection = workspace.restoredWindowID == nil || (saved.selectedPaneID != nil && workspace.restoredPaneID == nil)
        }
        if workspace.selectedID == nil, let selected = saved.selectedFileID, workspace.tabs.contains(where: { $0.id == selected }) {
            workspace.selectedID = selected
        }
    }

    func recordSelection(workspace: IOSFileBrowserWorkspace, window: TmuxWindow?, paneID: String?) {
        guard
            let reference = workspace.recoveryReference, let catalog = catalogs[reference.pairID],
            workspace.recoveryScope == catalog.scope,
            workspaces.values.contains(where: { $0 === workspace }) else { return }
        let key = Key(hostID: reference.pairID, sessionName: catalog.resolve(reference)?.sessionName ?? "")
        capture(workspace, key: key)
        guard let index = recovery.sessions.firstIndex(where: { $0.reference == reference }) else { return }
        if !workspace.hasPendingTerminalSelection, let window, let window = catalog.reference(sessionName: key.sessionName, windowID: window.stableId) {
            recovery.sessions[index].selectedWindowID = window.windowID
            recovery.sessions[index].selectedPaneID = paneID.flatMap { catalog.reference(paneID: $0) }.flatMap { $0.windowID == window.windowID ? $0.paneID : nil }
            workspace.hasPendingTerminalSelection = false
        }
        scheduleSave()
    }

    func selectSession(_ reference: ViewerWorkspaceReference?) {
        guard reference == nil || recovery.sessions.contains(where: { $0.reference == reference }) else { return }
        recovery.selectedSession = reference
        scheduleSave()
    }

    func recordDraft(id: UUID, pane: ViewerWorkspaceReference, text: String) {
        guard pane.paneID != nil, pane.windowID != nil else { return }
        recovery.drafts.removeAll { $0.id == id }
        if !text.isEmpty {
            recovery.drafts.append(.init(id: id, pane: pane, text: text))
        }
        scheduleSave()
    }

    func discardDraft(_ id: UUID, submittedText: String? = nil) {
        recovery.drafts.removeAll { $0.id == id && (submittedText == nil || $0.text == submittedText) }
        scheduleSave()
    }

    func editDraft(_ id: UUID, text: String) {
        guard let index = recovery.drafts.firstIndex(where: { $0.id == id }) else { return }
        recovery.drafts[index].text = text
        scheduleSave()
    }

    func drafts(paneID: String, hostID: String) -> [IOSWorkspaceRecoveryDraft] {
        guard let pane = catalogs[hostID]?.reference(paneID: paneID) else { return [] }
        return recovery.drafts.filter { $0.pane == pane }
    }
}
