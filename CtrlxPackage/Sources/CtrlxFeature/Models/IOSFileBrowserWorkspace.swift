import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Observation

@MainActor @Observable
final class IOSFileBrowserWorkspace {
    struct Context: Equatable {
        let hostID: String
        let directory: String

        init?(hostID: String, windows: [TmuxWindow]) {
            // Re-entry also starts at the Host's active window, not a viewer-local selection.
            guard
                let window = windows.first(where: \.isWindowActive) ?? windows.first,
                let pane = window.activePane,
                let directory = pane.agentSession?.detectedProjectPath ?? pane.currentPath,
                !directory.isEmpty else { return nil }
            self.hostID = hostID
            self.directory = directory
        }

        var storageKey: String? {
            guard let key = try? JSONEncoder().encode([hostID, directory]) else { return nil }
            return "fileBrowserWorkspace.v1." + key.base64EncodedString()
        }
    }

    var tabs: [FileBrowserTab] = []
    var selectedID: UUID?
    var linkedTabOrder: [PaneLinkedTabID] = []
    var didRestoreLinkedTabOrder = false
    let recoveryID = UUID()
    var recoveryReference: ViewerWorkspaceReference?
    var recoveryScope: WorkspaceIdentityScope?
    var restoredWindowID: String?
    var restoredPaneID: String?
    var hasPendingTerminalSelection = false
    var unavailableFileSources: Set<UUID> = []
    var restoredFileIDs: Set<UUID> = []
    var restoresFolderDefaults = true
    @ObservationIgnored var onSaveRecovery: (() -> Void)?
    @ObservationIgnored private var context: Context?
    @ObservationIgnored @Dependency(PreferencesService.self) private var preferences

    var selected: FileBrowserTab? {
        tabs.first { $0.id == selectedID }
    }

    var snapshots: [FileBrowserTab.Snapshot] {
        tabs.filter { $0.hostTab == nil }.compactMap(\.snapshot)
    }

    var recoverySnapshots: [FileBrowserTab.Snapshot] {
        tabs.compactMap(\.snapshot)
    }

    func updateContext(_ context: Context?) {
        guard let context, self.context != context, let name = context.storageKey else { return }
        let shouldRestore = restoresFolderDefaults && self.context == nil && tabs.allSatisfy { $0.hostTab != nil }
        self.context = context
        // Seed once. A directory change moves the save target without replacing live tabs.
        guard shouldRestore else {
            save()
            return
        }
        guard
            let data = preferences.data(forKey: name), data.count <= 1_024 * 1_024,
            let saved = try? JSONDecoder().decode([FileBrowserTab.Snapshot].self, from: data) else { return }
        // Host catalogs can arrive before the session page establishes its context.
        var seen = Set(tabs.map(\.id))
        tabs += saved.filter { $0.hostOwned != true && seen.insert($0.id).inserted }.prefix(30).map { FileBrowserTab(snapshot: $0) }
    }

    func save() {
        onSaveRecovery?()
        guard let storageKey = context?.storageKey, let data = try? JSONEncoder().encode(snapshots) else { return }
        preferences.setData(value: data, forKey: storageKey)
    }

    @discardableResult
    func adopt(_ descriptor: HostFileTab) -> FileBrowserTab {
        if let tab = tabs.first(where: { $0.id == descriptor.id }) {
            tab.updateHostTab(descriptor)
            return tab
        }
        let tab = FileBrowserTab(hostTab: descriptor)
        tabs.append(tab)
        return tab
    }

    func syncHostTabs(_ descriptors: [HostFileTab], retained: [UUID: FileBrowserTab] = [:]) {
        let ids = Set(descriptors.map(\.id))
        for tab in tabs where tab.hostTab != nil && !ids.contains(tab.id) {
            tab.releasePreview()
        }
        tabs.removeAll { $0.hostTab != nil && !ids.contains($0.id) }
        for descriptor in descriptors {
            if !tabs.contains(where: { $0.id == descriptor.id }), let tab = retained[descriptor.id] {
                tabs.append(tab)
            }
            adopt(descriptor)
        }
        if let selectedID, !tabs.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    func closeSelected() {
        guard let selectedID else { return }
        close(selectedID)
    }

    func reorder(_ ids: [UUID]) {
        guard ids.count == tabs.count, Set(ids) == Set(tabs.map(\.id)) else { return }
        tabs = ids.compactMap { id in tabs.first { $0.id == id } }
        save()
    }

    func recordLinkedTabOrder(_ ids: [PaneLinkedTabID]) {
        guard linkedTabOrder != ids else { return }
        linkedTabOrder = ids
        save()
    }

    func close(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = nil
        }
        save()
    }
}
