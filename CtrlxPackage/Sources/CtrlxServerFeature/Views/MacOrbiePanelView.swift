import CtrlxCommon
import CtrlxNetworking
import SwiftUI

@MainActor
public struct MacOrbiePanelView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var notice: String?
    @FocusState private var editing: Bool

    public init() { }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Orbie", symbol: .sparkles).font(.title2.bold())
                Spacer()
                Button("Orbiters…") { openFull(tasks: true) }.accessibilityIdentifier("orbie-panel-tasks")
                Button { coordinator.orbiePanel.dismiss(restoreFocus: true) } label: { Label("Close", symbol: .xmark) }
                    .labelStyle(.iconOnly).accessibilityIdentifier("orbie-panel-close")
            }
            if let orbie = coordinator.orbie {
                conversation(orbie)
            } else {
                Text(coordinator.agentWorkflowStartupError ?? "Starting Orbie services on this Mac…").foregroundStyle(.secondary)
            }
            if let notice {
                Text(notice).foregroundStyle(.red).textSelection(.enabled)
            }
            Divider()
            HStack {
                TextField("Find Orbiters by name or project", text: $query).textFieldStyle(.roundedBorder).accessibilityIdentifier("orbie-panel-search")
                Button { Task { await coordinator.orbiters?.refresh() } } label: { Label("Refresh", symbol: .arrowClockwise) }.labelStyle(.iconOnly)
            }
            if let orbiters = coordinator.orbiters {
                let catalog = OrbieAgentCatalog.summaries(agents: orbiters.agents, messages: orbiters.messages, instances: orbiters.instances)
                let recent = OrbieAgentCatalog.search(catalog, query: query, limit: 5)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if recent.isEmpty {
                            Text("No Orbiters match. Only Agents created here or explicitly associated are listed.").foregroundStyle(.secondary)
                        }
                        ForEach(recent) { task in taskRow(task) }
                    }
                }.frame(minHeight: 80, idealHeight: 140, maxHeight: 180)
            }
        }
        .padding(20).frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 600, alignment: .topLeading)
        .background(OrbiePanelWindowAttachment(controller: coordinator.orbiePanel))
        .onExitCommand { coordinator.orbiePanel.dismiss(restoreFocus: true) }
        .onChange(of: coordinator.orbiePanel.isVisible) { _, visible in
            if !visible {
                Task { await coordinator.orbie?.saveDraft() }
            }
        }
        .task(id: coordinator.orbiePanel.isVisible) {
            guard coordinator.orbiePanel.isVisible else { return }
            editing = true
            while !Task.isCancelled {
                await coordinator.orbie?.refresh()
                await coordinator.orbiters?.refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .task(id: coordinator.orbie?.draft) {
            do { try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
            } catch { return }
            await coordinator.orbie?.saveDraft()
        }
    }

    private func conversation(_ orbie: OrbieService) -> some View {
        @Bindable var orbie = orbie
        return VStack(alignment: .leading, spacing: 10) {
            if let issue = orbie.issue {
                Text(issue).foregroundStyle(.red).textSelection(.enabled)
            }
            if orbie.record?.enabled != true || orbie.record?.creation == nil {
                Button("Set Up Orbie…") { openFull(tasks: false) }.accessibilityIdentifier("orbie-panel-setup")
            }
            if orbie.canRestore {
                AgentRoleResumeButton(tabClosed: orbie.tabClosed) { Task { await orbie.restoreOriginalConversation() } }.disabled(orbie.isBusy)
            }
            if let availability = orbie.availability {
                Text(availability).font(.caption).foregroundStyle(.secondary)
            }
            if let answer = orbie.messages.last?.answer {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(OrbieAgentCatalog.displayAnswer(OrbieAgentCatalog.bounded(answer, bytes: 8_000))).textSelection(.enabled)
                        let ids = OrbieAgentCatalog.candidates(in: answer)
                        ForEach(ids, id: \.self) { id in
                            if
                                let orbiters = coordinator.orbiters,
                                let task = OrbieAgentCatalog.summaries(agents: orbiters.agents, messages: orbiters.messages, instances: orbiters.instances).first(where: { $0.id == id }) {
                                taskRow(task)
                            } else {
                                Text("A suggested Agent is no longer in the Orbiter list.").foregroundStyle(.secondary)
                            }
                        }
                        ForEach(OrbieAgentCatalog.workflowCandidates(in: answer), id: \.self) { id in
                            Button("Open Suggested Workflow") {
                                Task {
                                    do { try await coordinator.openOrbieWorkflow(id, openWindow: openWindow)
                                        notice = nil
                                    } catch { notice = error.localizedDescription }
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 180)
            }
            TextEditor(text: $orbie.draft).font(.body).frame(height: 76).focused($editing)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel("Message to Orbie").accessibilityIdentifier("orbie-panel-draft")
            HStack {
                Button("Full Conversation…") { openFull(tasks: false) }
                Spacer()
                Button("Send") { Task { await orbie.send() } }.buttonStyle(.borderedProminent)
                    .disabled(orbie.isBusy || orbie.availability != nil || orbie.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("orbie-panel-send")
            }
        }
    }

    private func taskRow(_ task: OrbieAgentSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.headline)
                Text(task.project).font(.caption).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            Spacer()
            Text(task.state.replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(.secondary)
            Button("Open Tab") {
                Task {
                    do { try await coordinator.openOrbiter(task.id, openWindow: openWindow)
                        notice = nil
                    } catch { notice = error.localizedDescription }
                }
            }.accessibilityIdentifier("orbie-task-open-\(task.id)")
        }.frame(maxWidth: .infinity)
    }

    private func openFull(tasks: Bool) {
        coordinator.orbiePanel.dismiss(restoreFocus: false)
        coordinator.showsOrbitersRequested = tasks
        openWindow(id: "orbie")
    }
}
