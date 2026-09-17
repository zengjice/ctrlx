import SwiftUI

/// The same device-level controls on Mac and iOS. Pairing/terminal roles never
/// leak into the normal consent UI, and the screen owns no networking state.
@MainActor
package struct QuickPhraseSyncSettingsView: View {
    let store: QuickPhraseStore

    package init(store: QuickPhraseStore) { self.store = store }

    package var body: some View {
        Form {
            Section {
                if store.syncDevices.isEmpty {
                    Text("Pair a device first to sync quick phrases.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.syncDevices) { device in
                    QuickPhraseSyncDeviceRow(store: store, device: device)
                }
            } header: {
                Text("Devices")
            } footer: {
                Text("Enable on both devices to share your entire phrase library over an encrypted connection. One switch covers every connection to that device. Offline changes merge when you reconnect.")
            }

            Section("Sharing Scope") {
                Text("Phrases can also reach other devices through a shared device. Turning sync off stops direct sharing with that device; it does not erase downloaded phrases or block indirect sharing through other devices.")
                Text("Agent commands use the same built-in list and do not need a sync switch.")
                    .foregroundStyle(.secondary)
            }

            if let error = store.loadError {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Quick Phrase Sync")
        .accessibilityIdentifier("quick-phrase-sync-settings")
    }
}

@MainActor
private struct QuickPhraseSyncDeviceRow: View {
    let store: QuickPhraseStore
    let device: QuickPhraseSyncDevice
    @State private var showingConfirmation = false

    private var needsConfirmation: Bool { store.syncConsent(for: device.id) == .needsConfirmation }
    private var errors: [String] { Set(device.pairIDs.compactMap { store.syncErrors[$0] }).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if needsConfirmation {
                HStack {
                    Text(device.name)
                    Spacer()
                    Button("Review…") { showingConfirmation = true }
                }
                Text("Needs confirmation — previous connection switches disagree. Their existing behavior is kept until you choose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Toggle(device.name, isOn: Binding(
                    get: { store.syncConsent(for: device.id) == .enabled },
                    set: { store.setDeviceSyncEnabled($0, deviceID: device.id) }
                ))
                .accessibilityIdentifier("quick-phrase-sync-toggle-\(device.id)")
                statusText
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Device key: \(String(device.id.prefix(12)))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(errors, id: \.self) { error in
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .confirmationDialog("Sync with \(device.name)?", isPresented: $showingConfirmation, titleVisibility: .visible) {
            Button("Enable for This Device") { store.setDeviceSyncEnabled(true, deviceID: device.id) }
            Button("Disable for This Device") { store.setDeviceSyncEnabled(false, deviceID: device.id) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This choice applies to every connection to this device. Both devices must allow sync before phrases are shared.")
        }
    }

    private var statusText: Text {
        switch store.syncStatus(for: device.id) {
        case .disabled: Text("Off on this device")
        case .needsConfirmation: Text("Needs confirmation")
        case .offline: Text("Not connected — sync resumes after connecting")
        case .waitingForPeer: Text("Waiting for the other device to enable sync")
        case .ready: Text("Connected — both devices allow sync")
        case .unsupported: Text("Update the other device to use quick phrase sync")
        case .unavailable: Text("Sync unavailable — the local phrase library could not be read")
        }
    }
}
