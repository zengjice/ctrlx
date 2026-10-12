import Dependencies
import SwiftUI

@MainActor
private struct FileBrowserCacheMaintenance: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Dependency(FileBrowserDownloadClient.self) private var downloads

    func body(content: Content) -> some View {
        content.task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // Shared across windows, throttled by the cache actor, off MainActor.
            await downloads.maintain()
        }
    }
}

package extension View {
    @MainActor
    func fileBrowserCacheMaintenance() -> some View {
        modifier(FileBrowserCacheMaintenance())
    }
}
