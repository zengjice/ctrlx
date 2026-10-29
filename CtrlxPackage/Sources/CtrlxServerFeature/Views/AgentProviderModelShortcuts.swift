import CtrlxNetworking
import SwiftUI

struct AgentProviderModelShortcutPresentation: Identifiable {
    let id = UUID()
    let providerID: String?
    let name: String
}

struct AgentProviderModelShortcuts: View {
    let pluginID: String
    let provider: AgentProviderModelShortcutPresentation
    @Binding var hidden: AgentModelShortcuts
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: AgentModelSnapshot?
    @State private var error: String?
    @State private var refreshing = false
    @State private var revision = 0

    var body: some View {
        AgentModelCustomization(
            snapshot: snapshot, hidden: $hidden,
            unavailableReason: error, refreshing: refreshing,
            refresh: { revision += 1 }, done: { dismiss() },
            title: provider.name,
            modelsTitle: "Default Model Buttons",
            effortsTitle: "Default Effort Buttons",
            explanation: "Copied when creating a new Agent tab with this Provider. Each tab can customize its buttons; its current model and effort always stay visible."
        )
        .task(id: revision) {
            refreshing = true
            error = nil
            defer { refreshing = false }
            do {
                let options = try await coordinator.agentProviderModels(pluginID: pluginID, providerID: provider.providerID)
                try Task.checkCancellation()
                snapshot = .init(runtimeID: "provider-defaults", models: options, selection: nil, unavailableReason: nil)
                if options.isEmpty {
                    error = "The Provider returned no available models."
                }
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
