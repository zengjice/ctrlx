import CtrlxCommon
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
            guard let window = windows.first(where: \.isWindowActive) ?? windows.first,
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
    @ObservationIgnored private var context: Context?
    @ObservationIgnored @Dependency(PreferencesService.self) private var preferences

    var selected: FileBrowserTab? { tabs.first { $0.id == selectedID } }
    var snapshots: [FileBrowserTab.Snapshot] { tabs.compactMap(\.snapshot) }

    func updateContext(_ context: Context?) {
        guard let context, self.context != context, let name = context.storageKey else { return }
        let shouldRestore = self.context == nil && tabs.isEmpty
        self.context = context
        // Seed once. A directory change moves the save target without replacing live tabs.
        guard shouldRestore else {
            save()
            return
        }
        guard let data = preferences.data(forKey: name), data.count <= 1024 * 1024,
              let saved = try? JSONDecoder().decode([FileBrowserTab.Snapshot].self, from: data) else { return }
        var seen: Set<UUID> = []
        tabs = saved.prefix(30).filter { seen.insert($0.id).inserted }.map(FileBrowserTab.init(snapshot:))
    }

    func save() {
        guard let storageKey = context?.storageKey, let data = try? JSONEncoder().encode(snapshots) else { return }
        preferences.setData(value: data, forKey: storageKey)
    }

    func open(paneID: String?) {
        let tab = FileBrowserTab(sourcePaneID: paneID)
        tabs.append(tab)
        selectedID = tab.id
    }

    func closeSelected() {
        tabs.removeAll { $0.id == selectedID }
        selectedID = nil
        save()
    }
}
