import CtrlxNetworking
import SwiftUI

/// These checkboxes change the current tab's display, never the Agent's model.
struct AgentModelCustomization: View {
    let snapshot: AgentModelSnapshot?
    @Binding var hidden: AgentModelPreferences.Hidden
    let unavailableReason: String?
    let refreshing: Bool
    let refresh: () -> Void
    let done: () -> Void
    var defaults = AgentModelShortcuts()
    var title = "Model Shortcuts"
    var modelsTitle = "Models in This Tab"
    var effortsTitle = "Effort in This Tab"
    var explanation = "The current model and effort always stay visible."

    private var efforts: [String] {
        var seen: Set<String> = []
        return (snapshot?.models.flatMap(\.efforts) ?? []).filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let unavailableReason {
                        Text(unavailableReason).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let snapshot, !snapshot.models.isEmpty {
                        Text(modelsTitle).font(.subheadline.weight(.semibold))
                        ForEach(snapshot.models) { model in
                            Toggle(isOn: Binding(get: {
                                hidden.shows(model: model, selection: snapshot.selection)
                            }, set: { visible in
                                if visible {
                                    hidden.models.remove(model.id)
                                } else {
                                    hidden.models.insert(model.id)
                                }
                            })) { row(model.name, selected: model.id == snapshot.selection?.model) }
                                .disabled(model.id == snapshot.selection?.model)
                                .accessibilityIdentifier("model-shortcut-visible-\(model.id)")
                        }
                        if !efforts.isEmpty {
                            Divider()
                            Text(effortsTitle).font(.subheadline.weight(.semibold))
                            ForEach(efforts, id: \.self) { effort in
                                Toggle(isOn: Binding(get: {
                                    hidden.shows(effort: effort, selection: snapshot.selection)
                                }, set: { visible in
                                    if visible {
                                        hidden.efforts.remove(effort)
                                    } else {
                                        hidden.efforts.insert(effort)
                                    }
                                })) { row(effort, selected: effort == snapshot.selection?.effort) }
                                    .disabled(effort == snapshot.selection?.effort)
                                    .accessibilityIdentifier("model-effort-visible-\(effort)")
                            }
                        }
                        Text(explanation)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            }
            .frame(maxHeight: 380)
            .toggleStyle(.checkbox)
            Divider()
            HStack {
                Button("Refresh Models", action: refresh).disabled(refreshing)
                Spacer()
                Button("Restore Defaults") { hidden = defaults }
                    .disabled(snapshot?.models.isEmpty != false)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func row(_ name: String, selected: Bool) -> some View {
        HStack {
            Text(name)
            Spacer()
            if selected {
                Text("Current").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
