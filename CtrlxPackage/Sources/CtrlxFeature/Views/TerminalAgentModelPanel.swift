#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftUI

    @MainActor
    struct TerminalAgentModelButton: View {
        let context: TerminalPhraseContext
        let pluginID: String
        let pane: WorkspacePaneIdentity?
        @Binding var presentation: TerminalQuickActionPresentation

        var body: some View {
            Button {
                guard let pane, context.target.paneID != nil else { return }
                presentation.toggle(.models(.init(context: context, pluginID: pluginID, pane: pane)))
            } label: {
                Text("Model").font(.subheadline.weight(.medium))
            }
            .disabled(context.target.paneID == nil || pane == nil)
            .accessibilityHint("Choose the current Agent's model or reasoning effort")
            .accessibilityIdentifier("terminal-agent-model-control")
        }
    }

    @MainActor
    struct TerminalAgentModelPanel: View {
        let captured: TerminalAgentModelPresentation
        let currentContext: TerminalPhraseContext
        let hidden: AgentModelShortcuts
        let unavailableReason: String?
        let request: @MainActor (AgentModelControls) async throws -> AgentModelSnapshot
        let close: () -> Void

        private enum Tab: String, CaseIterable {
            case model = "Model"
            case effort = "Effort"
        }

        @ScaledMetric(relativeTo: .subheadline) private var minimumButtonWidth: CGFloat = 112
        @State private var tab = Tab.model
        @State private var snapshot: AgentModelSnapshot?
        @State private var readError: String?
        @State private var changeError: String?
        @State private var refreshing = false
        @State private var changing = false

        private var inputUnavailableReason: String? {
            captured.context.hasSameInput(as: currentContext) && currentContext.canSend
                ? nil : "The terminal is not ready for a model change."
        }

        private var changesDisabled: Bool {
            refreshing || changing || unavailableReason != nil || inputUnavailableReason != nil
        }

        var body: some View {
            VStack(spacing: 0) {
                TerminalQuickActionPanelHeader(title: "Model", close: close)
                Picker("Model options", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .accessibilityIdentifier("terminal-agent-model-tabs")
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let reason = unavailableReason ?? inputUnavailableReason ?? readError ?? snapshot?.unavailableReason {
                            Text(reason).font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("terminal-agent-model-unavailable")
                        }
                        if let warning = snapshot?.catalogWarning {
                            Text(warning).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let snapshot, !snapshot.models.isEmpty {
                            choices(snapshot)
                        } else if snapshot != nil, !refreshing, unavailableReason == nil, readError == nil {
                            Text("No model shortcuts are available for this Agent.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if refreshing || changing {
                            ProgressView(changing ? "Switching…" : "Reading Models…")
                                .font(.subheadline)
                                .accessibilityIdentifier("terminal-agent-model-progress")
                        }
                        Button {
                            Task { await refresh(force: true) }
                        } label: {
                            Label("Refresh Models", symbol: .arrowClockwise)
                        }
                        .disabled(refreshing || changing || unavailableReason != nil)
                        .accessibilityIdentifier("terminal-agent-model-refresh")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }
            .task(id: unavailableReason == nil) {
                guard unavailableReason == nil else { return }
                await refresh(force: false)
            }
            .alert("Model Change Failed", isPresented: Binding(
                get: { changeError != nil }, set: {
                    if !$0 {
                        changeError = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) { changeError = nil }
            } message: {
                Text(changeError ?? "")
            }
        }

        @ViewBuilder
        private func choices(_ snapshot: AgentModelSnapshot) -> some View {
            let options = TerminalAgentModelOptions(snapshot: snapshot, hidden: hidden)
            if tab == .model, options.models.isEmpty {
                Text("Model shortcuts are hidden for this tab.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if tab == .effort, options.efforts.isEmpty {
                Text(snapshot.selection == nil ? "Choose a model first." : "No effort shortcuts are available for this model.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumButtonWidth), spacing: 8)], spacing: 8) {
                    if tab == .model {
                        ForEach(options.models) { model in
                            choice(model.name, selected: model.id == snapshot.selection?.model, selection: options.selection(modelID: model.id))
                                .accessibilityIdentifier("terminal-agent-model-\(model.id)")
                        }
                    } else {
                        ForEach(options.efforts, id: \.self) { effort in
                            choice(effort, selected: effort == snapshot.selection?.effort, selection: options.selection(effort: effort))
                                .accessibilityIdentifier("terminal-agent-effort-\(effort)")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 12))
            }
        }

        private func choice(_ title: String, selected: Bool, selection: AgentModelSelection?) -> some View {
            Button {
                if let selection {
                    change(selection)
                }
            } label: {
                HStack(spacing: 4) {
                    if selected {
                        Symbols.checkmark.image
                    }
                    Text(title).lineLimit(2).minimumScaleFactor(0.8)
                }
                .font(.subheadline.weight(selected ? .semibold : .medium))
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .tint(selected ? Color.accentColor : .primary)
            .disabled(changesDisabled || selected || selection == nil)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }

        private func refresh(force: Bool) async {
            guard !refreshing, !changing, unavailableReason == nil else { return }
            refreshing = true
            readError = nil
            defer { refreshing = false }
            do {
                let value = try await request(.init(workspacePane: captured.pane, refresh: force))
                try Task.checkCancellation()
                snapshot = value
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                readError = error.localizedDescription
            }
        }

        private func change(_ selection: AgentModelSelection) {
            guard !changesDisabled, let snapshot else { return }
            changing = true
            Task {
                defer { changing = false }
                do {
                    _ = try await request(.init(
                        workspacePane: captured.pane, runtimeID: snapshot.runtimeID,
                        selection: selection, expectedSelection: snapshot.selection
                    ))
                    try Task.checkCancellation()
                    close()
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled else { return }
                    changeError = error.localizedDescription
                }
            }
        }
    }
#endif
