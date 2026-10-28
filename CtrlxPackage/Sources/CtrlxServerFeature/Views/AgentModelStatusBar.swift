import CtrlxCommon
import CtrlxNetworking
import SwiftUI

@MainActor
struct AgentModelStatusBar: View {
    let hostID: String?
    let paneID: String
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(AppSettings.self) private var settings
    @State private var snapshot: AgentModelSnapshot?
    @State private var error: String?
    @State private var changing = false
    @State private var refreshing = false

    private var pane: PaneState? {
        if let hostID {
            return coordinator.remoteSessionStore?.paneState(for: paneID, hostId: hostID)
        }
        return windowManager.paneStates[paneID]
    }

    private var preferenceKey: AgentModelPreferences.Key? {
        guard let identity = pane?.workspaceIdentity else { return nil }
        return .init(hostID: hostID ?? "local", serverID: identity.serverID, windowID: identity.windowID)
    }

    private var hidden: AgentModelPreferences.Hidden {
        preferenceKey.flatMap { coordinator.agentModelPreferences.tabs[$0] } ?? .init()
    }

    private var unavailableReason: String? {
        if changing {
            return "Waiting for the Agent to confirm the change…"
        }
        if pane?.agentSession?.state.isActiveWorking == true {
            return "Wait for the Agent to finish before switching models."
        }
        if pane?.agentSession?.state.openForm != nil {
            return "Answer the Agent's request first."
        }
        return error ?? snapshot?.unavailableReason
    }

    var body: some View {
        if pane?.agentSession != nil {
            content
        } else {
            Color.clear.frame(minWidth: 0, maxWidth: .infinity, maxHeight: 28)
        }
    }

    private var content: some View {
        HStack(spacing: 4) {
            if let snapshot {
                AgentModelChoices(snapshot: snapshot, hidden: hidden, unavailableReason: unavailableReason, change: change, hide: { model, effort in hide(model: model, effort: effort) })
            } else {
                Text(refreshing ? "Reading models…" : "Model shortcuts unavailable")
                    .font(.caption).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(error ?? "Identify the Agent in the first pane to show its models.")
            }
            Menu {
                if let reason = unavailableReason {
                    Text(reason)
                }
                Button("Refresh Models") { Task { await refresh(force: true) } }
                    .disabled(refreshing || changing)
                if let snapshot {
                    Section("Models in This Tab") {
                        ForEach(snapshot.models) { model in
                            Toggle(model.name, isOn: Binding(get: {
                                hidden.shows(model: model, selection: snapshot.selection)
                            }, set: { visible in setHidden(model: model.id, visible: visible) }))
                                .disabled(model.id == snapshot.selection?.model)
                        }
                    }
                    Section("Effort in This Tab") {
                        ForEach(Array(Set(snapshot.models.flatMap(\.efforts))).sorted(), id: \.self) { effort in
                            Toggle(effort, isOn: Binding(get: {
                                hidden.shows(effort: effort, selection: snapshot.selection)
                            }, set: { visible in setHidden(effort: effort, visible: visible) }))
                                .disabled(effort == snapshot.selection?.effort)
                        }
                    }
                    Button("Restore Default Buttons") {
                        if let key = preferenceKey {
                            coordinator.agentModelPreferences.tabs[key] = nil
                        }
                    }
                }
            } label: {
                Symbols.ellipsisCircle.image
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(unavailableReason ?? "Customize model shortcuts for this tab · first pane")
            .accessibilityLabel("Customize Model Shortcuts")
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: 32)
        .padding(.horizontal, 8)
        .task(id: "\(hostID ?? "local"):\(paneID):\(pane?.agentSession?.pluginID ?? "")") {
            snapshot = nil
            error = nil
            while !Task.isCancelled {
                if !changing {
                    await refresh()
                }
                do { try await Task.sleep(for: .seconds(3)) }
                catch { break }
            }
        }
    }

    private func hide(model: String? = nil, effort: String? = nil) {
        setHidden(model: model, effort: effort, visible: false)
    }

    private func setHidden(model: String? = nil, effort: String? = nil, visible: Bool) {
        guard let key = preferenceKey else { return }
        var value = hidden
        if let model {
            if visible {
                value.models.remove(model)
            } else {
                value.models.insert(model)
            }
        }
        if let effort {
            if visible {
                value.efforts.remove(effort)
            } else {
                value.efforts.insert(effort)
            }
        }
        coordinator.agentModelPreferences.tabs[key] = value
    }

    private func refresh(force: Bool = false) async {
        guard !refreshing, !changing, pane?.agentSession != nil, let identity = pane?.workspaceIdentity else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let value = try await request(.init(workspacePane: identity, refresh: force))
            try Task.checkCancellation()
            guard identity.isSamePane(as: pane?.workspaceIdentity), !changing else { return }
            snapshot = value
            error = nil
            let identities: [WorkspacePaneIdentity]
            if let hostID {
                identities = coordinator.remoteSessionStore?.paneStates.compactMap { key, pane in
                    key.pairId == hostID ? pane.workspaceIdentity : nil
                } ?? []
            } else {
                identities = windowManager.paneStates.values.compactMap(\.workspaceIdentity)
            }
            coordinator.agentModelPreferences.prune(hostID: hostID ?? "local", identities: identities)
        } catch is CancellationError {
            return
        } catch {
            snapshot = nil
            self.error = error.localizedDescription
        }
    }

