import CtrlxNetworking
import SwiftUI

@MainActor
struct AgentWorkflowRunView: View {
    let endpoint: AgentWorkflowEndpoint
    let hostID: UUID
    let runID: UUID
    let openAgent: (AgentWorkflowInstance) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var state: AgentWorkflowRunState?
    @State private var history: [AgentWorkflowInvocationSummary] = []
    @State private var error: String?
    @State private var changing = false
    @State private var confirmingEnd = false
    @State private var confirmingDelete = false
    @State private var roundLimit = 1

    var body: some View {
        List {
            if let state {
                Section {
                    LabeledContent("Status", value: state.summary.status.title)
                    LabeledContent("Round", value: "\(state.summary.round) / \(state.summary.roundLimit)")
                    LabeledContent("Authorization expires", value: state.summary.authorizationExpiresAt.formatted(date: .abbreviated, time: .shortened))
                    if let issue = state.summary.issue {
                        Text(issue).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if let finish = state.finishRequest {
                        Text("Completion requested: \(finish.reason)").textSelection(.enabled)
                    }
                    if !endpoint.isConnected {
                        Text("Host offline · showing the last received state").foregroundStyle(.secondary)
                    }
                }
                Section("Nodes · current round") {
                    ForEach(state.nodes) { node in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(node.name).font(.headline)
                                Spacer()
                                Text(node.invocation?.status.title ?? (state.summary.status.isTerminal ? "Not run" : "Waiting"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if node.kind == .content {
                                Label("Content node", symbol: .docTextFill).font(.caption).foregroundStyle(.secondary)
                            }
                            if node.invocation == nil, !state.summary.status.isTerminal, !node.upstreamIDs.isEmpty {
                                let names = state.nodes.filter { node.upstreamIDs.contains($0.id) }.map(\.name)
                                Text("Waiting for: \(names.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                            }
                            if let issue = node.invocation?.issue {
                                Text(issue).foregroundStyle(.orange)
                            }
                            if let instance = node.instance {
                                Button { openAgent(instance) } label: {
                                    Label("Open \(instance.displayName)", symbol: .terminal)
                                }
                                .disabled(!endpoint.isConnected || instance.readiness == .unavailable)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                if !state.summary.status.isTerminal {
                    Section {
                        if state.summary.status == .paused {
                            if state.summary.isLooping {
                                TextField("Maximum rounds", value: $roundLimit, format: .number)
                            }
                            Button("Continue") {
                                change(.resume(runID, expectedRevision: state.summary.revision, roundLimit: roundLimit))
                            }
                        } else {
                            Button("Pause handoffs") { change(.pause(runID, expectedRevision: state.summary.revision)) }
                        }
                        Button("End workflow", role: .destructive) { confirmingEnd = true }
                    } footer: {
                        Text("Pausing stops new handoffs. Ending releases the Agents; their tabs and current tasks stay open.")
                    }
                    .disabled(changing || !endpoint.isConnected)
                } else {
                    Section {
                        Button("Delete run", role: .destructive) { confirmingDelete = true }
                            .disabled(changing || !endpoint.isConnected)
                    }
                }
                Section("Handoff history") {
                    ForEach(history.reversed()) { invocation in
                        NavigationLink {
                            AgentWorkflowInvocationView(endpoint: endpoint, hostID: hostID, runID: runID, invocation: invocation)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(state.nodes.first(where: { $0.id == invocation.nodeID })?.name ?? "Node")
                                Text("Round \(invocation.round) · \(invocation.status.title)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if history.isEmpty {
                        Text("No tasks have been sent yet.").foregroundStyle(.secondary)
                    }
                }
            } else if error == nil {
                ProgressView("Loading workflow…")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .navigationTitle(state?.summary.name ?? "Workflow")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await refresh() } } label: { Label("Refresh", symbol: .arrowClockwise) }
                    .disabled(changing || !endpoint.isConnected)
            }
        }
        .refreshable { await refresh() }
        .confirmationDialog("End this workflow?", isPresented: $confirmingEnd) {
            if let state {
                Button("End workflow", role: .destructive) { change(.end(runID, expectedRevision: state.summary.revision)) }
            }
        } message: {
            Text("No more tasks will be sent. Agent tabs and saved results will remain.")
        }
        .confirmationDialog("Delete this run and its handoff history?", isPresented: $confirmingDelete) {
            if let state {
                Button("Delete run", role: .destructive) { change(.deleteRun(runID, expectedRevision: state.summary.revision)) }
            }
        } message: { Text("The configuration and Agent tabs stay available.") }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .accessibilityIdentifier("workflow-run")
    }

    private func refresh() async {
        guard !changing else { return }
        do {
            let response = try await endpoint.request(.run(runID), hostID: hostID)
            guard let updated = response.run else { throw AgentWorkflowError("The Host did not return this workflow.") }
            let invocations = try await endpoint.invocations(runID: runID, hostID: hostID)
            try Task.checkCancellation()
            guard !changing, updated.summary.revision >= (state?.summary.revision ?? 0) else { return }
            state = updated
            history = invocations
            roundLimit = max(roundLimit, updated.summary.roundLimit)
            error = nil
        } catch is CancellationError {
            // Leaving this screen cancels its polling task.
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }

    private func change(_ operation: ManageAgentWorkflows.Operation) {
        guard !changing else { return }
        changing = true
        Task {
            defer { changing = false }
            do {
                let response = try await endpoint.request(operation, hostID: hostID)
                if let updated = response.run {
                    state = updated
                }
                if case .deleteRun = operation {
                    dismiss()
                }
                error = nil
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

@MainActor
private struct AgentWorkflowInvocationView: View {
    let endpoint: AgentWorkflowEndpoint
    let hostID: UUID
    let runID: UUID
    let invocation: AgentWorkflowInvocationSummary
    @State private var part: ManageAgentWorkflows.TextPart = .input
    @State private var text: String?
    @State private var attachments: [AgentWorkflowAttachment] = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Content", selection: $part) {
                    Text("Input").tag(ManageAgentWorkflows.TextPart.input)
                    if invocation.status == .succeeded {
                        Text("Output").tag(ManageAgentWorkflows.TextPart.result)
                    }
                }
                .pickerStyle(.segmented)
                if !attachments.isEmpty {
                    Text(part == .input ? "Attachments" : "Shared artifacts").font(.headline)
                    ForEach(attachments) { AgentWorkflowAttachmentLabel(attachment: $0) }
                    Divider()
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if let text {
                    Text(verbatim: text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView("Loading…")
                }
            }
            .padding()
        }
        .navigationTitle("Round \(invocation.round)")
        .task(id: part) {
            text = nil
            attachments = []
            error = nil
            do {
                let value = try await endpoint.text(runID: runID, invocationID: invocation.id, part: part, hostID: hostID)
                let files = try await endpoint.attachments(part == .input ? invocation.inputAttachmentIDs : invocation.resultAttachmentIDs, hostID: hostID)
                try Task.checkCancellation()
                text = value
                attachments = files
            } catch is CancellationError {
                // Switching content cancels the old read.
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

extension AgentWorkflowRunStatus {
    var title: String {
        switch self {
        case .running: "Running"
        case .paused: "Paused"
        case .finishing: "Waiting for final answer"
        case .completed: "Completed"
        case .ended: "Ended"
        }
    }
}

extension AgentWorkflowInvocationStatus {
    var title: String {
        switch self {
        case .pending: "Preparing"
        case .writing: "Submitting"
        case .awaitingAcceptance: "Waiting for receipt"
        case .running: "Working"
        case .succeeded: "Completed"
        case .failed: "Failed"
        case .uncertain: "Needs verification"
        case .cancelled: "Cancelled"
        }
    }
}
