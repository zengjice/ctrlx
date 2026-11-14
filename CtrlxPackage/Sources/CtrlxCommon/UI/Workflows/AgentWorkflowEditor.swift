import CtrlxNetworking
import os
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import PhotosUI
#endif

@MainActor
struct AgentWorkflowEditor: View {
    let endpoint: AgentWorkflowEndpoint
    let isNew: Bool
    let createAgent: ((UUID) async throws -> AgentWorkflowAgentCreation)?
    private let expectedRevision: Int?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentWorkflowDefinition
    @State private var instances: [AgentWorkflowInstance] = []
    @State private var error: String?
    @State private var saving = false
    @State private var refreshing = false
    @State private var creation: AgentWorkflowAgentCreation?
    @State private var showingCreation = false
    @State private var loadingCreation = false
    @State private var createdAgent: AgentWorkflowCreatedAgent?
    @State private var attachments: [UUID: AgentWorkflowAttachment] = [:]
    @State private var importedIDs: Set<UUID> = []
    @State private var importing = false
    @State private var activeImport: AgentWorkflowImageImport?
    @State private var showingReviewTemplate = false
    @State private var showingAgentPicker = false
    @State private var choosingAgentFor: UUID?
    @State private var showingInitialTask = false
    @State private var showingAgents = false
    @State private var showingExecution = false
    @State private var expandedStepID: UUID?

