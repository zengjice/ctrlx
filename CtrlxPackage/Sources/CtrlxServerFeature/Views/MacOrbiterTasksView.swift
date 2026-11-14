import CtrlxCommon
import CtrlxNetworking
import SwiftUI

@MainActor
struct MacOrbiterTasksView: View {
    @Bindable var service: OrbiterService
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var selectedID: UUID?
    @State private var query = ""
    @State private var period = 0
    @State private var showsArchived = false
    @State private var creation: NewAgentTabConfiguration?
    @State private var forkAgent: SessionLaunchAgent?
    @State private var forkProvider: String?
    @State private var showsAssociation = false
    @State private var confirmsReconnect = false
    @State private var notice: String?

    private var selected: OrbiterTask? {
        service.tasks.first { $0.id == selectedID }
    }

    private var filteredTasks: [OrbiterTask] {
        service.tasks.filter { task in
            let cutoff = Calendar.current.date(byAdding: .day, value: period == 1 ? 0 : -6, to: Calendar.current.startOfDay(for: Date())) ?? .distantPast
            return task.archived == showsArchived && (period == 0 || task.createdAt >= cutoff)
                && (query.isEmpty || "\(task.title) \(task.directory) \(task.source) \(task.createdAt.formatted(date: .numeric, time: .omitted))".localizedStandardContains(query))
        }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Orbiter Tasks").font(.title2.bold())
                Spacer()
                Text("\(service.activeCount)/2 active").foregroundStyle(.secondary)
                Button { Task { await service.refresh() } } label: { Label("Refresh", symbol: .arrowClockwise) }.labelStyle(.iconOnly).disabled(service.isBusy)
                Button { dismiss() } label: { Label("Close", symbol: .xmark) }.labelStyle(.iconOnly).keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
            HSplitView {
                VStack(alignment: .leading) {
                    TextField("Find by task or project", text: $query).accessibilityIdentifier("orbiter-search")
                    Picker("Created", selection: $period) {
                        Text("Any time").tag(0)
                        Text("Today").tag(1)
                        Text("Last 7 days").tag(2)
                    }
                    Toggle("Archived", isOn: $showsArchived)
                    List(selection: $selectedID) {
                        ForEach(filteredTasks) { task in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title).font(.headline)
                                Text(task.directory).font(.caption).lineLimit(1).truncationMode(.middle)
                                Text(task.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            }.tag(task.id)
                        }
                    }
                    Button("New Task…") { selectedID = nil }.disabled(service.isBusy).accessibilityIdentifier("orbiter-new")
                }.padding().frame(minWidth: 220, idealWidth: 240, maxWidth: 300)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let issue = service.issue {
                            Text(issue).foregroundStyle(.red).textSelection(.enabled)
                        }
                        if let notice {
                            Text(notice).textSelection(.enabled)
                        }
                        if let task = selected {
                            details(task)
                        } else {
                            draftForm
                        }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 400)
            }
        }
        .frame(minWidth: 740, idealWidth: 860, minHeight: 620, idealHeight: 700)
        .task {
            await service.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                if creation == nil, forkAgent == nil, !showsAssociation {
                    await service.refresh()
                }
            }
        }
        .task(id: service.draft) { await saveDraftAfterEditing() }
        .task(id: service.taskDrafts) { await saveDraftAfterEditing() }
        .onDisappear { Task { await service.saveDrafts() } }
        .sheet(item: $creation) {
            NewAgentTabPanel(configuration: $0, destinationDescription: "Create an independent Agent with only the goal, source and selected materials. Choose its actual project directory.")
                .disabled(service.isBusy)
        }
        .sheet(item: $forkAgent) { agent in forkForm(agent) }
        .sheet(isPresented: $showsAssociation) { associationForm }
        .confirmationDialog("Reconnect this task to the current Agent?", isPresented: $confirmsReconnect) {
            Button("Reconnect") { perform {
                if let selectedID {
                    try await service.reconnect(selectedID)
                }
            } }
        } message: { Text("Confirm the original conversation in its tab first. Reconnecting does not resend a task. Use the existing Resume or Use Shell controls to recover the Agent.") }
    }

    private var draftForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Task").font(.title2.bold())
            TextField("Short task name", text: $service.draft.title).accessibilityIdentifier("orbiter-title")
            Text("Goal").font(.headline)
            TextEditor(text: $service.draft.goal).frame(height: 100).border(.quaternary).accessibilityLabel("Task goal").accessibilityIdentifier("orbiter-goal")
            TextField("Project directory", text: $service.draft.directory).accessibilityIdentifier("orbiter-directory")
            Text("The Agent runs in this project. Task materials have a separate directory.").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Source and selected materials") {
                TextField("Source (optional)", text: $service.draft.source)
                TextEditor(text: $service.draft.materials).frame(height: 100).border(.quaternary).accessibilityLabel("Selected materials")
            }
            HStack {
                Button("New Agent…") { prepareNew() }.accessibilityIdentifier("orbiter-create-new")
                Button("Fork Orbie…") { prepareFork() }.accessibilityIdentifier("orbiter-create-fork")
            }.disabled(service.isBusy)
            Button("Associate Existing Agent…") { showsAssociation = true }
            if service.tasks.contains(where: { $0.id == service.draft.id }) {
                Text("This draft already has a task record. Select that task to check its existing tab.").foregroundStyle(.secondary)
                Button("Start Another Draft") { service.draft = OrbiterDraft() }
            }
        }.textFieldStyle(.roundedBorder).disabled(service.isOperating)
    }

    private func details(_ task: OrbiterTask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(task.title).font(.title2.bold())
            Text(task.directory).font(.caption).textSelection(.enabled)
            Text("\(task.origin.rawValue) · \(task.pluginID) · \(task.providerID ?? "Current CLI configuration")").font(.caption).foregroundStyle(.secondary)
            Text(task.goal).textSelection(.enabled)
            if let reason = service.availability(task) {
                Text(reason).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Button("Open Agent Tab") { perform { try await openTerminal(task) } }.accessibilityIdentifier("orbiter-open-agent")
                Menu("More") {
                    Button("Reconnect…") { confirmsReconnect = true }
                    Button("Associate Existing Agent…") { showsAssociation = true }
                    Button(task.archived ? "Unarchive" : "Archive") { perform { try await service.setArchived(task.id, !task.archived) } }
                    Button("Show Materials in Finder") { NSWorkspace.shared.activateFileViewerSelecting([service.materialDirectory(task)]) }
                    if task.pendingRunID != nil {
                        Button("Keep Draft and Clear Unstarted Request") { perform { try await service.clearUnstartedRequest(task.id) } }
                    }
                }
            }
            Divider()
            ForEach(service.executions(task)) { run in
                VStack(alignment: .leading, spacing: 6) {
                    Text(run.createdAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                    ForEach(OrbiterStore.reports(in: run).map(\.1)) { result in
                        Text("Agent report").font(.headline)
                        Text(result.text).textSelection(.enabled)
                        Text("A verified reply is not independent verification of the goal.").font(.caption).foregroundStyle(.secondary)
                        Button("Give to Orbie for Summary") { stageReport(task, run: run, result: result) }
                    }
                    if !run.status.isTerminal {
                        Text(run.issue ?? "Waiting for a verified native final reply…").foregroundStyle(.secondary)
                        Button("Stop Further Delivery") { perform { try await service.end(run) } }
                    }
                }
            }
            Text("Follow-up").font(.headline)
            TextEditor(text: Binding(get: { service.taskDrafts[task.id] ?? task.draft }, set: { service.taskDrafts[task.id] = $0 }))
                .frame(height: 110).border(.quaternary).accessibilityLabel("Task follow-up").accessibilityIdentifier("orbiter-followup")
            Button("Send to Agent") { perform { try await service.send(task.id) } }
                .buttonStyle(.borderedProminent).disabled(service.isBusy || service.availability(task) != nil).accessibilityIdentifier("orbiter-send")
        }.disabled(service.isOperating)
    }

    private func forkForm(_ agent: SessionLaunchAgent) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Fork Orbie").font(.headline)
                Spacer()
                Button { forkAgent = nil } label: { Label("Close", symbol: .xmark) }.labelStyle(.iconOnly)
            }
            Text("Use Orbie’s verified native conversation as the starting context. Orbie must be ready. A different Agent type requires New Agent.")
            TextField("Project directory", text: $service.draft.directory)
                .accessibilityLabel("Fork project directory").accessibilityIdentifier("orbiter-fork-directory")
            Picker("Provider", selection: $forkProvider) {
                Text("Current CLI configuration").tag(String?.none)
                ForEach(agent.providers) { provider in Text(provider.name).tag(Optional(provider.id)) }
            }
            if let notice {
                Text(notice).foregroundStyle(.red)
            }
            Button("Fork \(agent.name)") {
                perform {
                    selectedID = try await service.create(pluginID: agent.id, providerID: forkProvider, fork: true)
                    forkAgent = nil
                }
            }.buttonStyle(.borderedProminent).disabled(service.isBusy)
        }.padding(24).frame(width: 480).disabled(service.isOperating).interactiveDismissDisabled(service.isOperating)
    }

    private var associationForm: some View {
        let orbie = coordinator.orbie?.record?.currentInstance(in: service.instances)
        return VStack(alignment: .leading) {
            HStack {
                Text("Associate Existing Agent").font(.headline)
                Spacer()
                Button { showsAssociation = false } label: { Label("Close", symbol: .xmark) }.labelStyle(.iconOnly)
            }
            Text("Choose the exact Agent. This records a binding; it does not send the task or resume a process.")
            List(service.instances.filter { $0.capabilities != nil && $0.id != orbie?.id }) { instance in
                Button {
                    perform {
                        selectedID = try await service.associate(instance, with: selectedID)
                        showsAssociation = false
                    }
                } label: { VStack(alignment: .leading) {
                    Text(instance.displayName)
                    Text("\(instance.pluginID) · \(instance.workingDirectory) · \(instance.paneID)").font(.caption)
                } }
            }
            if let notice {
                Text(notice).foregroundStyle(.red)
            }
        }.padding().frame(width: 560, height: 400).disabled(service.isOperating)
    }

    private func prepareNew() {
        perform {
            try service.draft.validate()
            guard let hostID = service.index?.hostID else { throw AgentWorkflowError("The task index is not loaded.") }
            let options = try await coordinator.workflowAgentCreation(hostID: hostID)
            creation = .init(id: .init(hostID: "local", sessionName: service.draft.title), initialDirectory: service.draft.directory, agents: options.agents.filter { ["codex", "claude-code"].contains($0.id) }, directorySource: options.directorySource, unavailableReason: nil) { request in
                guard let pluginID = request.pluginID else { throw AgentWorkflowError("Choose an Agent.") }
                service.draft.directory = request.workingDirectory ?? service.draft.directory
                let taskID = service.draft.id
                do {
                    selectedID = try await service.create(pluginID: pluginID, providerID: request.providerID)
                    creation = nil
                } catch {
                    if service.tasks.contains(where: { $0.id == taskID }) {
                        selectedID = taskID
                        creation = nil
                    }
                    throw error
                }
            }
        }
    }

    private func prepareFork() {
        perform {
            try service.draft.validate()
            await coordinator.orbie?.refresh()
            guard
                coordinator.orbie?.availability == nil, let pluginID = coordinator.orbie?.instance?.pluginID,
                let agent = coordinator.localAgentLaunchAgents().first(where: { $0.id == pluginID }) else { throw AgentWorkflowError("Wait for Orbie’s verified conversation, or choose New Agent.") }
            forkProvider = nil
            forkAgent = agent
        }
    }

    private func stageReport(_ task: OrbiterTask, run: AgentWorkflowRun, result: AgentWorkflowResult) {
        perform {
            guard let orbie = coordinator.orbie else { throw AgentWorkflowError("Orbie is unavailable.") }
            let report = "Summarize this Agent report and identify any unverified claims or next steps.\nTask: \(task.title) (\(task.id))\nProject: \(task.directory)\nWorkflow: \(run.id)\nInvocation: \(result.invocationID)\nFull report: \(service.materialDirectory(task).appendingPathComponent("RESULT.md").path)\n\n\(String(result.text.prefix(6_000)))"
            try await orbie.stageReport(report)
            notice = "Report added to the Orbie draft. Review it and press Send when Orbie is ready."
        }
    }

    private func saveDraftAfterEditing() async {
        do { try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
        } catch { return }
        await service.saveDrafts()
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        notice = nil
        Task { do { try await operation() } catch { notice = error.localizedDescription } }
    }

    private func openTerminal(_ task: OrbiterTask) async throws {
        try await coordinator.openOrbiterTask(task.id, openWindow: openWindow)
    }
}
