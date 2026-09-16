import SwiftUI

@MainActor
package struct QuickPhraseSyncToggle: View {
    let store: QuickPhraseStore
    let pairID: String

    package init(store: QuickPhraseStore, pairID: String) {
        self.store = store
        self.pairID = pairID
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Sync Quick Phrases", isOn: Binding(
                get: { store.isSyncEnabled(for: pairID) },
                set: { store.setSyncEnabled($0, for: pairID) }
            ))
            Text("Enable on both devices to merge all saved phrases over the encrypted connection. Changes also reach your other sync-enabled devices. Disabling keeps downloaded phrases. Agent commands already use the same built-in list.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = store.loadError ?? store.syncErrors[pairID] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
