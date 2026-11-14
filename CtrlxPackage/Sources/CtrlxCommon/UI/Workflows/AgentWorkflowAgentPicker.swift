import CtrlxNetworking
import SwiftUI

@MainActor
struct AgentWorkflowAgentPicker: View {
    let instances: [AgentWorkflowInstance]
    let definition: AgentWorkflowDefinition?
    let refreshing: Bool
    let error: String?
    let refresh: () async -> Void
    let choose: (AgentWorkflowInstance) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var hasParticipants: Bool {
        definition?.agents.isEmpty == false
    }

    private var available: [AgentWorkflowInstance] {
        guard let definition, hasParticipants else { return instances }
        let currentIDs = Set(definition.agents.compactMap { definition.instance(for: $0.id, in: instances)?.id })
        return instances.filter { currentIDs.contains($0.id) }
    }

    private var filtered: [AgentWorkflowInstance] {
        available.filter { instance in
            search.isEmpty || [instance.displayName, instance.workingDirectory]
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
                            Text(instance.displayName)
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
                    } else if available.isEmpty {
                        ContentUnavailableView(
                            hasParticipants ? "No participating Agents available" : "No Agents available",
                            symbol: .sparkles,
                            description: hasParticipants ? "Refresh this list or choose a replacement in Participating Agents." : "Start an Agent tab, then refresh this list."
                        )
                        .accessibilityIdentifier("workflow-agent-picker-empty")
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
}
