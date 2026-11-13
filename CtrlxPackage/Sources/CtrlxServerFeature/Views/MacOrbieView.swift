#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftUI

    @MainActor
    public struct MacOrbieView: View {
        @Environment(AppCoordinator.self) private var coordinator
        @Environment(\.openWindow) private var openWindow
        @State private var creation: NewAgentTabConfiguration?
        @State private var error: String?
        @State private var confirmsRebuild = false
        @State private var confirmsReconnect = false

        public init() { }

        public var body: some View {
            Group {
                if let orbie = coordinator.orbie {
                    content(orbie)
                        .task {
                            await orbie.refresh()
                            while !Task.isCancelled {
                                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                                // While this window is open, startup and human-owned
                                // input can become ready without a manual refresh.
                                // In-flight answers only read the existing ledger.
                                await orbie.refresh(inspect: orbie.record?.creation != nil && !orbie.hasActiveRun && orbie.availability != nil)
                            }
                        }
                } else {
                    Text(coordinator.agentWorkflowStartupError ?? "Orbie is waiting for this Mac’s Agent services.")
                        .foregroundStyle(.secondary).padding()
                }
            }
            .frame(minWidth: 520, minHeight: 480)
            .sheet(item: $creation) { NewAgentTabPanel(configuration: $0, destinationDescription: "Create Orbie on this Mac. Its Agent and Provider use the normal launch settings.") }
            .alert("Could not open Orbie", isPresented: Binding(get: { error != nil }, set: {
                if !$0 {
                    error = nil
                }
            })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
            .confirmationDialog("Detach the old Orbie binding?", isPresented: $confirmsRebuild) {
                Button("Set Up Orbie Again") { Task { await coordinator.orbie?.resetBinding() } }
            } message: { Text("The existing Agent, messages and files will be kept. You can explicitly create a new Orbie afterward.") }
            .confirmationDialog("Use the current Agent as Orbie?", isPresented: $confirmsReconnect) {
                Button("Reconnect") { Task { await coordinator.orbie?.reconnect() } }
            } message: { Text("Confirm the conversation in its terminal first. Reconnecting does not resend any previous message.") }
        }

        private func content(_ orbie: OrbieService) -> some View {
            @Bindable var orbie = orbie
            return VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Orbie", symbol: .sparkles).font(.title2.bold())
                    Spacer()
                    if let record = orbie.record {
                        Toggle("Enabled on this Mac", isOn: Binding(get: { record.enabled }, set: { value in Task { await orbie.setEnabled(value) } }))
                            .toggleStyle(.switch).disabled(orbie.isBusy)
                    }
                    Button { Task { await orbie.refresh() } } label: { Label("Refresh", symbol: .arrowClockwise) }
                        .labelStyle(.iconOnly).disabled(orbie.isBusy)
                }
                if let issue = orbie.issue {
                    Text(issue).foregroundStyle(.red).textSelection(.enabled)
                }
                if let availability = orbie.availability {
                    Text(availability).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    if orbie.record?.creation == nil {
                        Button("Create Orbie…") { prepareCreation(orbie) }.disabled(orbie.record == nil || orbie.isBusy)
                            .accessibilityIdentifier("orbie-create")
                    } else {
                        Button("Open Agent Tab") { Task { await openTerminal(orbie) } }
                            .disabled(orbie.isBusy)
                            .accessibilityIdentifier("orbie-open-agent")
                        if let instance = orbie.instance, orbie.record?.binding?.matchesBinding(instance) == false {
                            Button("Reconnect…") { confirmsReconnect = true }.disabled(orbie.hasActiveRun || orbie.isBusy)
                        }
                        Menu("More") {
                            Button("Set Up Again…") { confirmsRebuild = true }
                                .disabled(orbie.isBusy || orbie.hasActiveRun || orbie.record?.pendingRunID != nil)
                        }
                    }
                    if orbie.record?.pendingRunID != nil {
                        Button("Keep Draft and Clear Unstarted Request") { Task { await orbie.reviewUnstartedRequest() } }
                            .disabled(orbie.isBusy)
                    }
                }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(orbie.runs) { run in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(run.definition.initialInput.text).font(.headline)
                                if let result = run.invocations.last?.result {
                                    Text(result.text).textSelection(.enabled)
                                } else {
                                    Text(run.issue ?? (run.status == .ended ? "Stopped. Check the Agent tab for any work already in progress." : "Waiting for a verified reply…"))
                                        .foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                if !run.status.isTerminal {
                                    Button("Stop Further Delivery") { Task { await orbie.endMessage(run) } }.disabled(orbie.isBusy)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                TextEditor(text: $orbie.draft)
                    .font(.body).frame(minHeight: 72, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .disabled(orbie.isBusy)
                    .accessibilityLabel("Message to Orbie").accessibilityIdentifier("orbie-draft")
                HStack {
                    Text("Questions and approvals stay in the Agent tab.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Send") { Task { await orbie.send() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(orbie.isBusy || orbie.availability != nil || orbie.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("orbie-send")
                }
            }.padding()
        }

        private func prepareCreation(_ orbie: OrbieService) {
            guard let record = orbie.record else { return }
            Task {
                do {
                    let options = try await coordinator.workflowAgentCreation(hostID: record.hostID)
                    creation = NewAgentTabConfiguration(
                        id: .init(hostID: "local", sessionName: "Orbie"), initialDirectory: orbie.directory,
                        agents: options.agents.filter { ["codex", "claude-code"].contains($0.id) },
                        directorySource: options.directorySource, unavailableReason: nil, allowsDirectorySelection: false
                    ) { request in
                        guard let pluginID = request.pluginID else { throw AgentWorkflowError("Choose an Agent.") }
                        try await orbie.create(pluginID: pluginID, providerID: request.providerID)
                        creation = nil
                    }
                } catch { self.error = error.localizedDescription }
            }
        }

        private func openTerminal(_ orbie: OrbieService) async {
            let panes = await coordinator.tmuxService.refreshPanes()
            coordinator.windowManager.updatePaneStates(from: panes)
            await orbie.refresh()
            guard let record = orbie.record else { return }
            let target = record.binding?.target ?? record.creation?.pane.map {
                AgentWorkflowTarget(hostID: record.hostID, windowID: $0.windowID, paneID: $0.paneID)
            }
            guard
                let target,
                let pane = coordinator.windowManager.paneStates.values.first(where: {
                    $0.workspaceIdentity?.paneID == target.paneID && $0.workspaceIdentity?.windowID == target.windowID
                }) else {
                error = "Orbie’s terminal is unavailable. Open the workspace and use its existing recovery controls, or explicitly set up Orbie again."
                return
            }
            coordinator.detachedWindows.sourcePaneRequest = .init(hostID: nil, pane: pane)
            let owner = coordinator.detachedWindows.owner(hostID: nil, windowID: pane.stableWindowId)
            if !coordinator.detachedWindows.focusNativeWindow(workspaceID: owner) {
                if let owner {
                    openWindow(id: "detached-terminal", value: owner)
                } else {
                    openWindow(id: "panes")
                }
            }
        }
    }
#endif
