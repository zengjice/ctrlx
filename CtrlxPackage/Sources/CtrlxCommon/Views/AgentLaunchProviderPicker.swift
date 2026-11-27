import SwiftUI

@MainActor
public struct AgentLaunchProviderPicker: View {
    let agent: SessionLaunchAgent
    @Binding var selection: String?

    public init(agent: SessionLaunchAgent, selection: Binding<String?>) {
        self.agent = agent
        self._selection = selection
    }

    public var body: some View {
        Picker("Provider", selection: Binding(
            get: { agent.providerID(for: selection) },
            set: { selection = $0 }
        )) {
            ForEach(agent.orderedProviders) { provider in
                Text(provider.name).tag(Optional(provider.id))
            }
            if agent.defaultProvider == nil {
                Text("Current CLI configuration").tag(String?.none)
            }
        }
        .pickerStyle(.menu)
    }
}
