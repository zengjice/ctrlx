import CtrlxCommon
import CtrlxNetworking
import SwiftUI

@MainActor
struct MacOrbitersView: View {
    enum CreationSource: Hashable, Sendable {
        case newConversation
        case fork
        case existingConversation
    }

    @Bindable var service: OrbiterService
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var selectedID: String?
    @State private var query = ""
    @State private var creationSource: CreationSource
    @State private var engineID: String?
    @State private var providerID: String?
    @State private var forkProvider: String?
    @State private var selectedConversationID: UUID?
    @State private var showsDirectories = false
    @State private var isCreatingDirectory = false
    @State private var notice: String?
    @State private var files: AgentMaterialFiles?
    private let requestedForkSource: AgentWorkflowInstance?

    init(
        service: OrbiterService, initialSelection: String? = nil,
        initialSource: CreationSource = .newConversation, requestedForkSource: AgentWorkflowInstance? = nil
    ) {
        self.service = service
        _selectedID = State(initialValue: initialSelection)
        _creationSource = State(initialValue: initialSource)
        self.requestedForkSource = requestedForkSource
    }

    private var selectedRecord: OrbiterRecord? {
        service.agents.first { $0.id == selectedID }
    }

    private var engines: [SessionLaunchAgent] {
        coordinator.workflowAgentLaunchOptions().filter { ["codex", "claude-code", "traex"].contains($0.id) }
    }

    private var selectedEngine: SessionLaunchAgent? {
        let options = engines
        return options.first { $0.id == engineID }
            ?? options.first { $0.id == AgentLaunchDefaults.pluginID }
            ?? options.first
    }

    private var forkEngine: SessionLaunchAgent? {
        let pluginID = requestedForkSource?.pluginID ?? coordinator.orbie?.instance?.pluginID ?? coordinator.orbie?.record?.creation?.pluginID
        return coordinator.localAgentLaunchAgents().first { $0.id == pluginID }
    }

