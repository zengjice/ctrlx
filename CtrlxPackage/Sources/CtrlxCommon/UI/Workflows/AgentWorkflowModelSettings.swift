import CtrlxNetworking
import SwiftUI

@MainActor
struct AgentWorkflowModelSettings: View {
    let endpoint: AgentWorkflowEndpoint
    let hostID: UUID
    let instance: AgentWorkflowInstance?
    @Binding var selection: AgentModelSelection?
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Model and effort…") { choosing = true }.disabled(instance == nil)
                .accessibilityIdentifier("workflow-model-open")
            if let selection {
                Text(selection.model + (selection.effort.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                Button("Use current Agent settings") { self.selection = nil }
            } else {
                Text("Uses the Agent's current model and effort.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Applied before this step starts. The selection stays active until another step or you change it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $choosing) {
            if let instance {
                AgentWorkflowModelSelectionView(endpoint: endpoint, hostID: hostID, instance: instance, initial: selection) {
                    selection = $0
                }
            }
        }
    }
}

@MainActor
private struct AgentWorkflowModelSelectionView: View {
    let endpoint: AgentWorkflowEndpoint
    let hostID: UUID
    let instance: AgentWorkflowInstance
    let choose: (AgentModelSelection?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: AgentModelSelection
    @State private var snapshot: AgentModelSnapshot?
    @State private var loading = false
    @State private var error: String?

    init(endpoint: AgentWorkflowEndpoint, hostID: UUID, instance: AgentWorkflowInstance, initial: AgentModelSelection?, choose: @escaping (AgentModelSelection?) -> Void) {
        self.endpoint = endpoint
        self.hostID = hostID
        self.instance = instance
        self.choose = choose
        self._selection = State(initialValue: initial ?? .init(model: "", effort: nil))
    }

    private var model: AgentModelOption? {
        snapshot?.models.first { $0.id == selection.model }
    }

    private var valid: Bool {
        guard let model else { return false }
        return selection.effort.map(model.efforts.contains) ?? true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Button("Use current Agent settings") { choose(nil)
                        dismiss()
                    }
                    .accessibilityIdentifier("workflow-model-inherit")
                    if let snapshot {
                        Picker("Model", selection: $selection.model) {
                            ForEach(snapshot.models) { Text($0.name).tag($0.id) }
                            if model == nil, !selection.model.isEmpty {
                                Text("Unavailable · \(selection.model)").tag(selection.model)
                            }
                        }.accessibilityIdentifier("workflow-step-model")
                        if let model, !model.efforts.isEmpty {
                            Picker("Effort", selection: $selection.effort) {
                                Text("Use native setting").tag(String?.none)
                                ForEach(model.efforts, id: \.self) { Text($0).tag(Optional($0)) }
                            }.accessibilityIdentifier("workflow-step-effort")
                        }
                        if let warning = snapshot.catalogWarning {
                            Text(warning).foregroundStyle(.orange)
                        }
                        if snapshot.models.isEmpty, let reason = snapshot.unavailableReason {
                            Text(reason).foregroundStyle(.secondary)
                        }
                    }
                    if loading {
                        ProgressView("Loading models…")
                    }
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                    Button("Refresh models") { Task { await load(refresh: true) } }.disabled(loading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Step model")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("workflow-model-cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use selection") { choose(selection)
                        dismiss()
                    }
                    .disabled(!valid || loading).accessibilityIdentifier("workflow-model-apply")
                }
            }
            .task { await load(refresh: false) }
            .onChange(of: selection.model) { _, _ in
                if let effort = selection.effort, model?.efforts.contains(effort) != true {
                    selection.effort = model?.defaultEffort
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 480, minHeight: 300)
        #endif
    }

    private func load(refresh: Bool) async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let response = try await endpoint.request(.models(instanceID: instance.id, refresh: refresh), hostID: hostID)
            guard let value = response.modelSnapshot, value.runtimeID == instance.processRuntimeID else {
                throw AgentWorkflowError("The Agent changed. Refresh the Agent list before choosing a model.")
            }
            if selection.model.isEmpty {
                selection = value.selection ?? value.models.first.map { .init(model: $0.id, effort: $0.defaultEffort) } ?? selection
            }
            snapshot = value
        } catch is CancellationError {
            return
        } catch { self.error = error.localizedDescription }
    }
}
