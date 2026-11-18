import CtrlxNetworking
import SwiftUI

@MainActor
struct AgentWorkflowAgentPicker: View {
    enum Purpose {
        case step
        case addParticipant
    }

    let instances: [AgentWorkflowInstance]
    let definition: AgentWorkflowDefinition
    let purpose: Purpose
    let refreshing: Bool
    let error: String?
    let refresh: () async -> Void
    let choose: (AgentWorkflowInstance) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var hasParticipants: Bool {
        !definition.agents.isEmpty
    }

    private var available: [AgentWorkflowInstance] {
        let currentIDs = Set(definition.agents.compactMap { definition.instance(for: $0.id, in: instances)?.id })
        switch purpose {
        case .step:
            return instances.filter { currentIDs.contains($0.id) }
        case .addParticipant:
            return instances.filter { !currentIDs.contains($0.id) }
        }
    }

    private var filtered: [AgentWorkflowInstance] {
        available.filter { instance in
            search.isEmpty || [instance.displayName, instance.workingDirectory, instance.paneID]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch purpose {
        case .step:
            ContentUnavailableView(
                hasParticipants ? "No participating Agents available" : "No participating Agents configured",
                symbol: .sparkles,
                description: hasParticipants ? "Refresh this list or choose a replacement in Participating Agents." : "Add an Agent in Participating Agents before choosing one for this step."
            )
        case .addParticipant:
            ContentUnavailableView("No more Agents available", symbol: .sparkles, description: "Start an Agent tab on this Host, then refresh this list.")
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
                            Text("\(instance.displayName) · \(instance.paneID)")
                            Text(instance.workingDirectory)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
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
                        emptyState.accessibilityIdentifier("workflow-agent-picker-empty")
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .searchable(text: $search, prompt: "Find an Agent")
            .navigationTitle(purpose == .step ? "Add Agent step" : "Add existing Agent")
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