    private func change(_ selection: AgentModelSelection) {
        guard !changing, let identity = pane?.workspaceIdentity, let snapshot else { return }
        changing = true
        error = nil
        Task {
            defer { changing = false }
            do {
                let value = try await request(.init(workspacePane: identity, runtimeID: snapshot.runtimeID, selection: selection, expectedSelection: snapshot.selection))
                guard identity.isSamePane(as: pane?.workspaceIdentity) else { return }
                self.snapshot = value
            } catch { self.error = error.localizedDescription }
        }
    }

    private func request(_ spec: AgentModelControls) async throws -> AgentModelSnapshot {
        if let hostID {
            guard let connection = coordinator.viewerConnectionManager?.connection(for: hostID) else {
                throw ModelControlError("The Host is disconnected.")
            }
            let response = try await connection.sendCommand(spec, paneId: paneID, timeout: 25).get()
            guard response.success, let value = response.agentModels else { throw ModelControlError(response.error ?? "Model controls are unavailable on this Host.") }
            return value
        }
        return try await coordinator.handleAgentModels(spec, paneID: paneID)
    }

    private struct ModelControlError: LocalizedError {
        let message: String
        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? {
            message
        }
    }
}

@MainActor
struct AgentModelChoices: View {
    let snapshot: AgentModelSnapshot
    let hidden: AgentModelPreferences.Hidden
    let unavailableReason: String?
    let change: (AgentModelSelection) -> Void
    let hide: (String?, String?) -> Void
    @Environment(AppSettings.self) private var settings

    private var displayedEfforts: [String] {
        if let model = snapshot.models.first(where: { $0.id == snapshot.selection?.model }) {
            return model.efforts
        }
        var seen: Set<String> = []
        return snapshot.models.flatMap(\.efforts).filter { seen.insert($0).inserted }
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(snapshot.models.filter { hidden.shows(model: $0, selection: snapshot.selection) }) { model in
                    choice(model.name, selected: model.id == snapshot.selection?.model) {
                        let effort = snapshot.selection?.effort.flatMap { model.efforts.contains($0) ? $0 : nil } ?? model.defaultEffort
                        change(.init(model: model.id, effort: effort))
                    }
                    .contextMenu {
                        Button("Hide \(model.name) in This Tab") { hide(model.id, nil) }
                            .disabled(model.id == snapshot.selection?.model)
                    }
                }
                if !displayedEfforts.isEmpty {
                    Divider().frame(height: 16).padding(.horizontal, 4)
                    ForEach(displayedEfforts.filter { hidden.shows(effort: $0, selection: snapshot.selection) }, id: \.self) { effort in
                        choice(effort, selected: effort == snapshot.selection?.effort) {
                            if let model = snapshot.selection?.model {
                                change(.init(model: model, effort: effort))
                            }
                        }
                        .disabled(snapshot.selection == nil)
                        .contextMenu {
                            Button("Hide \(effort) in This Tab") { hide(nil, effort) }
                                .disabled(effort == snapshot.selection?.effort)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.hidden)
        .frame(height: 32)
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if selected {
                    Symbols.checkmark.image.font(.caption2.bold())
                }
                Text(title).lineLimit(1)
            }
            .font(.caption.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .foregroundStyle(selected ? settings.theme.workspaceAccentColor : settings.theme.workspaceSecondaryTextColor)
            .background(settings.theme.workspaceAccentColor.opacity(selected ? 0.2 : 0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(unavailableReason != nil || selected)
        .help(unavailableReason ?? "Switch this tab's first pane to \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
