import SwiftUI

struct RemoteReconnectSettingsSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section("Reconnection") {
            Toggle("Auto-reconnect on connection loss", isOn: $settings.autoReconnect)

            if settings.autoReconnect {
                LabeledContent("Reconnect delay") {
                    HStack {
                        TextField("", value: $settings.reconnectDelay, format: .number)
                            .frame(width: 60)
                        Text("seconds")
                    }
                }
            }
        }
        .settingsAnchor(.reconnection)
    }
}