    private var availableConversations: [AgentWorkflowInstance] {
        let associated = Set(service.agents.compactMap(\.agentID) + [coordinator.orbie?.record?.target?.agentID].compactMap { $0 })
        return service.instances.filter { $0.capabilities != nil && !associated.contains($0.agentID) }
    }

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
                    TextField("Find Orbiter or project", text: $query).accessibilityIdentifier("orbiter-search")
                    List(selection: $selectedID) {
                        ForEach(service.agents.filter { query.isEmpty || "\($0.title) \($0.directory)".localizedStandardContains(query) }) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.title).font(.headline)
                                Text(record.directory).font(.caption).lineLimit(1).truncationMode(.middle)
                                Text(record.agentID.map { service.restoringAgents.contains($0) } == true ? "Restoring…" : service.currentInstance(record)?.readiness.rawValue ?? "Unavailable").font(.caption).foregroundStyle(.secondary)
                            }.tag(record.id)
                        }
                    }
                    if selectedRecord != nil {
                        Button("New Orbiter…") {
                            notice = nil
                            creationSource = .newConversation
                            selectedID = nil
                        }.accessibilityIdentifier("orbiter-new-draft")
                    }
                }.padding().frame(minWidth: 220, maxWidth: 300)
                VStack(alignment: .leading, spacing: 14) {
                    if let issue = service.issue {
                        Text(issue).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let notice {
                        Text(notice).textSelection(.enabled)
                    }
                    if let record = selectedRecord {
                        details(record)
                    } else {
                        ScrollView { draftForm }
                    }
                }.padding().frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    }

    private var draftForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Orbiter").font(.title2.bold())
            Picker("Source", selection: $creationSource) {
                Text("New Conversation").tag(CreationSource.newConversation)
                Text(requestedForkSource.map { "Fork \($0.displayName)" } ?? "Fork Orbie").tag(CreationSource.fork)
                Text("Use Existing Conversation").tag(CreationSource.existingConversation)
            }
            .accessibilityIdentifier("orbiter-source")
            .onChange(of: creationSource) { notice = nil }
            .disabled(isCreatingDirectory)

            if creationSource == .existingConversation {
                existingConversationForm
            } else {
                newConversationForm
            }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(service.isBusy)
        .onChange(of: selectedEngine?.id, initial: true) { providerID = selectedEngine?.initialProviderID }
        .onChange(of: forkEngine?.id) { forkProvider = nil }
    }

    private var newConversationForm: some View {
        let engine = creationSource == .fork ? forkEngine : selectedEngine
        let alreadyRecorded = service.agents.contains { $0.creation?.id == service.draft.id }
        return VStack(alignment: .leading, spacing: 12) {
            TextField("Orbiter name", text: $service.draft.title).accessibilityIdentifier("orbiter-title")
            Text("Initial message").font(.headline)
            TextEditor(text: $service.draft.goal).accessibilityIdentifier("orbiter-goal").frame(height: 100).border(.quaternary)
            TextField("Project directory", text: $service.draft.directory).accessibilityIdentifier("orbiter-directory")
            DisclosureGroup("Choose Directory…", isExpanded: $showsDirectories) {
                if showsDirectories {
                    SessionDirectoryBrowser(path: $service.draft.directory, source: coordinator.workflowAgentDirectorySource, isCreatingDirectory: $isCreatingDirectory)
                }
            }
            DisclosureGroup("Source and selected materials") {
                TextField("Source (optional)", text: $service.draft.source)
                TextEditor(text: $service.draft.materials).frame(height: 100).border(.quaternary)
            }
            launchOptions(engine)
            Button("Create Orbiter") {
                guard let engine else { return }
                let fork = creationSource == .fork
                let provider = fork ? forkProvider : providerID
                perform {
                    selectedID = try await service.create(pluginID: engine.id, providerID: provider, fork: fork, requestedSource: fork ? requestedForkSource : nil)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(engine == nil || isCreatingDirectory || alreadyRecorded)
            .accessibilityIdentifier("orbiter-create")
            if alreadyRecorded {
                Text("This creation is already recorded. Select the existing Orbiter to check its tab.").foregroundStyle(.secondary)
                Button("Start Another Draft") { service.draft = OrbiterDraft() }
            }
        }
    }

    @ViewBuilder
    private func launchOptions(_ engine: SessionLaunchAgent?) -> some View {
        if let engine {
            if creationSource == .fork {
                LabeledContent("Engine", value: engine.name)
                if !engine.providers.isEmpty {
                    providerPicker(engine, selection: $forkProvider, defaultLabel: "Current CLI configuration")
                }
            } else {
                Picker("Engine", selection: Binding(get: { selectedEngine?.id }, set: { engineID = $0 })) {
                    ForEach(engines) { Text($0.name).tag(Optional($0.id)) }
                }.accessibilityIdentifier("orbiter-engine")
                if !engine.providers.isEmpty {
                    providerPicker(engine, selection: $providerID, defaultLabel: engine.defaultProviderLabel)
                }
            }
        } else {
            Text(creationSource == .fork ? "A source conversation with a supported engine is required to fork." : "No supported engines are available. Check Settings → Agents.")
                .foregroundStyle(.secondary)
        }
    }

    private func providerPicker(_ engine: SessionLaunchAgent, selection: Binding<String?>, defaultLabel: String) -> some View {
        Picker("Provider", selection: selection) {
            Text(defaultLabel).tag(String?.none)
            ForEach(engine.providers) { Text($0.name).tag(Optional($0.id)) }
        }.accessibilityIdentifier("orbiter-provider")
    }

    private var existingConversationForm: some View {
        let options = availableConversations
        let selected = options.first { $0.id == selectedConversationID }
        return VStack(alignment: .leading, spacing: 12) {
            if options.isEmpty {
                Text("No conversations are available to add.").foregroundStyle(.secondary)
            } else {
                Picker("Conversation", selection: Binding(get: { selected?.id }, set: { selectedConversationID = $0 })) {
                    Text("Choose a conversation").tag(UUID?.none)
                    ForEach(options) { Text("\($0.displayName) · \($0.workingDirectory)").tag(Optional($0.id)) }
                }.accessibilityIdentifier("orbiter-conversation")
            }
            Button("Add to Orbiters") {
                guard let selected else { return }
                perform { selectedID = try await service.associate(selected) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected == nil)
            .accessibilityIdentifier("orbiter-associate")
        }
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
                }
                Button("Open Orbiter Tab") { perform { try await coordinator.openOrbiter(record.id, openWindow: openWindow) } }
                    .disabled(record.agentID.map { service.closedAgents.contains($0) } ?? true)
                    .accessibilityIdentifier("orbiter-open-tab")
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
            OrbieConversationView(messages: service.history(record), title: record.title, orbiterID: record.id, onStop: { message in
                perform { try await service.stopWaiting(message) }
            }, onGiveToOrbie: { message in
                perform {
                    guard let orbie = coordinator.orbie, let answer = message.answer else { throw AgentWorkflowError("Orbie is unavailable.") }
                    try await orbie.stageReport("Summarize this Orbiter reply and identify unverified claims.\nOrbiter: \(record.title)\n\n" + OrbieAgentCatalog.bounded(answer, bytes: 6_000))
                    notice = "Reply added to Orbie’s draft. Review it before sending."
                }
            })
            .id(record.id)
            .frame(minHeight: 240, maxHeight: .infinity)
            TextEditor(text: Binding(get: { service.drafts[record.id] ?? record.draft }, set: { service.drafts[record.id] = $0 })).frame(height: 100).border(.quaternary)
            Button("Send") { perform { try await service.send(record.id) } }.disabled(service.isBusy || service.availability(record) != nil)
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

struct AgentMaterialFiles: Identifiable {
    let id = UUID()
    let directory: String
    var reveal: String?
}

@MainActor
struct AgentMaterialFilesView: View {
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
