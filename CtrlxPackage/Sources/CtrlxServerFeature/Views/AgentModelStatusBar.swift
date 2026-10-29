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
    @State private var confirmed = false
    @State private var showsCustomization = false

    private var displayKey: AgentModelDisplayCache.Key? {
        guard let identity = pane?.workspaceIdentity, let pluginID = pane?.agentSession?.pluginID else { return nil }
        return .init(hostID: hostID ?? "local", pane: identity, pluginID: pluginID)
    }

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
        if let error {
            return error
        }
        if !confirmed {
            return "Refreshing the current model selection…"
        }
        if pane?.agentSession?.state.isActiveWorking == true {
            return "Wait for the Agent to finish before switching models."
        }
        if pane?.agentSession?.state.openForm != nil {
            return "Answer the Agent's request first."
        }
        return snapshot?.unavailableReason
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
            if let snapshot, !snapshot.models.isEmpty {
                AgentModelChoices(snapshot: snapshot, hidden: hidden, unavailableReason: unavailableReason, change: change, hide: { model, effort in hide(model: model, effort: effort) })
                    .disabled(refreshing)
            } else {
                Text(error ?? snapshot?.unavailableReason ?? (refreshing ? "Reading models…" : "Model shortcuts unavailable"))
                    .font(.caption).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(error ?? "Identify the Agent in the selected pane to show its models.")
            }
            if refreshing {
                ProgressView().controlSize(.mini).help("Refreshing models")
            } else if error != nil, snapshot?.models.isEmpty == false {
                Symbols.exclamationmarkTriangle.image
                    .foregroundStyle(.secondary).help(error ?? "")
            }
            Button { showsCustomization = true } label: {
                Symbols.ellipsisCircle.image
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(unavailableReason ?? "Customize model shortcuts for this tab · selected pane")
            .accessibilityLabel("Customize Model Shortcuts")
            .accessibilityIdentifier("model-shortcuts-customize")
            .popover(isPresented: $showsCustomization, arrowEdge: .bottom) {
                AgentModelCustomization(
                    snapshot: snapshot,
                    hidden: Binding(get: { hidden }, set: { value in
                        if let key = preferenceKey {
                            coordinator.agentModelPreferences.tabs[key] = value
                        }
                    }),
                    unavailableReason: unavailableReason,
                    refreshing: refreshing || changing,
                    refresh: { Task { await refresh(force: true) } },
                    done: { showsCustomization = false }
                )
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: 32)
        .padding(.horizontal, 8)
        .task(id: displayKey) {
            snapshot = displayKey.flatMap { coordinator.agentModelDisplayCache.snapshots[$0] }
            error = nil
            confirmed = false
            while !Task.isCancelled {
                if !changing {
                    await refresh()
                }
                do { try await Task.sleep(for: .seconds(error == nil ? 3 : 15)) }
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
        guard !refreshing, !changing, let key = displayKey else { return }
        let identity = key.pane
        refreshing = true
        defer { refreshing = false }
        do {
            let value = try await request(.init(workspacePane: identity, refresh: force))
            try Task.checkCancellation()
            guard key == displayKey, !changing else { return }
            snapshot = value
            error = nil
            confirmed = true
            coordinator.agentModelDisplayCache.snapshots[key] = value
            let identities: [WorkspacePaneIdentity]
            if let hostID {
                identities = coordinator.remoteSessionStore?.paneStates.compactMap { key, pane in
                    key.pairId == hostID ? pane.workspaceIdentity : nil
                } ?? []
            } else {
                identities = windowManager.paneStates.values.compactMap(\.workspaceIdentity)
            }
            coordinator.agentModelPreferences.prune(hostID: hostID ?? "local", identities: identities)
            coordinator.agentModelDisplayCache.prune(hostID: hostID ?? "local", identities: identities)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, key == displayKey, !changing else { return }
            confirmed = false
            self.error = error.localizedDescription
        }
    }

    private func change(_ selection: AgentModelSelection) {
        guard !changing, !refreshing, unavailableReason == nil, let key = displayKey, let snapshot else { return }
        let identity = key.pane
        changing = true
        error = nil
        Task {
            defer { changing = false }
            do {
                let value = try await request(.init(workspacePane: identity, runtimeID: snapshot.runtimeID, selection: selection, expectedSelection: snapshot.selection))
                guard key == displayKey else { return }
                self.snapshot = value
                confirmed = true
                coordinator.agentModelDisplayCache.snapshots[key] = value
            } catch {
                guard key == displayKey else { return }
                confirmed = false
                self.error = error.localizedDescription
            }
        }
    }

    private func request(_ spec: AgentModelControls) async throws -> AgentModelSnapshot {
        if let hostID {
            let start = ContinuousClock.now
            guard let connection = coordinator.viewerConnectionManager?.connection(for: hostID) else {
                throw ModelControlError("The Host is disconnected.")
            }
            let response = try await connection.sendCommand(spec, paneId: paneID, timeout: 25).get()
            coordinator.recordAgentModelDiagnostic(paneID: paneID, phase: "viewer-response", since: start, failure: response.error)
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
        .help(unavailableReason ?? "Switch the selected pane to \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
