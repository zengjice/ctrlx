import CtrlxNetworking
import SwiftUI

@MainActor
struct AgentWorkflowAgentPicker: View {
    let instances: [AgentWorkflowInstance]
    let participants: [AgentWorkflowParticipant]
    let refreshing: Bool
    let error: String?
    let refresh: () async -> Void
    let choose: (AgentWorkflowInstance) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [AgentWorkflowInstance] {
        instances.filter { instance in
            search.isEmpty || [instance.displayName, instance.workingDirectory, role(for: instance)]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { instance in
                    Button {
                        choose(instance)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(role(for: instance))
                            if role(for: instance) != instance.displayName {
                                Text(instance.displayName).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(instance.workingDirectory).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workflow-choose-agent-\(instance.id)")
                }
                if filtered.isEmpty {
                    if refreshing {
                        ProgressView("Loading Agents…")
                    } else if instances.isEmpty {
                        ContentUnavailableView("No Agents available", symbol: .sparkles, description: "Start an Agent tab, then refresh this list.")
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .searchable(text: $search, prompt: "Find an Agent")
            .navigationTitle("Add Agent step")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("workflow-agent-picker-cancel")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await refresh() } } label: { Label("Refresh Agents", symbol: .arrowClockwise) }.disabled(refreshing)
                }
            }
            .task { await refresh() }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 560, minHeight: 360, idealHeight: 500)
        #endif
    }

    private func role(for instance: AgentWorkflowInstance) -> String {
        participants.first { $0.id == instance.id }?.name ?? instance.displayName
    }
}
