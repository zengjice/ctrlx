import CtrlxCommon
import CtrlxNetworking
import SwiftUI

@MainActor
struct MacOrbitersView: View {
    @Bindable var service: OrbiterService
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var selectedID: String?
    @State private var query = ""
    @State private var creation: NewAgentTabConfiguration?
    @State private var forkAgent: SessionLaunchAgent?
    @State private var forkProvider: String?
    @State private var showsAssociation = false
    @State private var notice: String?
    @State private var files: AgentMaterialFiles?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Orbiters").font(.title2.bold())
                Spacer()
                Button("Workflows…") { openWindow(id: "workflows") }
                Button { Task { await service.refresh() } } label: { Label("Refresh", symbol: .arrowClockwise) }.labelStyle(.iconOnly)
                Button { dismiss() } label: { Label("Close", symbol: .xmark) }.labelStyle(.iconOnly).keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
            HSplitView {
                VStack(alignment: .leading) {
                    TextField("Find Agent or project", text: $query).accessibilityIdentifier("orbiter-search")
                    List(selection: $selectedID) {
                        ForEach(service.agents.filter { query.isEmpty || "\($0.title) \($0.directory)".localizedStandardContains(query) }) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.title).font(.headline)
                                Text(record.directory).font(.caption).lineLimit(1).truncationMode(.middle)
                                Text(record.agentID.map { service.restoringAgents.contains($0) } == true ? "Restoring…" : service.currentInstance(record)?.readiness.rawValue ?? "Unavailable").font(.caption).foregroundStyle(.secondary)
                            }.tag(record.id)
                        }
                    }
                    Button("New Orbiter…") { selectedID = nil }.disabled(service.isBusy)
                }.padding().frame(minWidth: 220, maxWidth: 300)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let issue = service.issue {
                            Text(issue).foregroundStyle(.red).textSelection(.enabled)
                        }
                        if let notice {
                            Text(notice).textSelection(.enabled)
                        }
                        if let record = service.agents.first(where: { $0.id == selectedID }) {
                            details(record)
                        } else {
                            draftForm
                        }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 400)
            }
        }.frame(minWidth: 740, minHeight: 620)
            .task {
                while !Task.isCancelled {
                    await service.refresh()
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
            .task(id: selectedID) {
                service.historyAgentID = selectedID
                await service.refresh(inspect: false)
            }
            .onChange(of: service.historyAgentID) { _, id in selectedID = id }
            .task(id: service.draft) { await saveDraftAfterEditing() }
            .task(id: service.drafts) { await saveDraftAfterEditing() }
            .onDisappear { Task { await service.saveDrafts() } }
            .sheet(item: $files) { AgentMaterialFilesView(files: $0) }
            .sheet(item: $creation) { NewAgentTabPanel(configuration: $0, destinationDescription: "Create an independent Agent. Choose its project directory.") }
            .sheet(item: $forkAgent) { agent in
                VStack(alignment: .leading, spacing: 12) {
                    Text("Fork Orbie").font(.headline)
                    Picker("Provider", selection: $forkProvider) {
                        Text("Current CLI configuration").tag(String?.none)
                        ForEach(agent.providers) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Button("Fork \(agent.name)") { perform {
                        selectedID = try await service.create(pluginID: agent.id, providerID: forkProvider, fork: true)
                        forkAgent = nil
                    } }.disabled(service.isBusy)
                }.padding(24).frame(width: 480)
            }
            .sheet(isPresented: $showsAssociation) {
                VStack {
                    Text("Associate Existing Agent").font(.headline)
                    List(service.instances.filter { $0.capabilities != nil && $0.agentID != coordinator.orbie?.instance?.agentID }) { instance in
                        Button(instance.displayName) { perform {
                            selectedID = try await service.associate(instance)
                            showsAssociation = false
                        } }
                    }
                    Button("Close") { showsAssociation = false }
                }.padding().frame(width: 560, height: 400)
            }
    }

    private var draftForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Orbiter").font(.title2.bold())
            TextField("Agent name", text: $service.draft.title).accessibilityIdentifier("orbiter-title")
            Text("Initial message").font(.headline)
            TextEditor(text: $service.draft.goal).accessibilityIdentifier("orbiter-goal").frame(height: 100).border(.quaternary)
            TextField("Project directory", text: $service.draft.directory)
            DisclosureGroup("Source and selected materials") {
                TextField("Source (optional)", text: $service.draft.source)
                TextEditor(text: $service.draft.materials).frame(height: 100).border(.quaternary)
            }
            HStack {
                Button("New Agent…") { prepareNew() }.accessibilityIdentifier("orbiter-create-new")
                Button("Fork Orbie…") { prepareFork() }.accessibilityIdentifier("orbiter-create-fork")
            }.disabled(service.isBusy)
            Button("Associate Existing Agent…") { showsAssociation = true }
            if service.agents.contains(where: { $0.creation?.id == service.draft.id }) {
                Text("This creation is already recorded. Select the existing Agent to check its tab.").foregroundStyle(.secondary)
                Button("Start Another Draft") { service.draft = OrbiterDraft() }
            }
        }.textFieldStyle(.roundedBorder)
    }

    private func details(_ record: OrbiterRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(record.title).font(.title2.bold())
            Text(record.directory).font(.caption).textSelection(.enabled)
            if record.legacyRunIDs?.isEmpty == false {
                Text("Some older records remain in Workflows for review. Their messages and materials have not been deleted.").foregroundStyle(.secondary)
            }
            if let reason = service.availability(record) {
                Text(reason).foregroundStyle(.secondary)
            }
            HStack {
                if let agentID = record.agentID, service.currentInstance(record) == nil {
                    if !service.restoringAgents.contains(agentID) {
                        AgentRoleResumeButton(tabClosed: service.closedAgents.contains(agentID)) { perform { try await service.restoreOriginalConversation(record.id) } }.disabled(service.isBusy)
                    }
                    Button("New Agent Instead…") { selectedID = nil }
                }
                Button("Open Agent Tab") { perform { try await coordinator.openOrbiter(record.id, openWindow: openWindow) } }.disabled(record.agentID.map { service.closedAgents.contains($0) } ?? true)
                if !record.materialsDirectories.isEmpty {
                    Menu("Open Materials") {
                        ForEach(record.materialsDirectories, id: \.self) { path in
                            Button(path) { files = .init(directory: path) }
                        }
                    }
                }
            }
            Divider()
            HStack {
                if let older = service.historyPage.olderPageEndID {
                    Button("Earlier Messages") { Task { await service.loadHistory(endingAt: older) } }
                }
                Spacer()
                if let newer = service.historyPage.newerPageEndID {
                    Button("Newer Messages") { Task { await service.loadHistory(endingAt: newer) } }
                    Button("Latest Messages") { Task { await service.loadHistory(endingAt: nil) } }
                }
            }.disabled(service.isBusy)
            ForEach(service.history(record)) { message in
                Text(message.text).font(.headline).textSelection(.enabled)
                if let answer = message.answer {
                    Text(answer).textSelection(.enabled)
                    Button("Give to Orbie…") { perform {
                        guard let orbie = coordinator.orbie else { throw AgentWorkflowError("Orbie is unavailable.") }
                        try await orbie.stageReport("Summarize this Agent reply and identify unverified claims.\nAgent: \(record.title)\n\n" + OrbieAgentCatalog.bounded(answer, bytes: 6_000))
                        notice = "Reply added to Orbie’s draft. Review it before sending."
                    } }
                } else {
                    Text(message.issue ?? "Waiting for a verified reply…").foregroundStyle(.secondary)
                }
                if let attachments = message.attachments, !attachments.isEmpty {
                    Menu("Open Saved Attachments") {
                        ForEach(attachments, id: \.path) { attachment in
                            Button(URL(fileURLWithPath: attachment.path).lastPathComponent) {
                                files = .init(directory: URL(fileURLWithPath: attachment.path).deletingLastPathComponent().path, reveal: attachment.path)
                            }
                        }
                    }
                }
                if message.isPending {
                    Button("Stop Waiting") { perform { try await service.stopWaiting(message) } }
                }
            }
            TextEditor(text: Binding(get: { service.drafts[record.id] ?? record.draft }, set: { service.drafts[record.id] = $0 })).frame(height: 100).border(.quaternary)
            Button("Send") { perform { try await service.send(record.id) } }.disabled(service.isBusy || service.availability(record) != nil)
        }
    }

    private func prepareNew() {
        perform {
            try service.draft.validate()
            guard let hostID = service.index?.hostID else { throw AgentWorkflowError("Orbiters have not loaded yet.") }
            let options = try await coordinator.workflowAgentCreation(hostID: hostID)
            creation = .init(
                id: .init(hostID: "local", sessionName: service.draft.title),
                initialDirectory: service.draft.directory,
                agents: options.agents.filter { ["codex", "claude-code"].contains($0.id) },
                directorySource: options.directorySource,
                unavailableReason: nil
            ) { request in
                guard let pluginID = request.pluginID else { throw AgentWorkflowError("Choose an Agent.") }
                service.draft.directory = request.workingDirectory ?? service.draft.directory
                selectedID = try await service.create(pluginID: pluginID, providerID: request.providerID)
                creation = nil
            }
        }
    }

    private func prepareFork() {
        perform {
            try service.draft.validate()
            await coordinator.orbie?.refresh()
            guard
                coordinator.orbie?.availability == nil, let pluginID = coordinator.orbie?.instance?.pluginID,
                let agent = coordinator.localAgentLaunchAgents().first(where: { $0.id == pluginID }) else {
                throw AgentWorkflowError("Wait for Orbie’s verified conversation, or choose New Agent.")
            }
            forkProvider = nil
            forkAgent = agent
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
}

private struct AgentMaterialFiles: Identifiable {
    let id = UUID()
    let directory: String
    var reveal: String?
}

@MainActor
private struct AgentMaterialFilesView: View {
    let files: AgentMaterialFiles
    @Environment(\.dismiss) private var dismiss
    @State private var browser = FileBrowserState()
    @State private var tabs = SessionFileTabsState()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(files.directory).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
            FileBrowserView(directoryPath: files.directory, state: browser, sessionTabs: tabs) { path in
                browser.pendingRevealPath = path
            }
        }.frame(minWidth: 800, minHeight: 600)
            .task { browser.pendingRevealPath = files.reveal }
    }
}
