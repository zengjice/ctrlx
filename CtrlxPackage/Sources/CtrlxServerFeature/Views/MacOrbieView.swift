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
        @State private var showsTasks = false

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
                                await orbie.refresh(inspect: orbie.canRestore || orbie.isRestoring || (orbie.record?.creation != nil && !orbie.hasPendingMessage && orbie.availability != nil))
                            }
                        }
                } else {
                    Text(coordinator.agentWorkflowStartupError ?? "Orbie is waiting for this Mac’s Agent services.")
                        .foregroundStyle(.secondary).padding()
                }
            }
            .frame(minWidth: 520, minHeight: 480)
            .sheet(item: $creation) { NewAgentTabPanel(configuration: $0, destinationDescription: "Create Orbie on this Mac. Its Agent and Provider use the normal launch settings.") }
            .sheet(isPresented: $showsTasks) {
                if let orbiters = coordinator.orbiters {
                    MacOrbitersView(service: orbiters)
                }
            }
            .onChange(of: coordinator.showsOrbitersRequested, initial: true) { _, requested in
                if requested {
                    showsTasks = true
                    coordinator.showsOrbitersRequested = false
                }
            }
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
        }

        private func content(_ orbie: OrbieService) -> some View {
            @Bindable var orbie = orbie
            return VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Orbie", symbol: .sparkles).font(.title2.bold())
                    Spacer()
                    Button("Orbiters…") { showsTasks = true }
                        .disabled(coordinator.orbiters == nil).accessibilityIdentifier("orbie-tasks")
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
                        if orbie.canRestore {
                            AgentRoleResumeButton(tabClosed: orbie.tabClosed) { Task { await orbie.restoreOriginalConversation() } }.disabled(orbie.isBusy)
                        }
                        Button("Open Agent Tab") { Task { await openTerminal(orbie) } }.disabled(orbie.tabClosed)
                            .accessibilityIdentifier("orbie-open-agent")
                        Menu("More") {
                            Button("Set Up Again…") { confirmsRebuild = true }
                                .disabled(orbie.isBusy)
                        }
                    }
                    if orbie.record?.pendingMessageID != nil {
                        Button("Keep Draft and Clear Unstarted Request") { Task { await orbie.reviewUnstartedRequest() } }
                            .disabled(orbie.isBusy)
                    }
                }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if let legacyIssue = orbie.legacyIssue {
                            Text(legacyIssue).foregroundStyle(.secondary)
                        }
                        HStack {
                            if let older = orbie.historyPage.olderPageEndID {
                                Button("Earlier Messages") { Task { await orbie.loadHistory(endingAt: older) } }
                            }
                            Spacer()
                            if let newer = orbie.historyPage.newerPageEndID {
                                Button("Newer Messages") { Task { await orbie.loadHistory(endingAt: newer) } }
                                Button("Latest Messages") { Task { await orbie.loadHistory(endingAt: nil) } }
                            }
                        }.disabled(orbie.isBusy)
                        ForEach(orbie.historyPage.messages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.text).font(.headline)
                                if let answer = message.answer {
                                    Text(answer).textSelection(.enabled)
                                } else {
                                    Text(message.issue ?? (message.status == .cancelled ? "Stopped. Check the Agent tab for any work already in progress." : "Waiting for a verified reply…"))
                                        .foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                if let attachments = message.attachments, !attachments.isEmpty {
                                    Button("Show Saved Attachments") { NSWorkspace.shared.activateFileViewerSelecting(attachments.map { URL(fileURLWithPath: $0.path) }) }
                                }
                                if message.isPending {
                                    Button("Stop Waiting") { Task { await orbie.endMessage(message) } }.disabled(orbie.isBusy)
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
                        agents: options.agents.filter { ["codex", "claude-code", "traex"].contains($0.id) },
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
            do { try await coordinator.openOrbieTerminal(openWindow: openWindow) }
            catch { self.error = error.localizedDescription }
        }
    }
#endif