    init(endpoint: AgentWorkflowEndpoint, definition: AgentWorkflowDefinition, isNew: Bool, createAgent: ((UUID) async throws -> AgentWorkflowAgentCreation)?) {
        self.endpoint = endpoint
        self.isNew = isNew
        self.createAgent = createAgent
        self.expectedRevision = isNew ? nil : definition.revision
        var editable = definition
        editable.participants = definition.agents
        for index in editable.nodes.indices {
            editable.nodes[index].initialTask = definition.initialTask(for: definition.nodes[index])
        }
        self._draft = State(initialValue: editable)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Workflow") {
                    TextField("Workflow name", text: $draft.name)
                    DisclosureGroup(isExpanded: expansion($showingInitialTask)) {
                        taskInput("Initial task", input: $draft.initialInput)
                        Text("Optional default task and attachments. You can also set the task when starting a run.")
                            .font(.caption).foregroundStyle(.secondary)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Saved initial task")
                                Spacer()
                                if !draft.initialInput.attachmentIDs.isEmpty {
                                    Text(draft.initialInput.attachmentIDs.count == 1 ? "1 image" : "\(draft.initialInput.attachmentIDs.count) images")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(inputSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.disclosureGroupStyle(AgentWorkflowEditorDisclosureStyle(id: "workflow-initial-task-toggle", disabled: importing))
                }
                if draft.nodes.isEmpty {
                    Section("Quick start") {
                        Button("Develop, review and repair…") { showingReviewTemplate = true }
                            .disabled(instances.count < 2)
                            .accessibilityIdentifier("workflow-review-template")
                        Text("Choose a Developer and a Reviewer. The template separates development, judgment and repair, and repeats from review.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    DisclosureGroup(isExpanded: expansion($showingAgents)) {
                        ForEach(draft.agents) { participant in
                            VStack(alignment: .leading, spacing: 8) {
                                Picker("Agent", selection: participantBinding(participant.id)) {
                                    ForEach(instances.filter { draft.participantID(for: $0, in: instances) == participant.id || draft.participantID(for: $0, in: instances) == nil }) { instance in
                                        Text(instance.displayName).tag(instance.id)
                                    }
                                    if draft.instance(for: participant.id, in: instances) == nil {
                                        Text("Agent unavailable · choose a replacement").tag(participant.id)
                                    }
                                }
                                Button("Remove Agent", role: .destructive) {
                                    draft.participants?.removeAll { $0.id == participant.id }
                                }.disabled(draft.nodes.contains { $0.agentInstanceID == participant.id })
                            }
                        }
                        Menu {
                            ForEach(instances.filter { draft.participantID(for: $0, in: instances) == nil }) { instance in
                                Button(instance.displayName) { draft.addAgent(instance, in: instances) }
                            }
                        } label: { Label("Add existing Agent", symbol: .plus) }
                        Button { Task { await refreshInstances() } } label: {
                            Label("Refresh Agents", symbol: .arrowClockwise)
                        }.disabled(refreshing)
                        Text("Each selection binds a specific Agent and conversation. Multiple steps can use the same Agent.")
                            .font(.caption).foregroundStyle(.secondary)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Participating Agents")
                            Text(draft.agents.isEmpty ? "Choose an Agent in each step, or add an Agent step." : draft.agents.map { agentName($0.id) }.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if draft.agents.contains(where: { draft.instance(for: $0.id, in: instances) == nil }), !refreshing {
                                Text("Some Agents are unavailable. Choose a replacement.").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }.disclosureGroupStyle(AgentWorkflowEditorDisclosureStyle(id: "workflow-agents-toggle", disabled: importing))
                }
                Section("Steps") {
                    if draft.nodes.isEmpty {
                        Text("Add a step below, or use the review template.").foregroundStyle(.secondary)
                    }
                    ForEach($draft.nodes) { $node in
                        DisclosureGroup(isExpanded: stepExpansion(node.id)) {
                            TextField("Step name", text: $node.name)
                                .accessibilityIdentifier("workflow-step-name-\(node.id)")
                            if node.kind == .agent {
                                if node.agentInstanceID == nil {
                                    Button("Choose Agent…") {
                                        choosingAgentFor = node.id
                                        showingAgentPicker = true
                                    }
                                    .accessibilityIdentifier("workflow-step-agent-\(node.id)")
                                } else {
                                    Picker("Agent", selection: Binding(get: { node.agentInstanceID }, set: { replacement in
                                        guard node.agentInstanceID != replacement else { return }
                                        node.agentInstanceID = replacement
                                        node.modelSelection = nil
                                    })) {
                                        ForEach(draft.agents) { participant in
                                            Text(agentName(participant.id)).tag(Optional(participant.id))
                                        }
                                        if !draft.agents.contains(where: { $0.id == node.agentInstanceID }) {
                                            Text("Choose a participating Agent").tag(node.agentInstanceID)
                                        }
                                    }.accessibilityIdentifier("workflow-step-agent-\(node.id)")
                                }
                                if let instance = draft.instance(for: node.agentInstanceID, in: instances) {
                                    if let issue = instance.capabilityIssue {
                                        Text(issue).font(.caption).foregroundStyle(.orange)
                                    } else if instance.readiness != .ready {
                                        Text(instance.readiness.title).font(.caption).foregroundStyle(.orange)
                                    }
                                }
                            } else {
                                Label("Content step", symbol: .docTextFill).font(.caption).foregroundStyle(.secondary)
                                Text("Prepares text and attachments without calling an Agent. Connect an Agent step to send this material.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            taskInput("Instructions or skill for this step", input: $node.input)
                            DisclosureGroup("More options") {
                                if node.kind == .agent {
                                    if let instance = draft.instance(for: node.agentInstanceID, in: instances) {
                                        Text(instance.displayName).font(.caption).foregroundStyle(.secondary)
                                        Text(instance.workingDirectory).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                    AgentWorkflowModelSettings(endpoint: endpoint, hostID: draft.hostID, instance: draft.instance(for: node.agentInstanceID, in: instances), selection: $node.modelSelection)
                                        .accessibilityIdentifier("workflow-model-\(node.id)")
                                }
                                NavigationLink(node.kind == .content ? "Preview output" : "Preview task input") {
                                    AgentWorkflowInputPreview(definition: draft, node: node, attachments: attachments)
                                }
                                if node.kind == .agent {
                                    Picker("Complete step", selection: $node.completion) {
                                        ForEach(AgentWorkflowNode.Completion.allCases, id: \.self) { Text($0.title).tag($0) }
                                    }
                                    if node.completion == .explicit {
                                        Text("Discussion can continue across replies. Downstream steps wait until the Agent explicitly completes this task.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Toggle("Allow this step to end the workflow", isOn: $node.allowsFinish)
                                    if node.allowsFinish {
                                        Text("Define when to finish in this step's instructions. This switch grants permission; it does not define the completion condition.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                DisclosureGroup("Wait for upstream steps") {
                                    ForEach(draft.nodes.filter { $0.id != node.id }) { source in
                                        Picker(stepTitle(source), selection: connection(from: source.id, to: node.id)) {
                                            ForEach(AgentWorkflowConnectionMode.allCases, id: \.self) { mode in
                                                Text(mode.rawValue).tag(mode)
                                            }
                                        }
                                    }
                                    Text("Always waits for all selected steps. Completion only sends no upstream text or attachments.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.disclosureGroupStyle(AgentWorkflowEditorDisclosureStyle(id: "workflow-step-upstream-\(node.id)", disabled: importing))
                                let targets = draft.nodes.filter { target in
                                    draft.edges.contains { $0.source == node.id && $0.target == target.id }
                                }
                                Text(targets.isEmpty ? "No downstream steps." : "Then: " + targets.map { stepTitle($0) }.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.disclosureGroupStyle(AgentWorkflowEditorDisclosureStyle(id: "workflow-step-options-\(node.id)", disabled: importing))
                        } label: {
                            stepSummary(node)
                        }
                        .disclosureGroupStyle(AgentWorkflowEditorDisclosureStyle(id: "workflow-step-toggle-\(node.id)", disabled: importing, remove: { remove(node.id) }))
                    }
                }
                Section {
                    Button { showingAgentPicker = true } label: { Label("Add Agent step", symbol: .plus) }
                        .accessibilityIdentifier("workflow-add-agent-step")
                    Button {
                        addNode(.init(name: "Content", content: .init(), initialTask: draft.nodes.isEmpty ? .textAndAttachments : .omit))
                    } label: { Label("Add content step", symbol: .docTextFill) }
                        .accessibilityIdentifier("workflow-add-content-step")
                    Text(draft.nodes.isEmpty ? "The first step receives the original task." : "Added after: " + draft.terminalSteps.map { stepTitle($0) }.joined(separator: ", ") + ". Receives their output; change upstream connections to branch.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if createAgent != nil {
                        Button("New Agent tab") { showingCreation = true }.disabled(createdAgent != nil)
                            .accessibilityIdentifier("workflow-new-agent-tab")
                    }
                    if createdAgent != nil {
                        Text("Agent created. Complete any setup in its terminal, then refresh Agents.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Choose another Agent") { createdAgent = nil }
                    }
                }
                .disabled(importing)
                if !draft.nodes.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showingExecution) {
                            Picker("First step", selection: $draft.entryNodeID) {
                                ForEach(draft.nodes) { Text(stepTitle($0)).tag($0.id) }
                            }
                            Toggle("Repeat rounds", isOn: Binding(get: { draft.loop != nil }, set: { enabled in
                                draft.loop = enabled ? .init(finalNodeID: draft.nodes.last?.id ?? draft.entryNodeID) : nil
                            })).accessibilityIdentifier("workflow-repeat-rounds")
                            Picker("Repeat from", selection: Binding(get: { draft.loop?.entryNodeID ?? draft.entryNodeID }, set: { value in
                                guard var loop = draft.loop else { return }
                                loop.entryNodeID = value
                                draft.loop = loop
                            })) {
                                ForEach(draft.nodes) { Text(stepTitle($0)).tag($0.id) }
                            }
                            .pickerStyle(.menu)
                            .disabled(draft.loop == nil)
                            .accessibilityIdentifier("workflow-repeat-from")
                            if draft.loop == nil {
                                Text("Enable Repeat rounds to choose where later rounds start.").font(.caption).foregroundStyle(.secondary)
                            }
                            if draft.loop != nil {
                                Picker("Final step", selection: Binding(get: { draft.loop?.finalNodeID ?? draft.entryNodeID }, set: { draft.loop?.finalNodeID = $0 })) {
                                    ForEach(draft.nodes) { Text(stepTitle($0)).tag($0.id) }
                                }
                                Toggle("Include final output on repeat", isOn: Binding(get: { draft.loop?.includesResult ?? true }, set: { draft.loop?.includesResult = $0 }))
                                TextField("Maximum rounds", value: Binding(get: { draft.loop?.maximumRounds ?? 5 }, set: { draft.loop?.maximumRounds = $0 }), format: .number)
                                Text("The first round starts at First step; later rounds start at Repeat from. Earlier steps are not repeated. All branches must reach Final step. The limit pauses the workflow.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Execution")
                                Text(executionSummary).font(.caption).foregroundStyle(.secondary)
                            }
                        }.disclosureGroupStyle(AgentWorkflowEditorDisclosureStyle(id: "workflow-execution-toggle", disabled: false))
                    }
                }
                if let validationIssue {
                    Section { Text(validationIssue).font(.callout).foregroundStyle(.secondary) }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
            .disabled(saving)
            .navigationTitle(isNew ? "New workflow" : "Edit workflow")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(!importing ? "Cancel" : "Stop import") {
                        if importing {
                            if activeImport == nil {
                                importing = false
                            }
                            activeImport = nil
                        } else {
                            cancel()
                        }
                    }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(saving || importing || validationIssue != nil || !endpoint.isConnected)
                        .accessibilityIdentifier("workflow-editor-save")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 500, idealHeight: 700)
        #endif
        .interactiveDismissDisabled(saving || importing || !importedIDs.isEmpty)
        .task(id: activeImport?.id) {
            guard let activeImport else { return }
            await activeImport.perform()
        }
        .sheet(isPresented: $showingCreation, onDismiss: { creation = nil }) {
            VStack {
                if let creation {
                    AgentWorkflowNewAgentView(creation: creation, preferredSession: draft.creationSession, workflowName: draft.name) {
                        createdAgent = $0
                        showingCreation = false
                    }
                } else if let error {
                    VStack {
                        Text(error).textSelection(.enabled)
                        Button("Close") { showingCreation = false }
                    }.padding()
                } else {
                    ProgressView("Loading Agent launch options…").padding()
                }
            }
            #if os(macOS)
            .frame(minWidth: 480, idealWidth: 480, minHeight: 600, idealHeight: 620)
            #endif
            .task {
                guard let createAgent, !loadingCreation else { return }
                loadingCreation = true
                error = nil
                defer { loadingCreation = false }
                do {
                    let options = try await createAgent(draft.hostID)
                    try Task.checkCancellation()
                    creation = options
                } catch {
                    if !Task.isCancelled {
                        self.error = error.localizedDescription
                    }
                }
            }
        }
        .sheet(isPresented: $showingReviewTemplate) {
            AgentWorkflowReviewTemplatePicker(instances: instances) { developer, reviewer in
                AgentWorkflowReviewTemplate.apply(to: &draft, developerID: developer, reviewerID: reviewer)
                draft.updateAgentNames(from: instances)
            }
        }
        .sheet(isPresented: $showingAgentPicker, onDismiss: { choosingAgentFor = nil }) {
            AgentWorkflowAgentPicker(instances: instances, definition: choosingAgentFor == nil ? draft : nil, refreshing: refreshing, error: error, refresh: refreshInstances) { instance in
                guard !importing else { return }
                let participantID = draft.addAgent(instance, in: instances)
                if let choosingAgentFor {
                    guard let index = draft.nodes.firstIndex(where: { $0.id == choosingAgentFor }) else { return }
                    draft.nodes[index].agentInstanceID = participantID
                } else {
                    addNode(.init(name: AgentWorkflowWire.boundedName("\(instance.displayName) task"), agentInstanceID: participantID, initialTask: draft.nodes.isEmpty ? .textAndAttachments : .omit))
                }
            }
        }
        .task {
            await refreshInstances()
            await refreshAttachments()
        }
        .onDisappear {
            let unused = importedIDs
            Task { await discardImports(unused) }
        }
        .task(id: createdAgent) {
            guard createdAgent != nil else { return }
            for _ in 0..<10 {
                await refreshInstances()
                guard createdAgent != nil, !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .accessibilityIdentifier("workflow-editor")
    }

    private var validationIssue: String? {
        if draft.nodes.contains(where: { $0.kind == .agent && $0.agentInstanceID == nil }) {
            return "Choose an Agent for each Agent step before saving."
        }
        do { try AgentWorkflowWire.validate(draft)
            return nil
        } catch { return error.localizedDescription }
    }

    private var inputSummary: String {
        let text = draft.initialInput.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = draft.initialInput.attachmentIDs.count
        if text.isEmpty, images == 0 {
            return "Optional · set the task when starting a run."
        }
        return text.isEmpty ? "Images attached." : text
    }

    private var executionSummary: String {
        let start = draft.nodes.first { $0.id == draft.entryNodeID }.map { stepTitle($0) } ?? "Choose a first step"
        guard let loop = draft.loop else { return "Starts at \(start) · runs once" }
        let repeated = draft.nodes.first { $0.id == (loop.entryNodeID ?? draft.entryNodeID) }.map { stepTitle($0) } ?? "Choose a repeat step"
        return "Starts at \(start) · repeats from \(repeated) · up to \(loop.maximumRounds) rounds"
    }

    private func stepTitle(_ node: AgentWorkflowNode) -> String {
        "\((draft.nodes.firstIndex { $0.id == node.id } ?? 0) + 1). \(node.name)"
    }

    private func stepSummary(_ node: AgentWorkflowNode) -> some View {
        let agent = node.agentInstanceID.map(agentName) ?? (node.kind == .content ? "Content" : "Choose an Agent")
        let upstream = draft.upstream(of: node.id).map { stepTitle($0) }
        return VStack(alignment: .leading, spacing: 4) {
            Text(stepTitle(node)).font(.headline)
            Text(agent + " · " + (node.id == draft.entryNodeID ? "Starts here" : upstream.isEmpty ? "No upstream steps" : "After " + upstream.joined(separator: ", ")))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let selection = node.modelSelection {
                Text(selection.model + (selection.effort.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private func expansion(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue }, set: {
            if !importing {
                binding.wrappedValue = $0
            }
        })
    }

    private func stepExpansion(_ id: UUID) -> Binding<Bool> {
        Binding(get: { expandedStepID == id }, set: { expanded in
            guard !importing else { return }
            expandedStepID = expanded ? id : nil
        })
    }

    private func connection(from source: UUID, to target: UUID) -> Binding<AgentWorkflowConnectionMode> {
        Binding(get: { draft.connectionMode(from: source, to: target) }, set: { draft.setConnectionMode($0, from: source, to: target) })
    }

    private func agentName(_ id: UUID) -> String {
        draft.instance(for: id, in: instances)?.displayName ?? "Agent unavailable · \(id.uuidString.prefix(8))"
    }

    private func participantBinding(_ id: UUID) -> Binding<UUID> {
        Binding(get: { draft.instance(for: id, in: instances)?.id ?? id }, set: { replacement in
            guard
                let target = instances.first(where: { $0.id == replacement })?.target,
                draft.agentTargets?[id]?.agentID != target.agentID,
                let index = draft.participants?.firstIndex(where: { $0.id == id }) else { return }
            draft.agentTargets = draft.agentTargets ?? [:]
            draft.agentTargets?[id] = target
            draft.participants?[index].name = AgentWorkflowWire.boundedName(agentName(id))
            for step in draft.nodes.indices where draft.nodes[step].agentInstanceID == id {
                draft.nodes[step].modelSelection = nil
            }
        })
    }

    private func addNode(_ node: AgentWorkflowNode) {
        guard !importing else { return }
        draft.appendStep(node)
        expandedStepID = node.id
    }

    private func remove(_ nodeID: UUID) {
        guard !importing else { return }
        if expandedStepID == nodeID {
            expandedStepID = nil
        }
        draft.nodes.removeAll { $0.id == nodeID }
        draft.edges.removeAll { $0.source == nodeID || $0.target == nodeID }
        if draft.entryNodeID == nodeID {
            draft.entryNodeID = draft.nodes.first?.id ?? UUID()
        }
        if draft.nodes.isEmpty {
            draft.loop = nil
        }
        if draft.loop?.entryNodeID == nodeID {
            draft.loop?.entryNodeID = draft.entryNodeID
        }
        if draft.loop?.finalNodeID == nodeID {
            draft.loop?.finalNodeID = draft.nodes.last?.id ?? draft.entryNodeID
        }
    }

    private func refreshInstances() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let values = try await endpoint.instances(hostID: draft.hostID)
            try Task.checkCancellation()
            instances = values
            draft = draft.resolvingAgents(in: values)
            draft.updateAgentNames(from: values)
            if let target = createdAgent, let instance = values.first(where: { target.matches($0) }) {
                draft.creationSession = AgentWorkflowSessionReference(instance.workspacePane)
                draft.addAgent(instance, in: instances)
                createdAgent = nil
            }
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                _ = try await endpoint.request(.save(draft, expectedRevision: expectedRevision), hostID: draft.hostID)
                let originals = draft.attachmentIDs.compactMap { attachments[$0]?.conversion?.sourceID }
                let unused = importedIDs.subtracting(draft.attachmentIDs.union(originals))
                importedIDs.removeAll()
                await discardImports(unused)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func taskInput(_ title: String, input: Binding<AgentWorkflowInput>) -> some View {
        AgentWorkflowImageInput(
            endpoint: endpoint,
            hostID: draft.hostID,
            title: title,
            text: input.text,
            ids: input.attachmentIDs,
            attachments: $attachments,
            importedIDs: $importedIDs,
            importing: $importing, activeImport: $activeImport, totalImageCount: draft.attachmentIDs.count
        )
    }

    private func refreshAttachments() async {
        do {
            let values = try await endpoint.attachments(Array(draft.attachmentIDs), hostID: draft.hostID)
            try Task.checkCancellation()
            for value in values {
                attachments[value.id] = value
            }
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }

    private func cancel() {
        saving = true
        Task {
            await discardImports(importedIDs)
            importedIDs.removeAll()
            saving = false
            dismiss()
        }
    }

    private func discardImports(_ ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }
        // Remove outputs before originals, including across batches. A retained
        // output deliberately prevents its original from being discarded.
        let values = ids.sorted { (attachments[$0]?.conversion == nil ? 1 : 0) < (attachments[$1]?.conversion == nil ? 1 : 0) }
        for offset in stride(from: 0, to: values.count, by: AgentWorkflowWire.maximumAttachments) {
            let end = min(values.count, offset + AgentWorkflowWire.maximumAttachments)
            do { _ = try await endpoint.request(.discardAttachments(Array(values[offset..<end])), hostID: draft.hostID) }
            catch {
                Logger(subsystem: "com.jicezeng.ctrlx", category: "WorkflowUploads")
                    .error("Could not remove unused workflow imports: \(error.localizedDescription)")
            }
        }
    }
}

private struct AgentWorkflowEditorDisclosureStyle: DisclosureGroupStyle {
    let id: String
    let disabled: Bool
    var remove: (() -> Void)? = nil

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { configuration.isExpanded.toggle() } label: {
                    HStack(spacing: 8) {
                        Symbols.chevronRight.image
                            .font(.caption).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                        configuration.label
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier(id)
                if let remove {
                    Button(role: .destructive, action: remove) { Label("Remove step", symbol: .trash) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Remove step")
                        .disabled(disabled)
                        .accessibilityIdentifier("\(id)-remove")
                }
            }
            if configuration.isExpanded {
                configuration.content.padding(.leading, 20)
            }
        }
    }
}

extension AgentWorkflowReadiness {
    var title: String {
        switch self {
        case .ready: "Ready"
        case .busy: "Agent is working; wait before starting."
        case .draft: "The Agent has an unsent draft."
        case .awaitingHuman: "Resolve the Agent’s question or permission request first."
        case .unavailable: "Agent identity or input cannot be verified."
        }
    }
}
