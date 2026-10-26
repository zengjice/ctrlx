import CtrlxNetworking
import SwiftUI

@MainActor
struct AgentWorkflowNewAgentView: View {
    let creation: AgentWorkflowAgentCreation
    let onCreated: (AgentWorkflowCreatedAgent) -> Void
    @State private var selectedSession: AgentWorkflowSessionReference?
    @State private var newSessionName: String
    @State private var launching = false

    init(creation: AgentWorkflowAgentCreation, preferredSession: AgentWorkflowSessionReference? = nil, workflowName: String = "workflow", onCreated: @escaping (AgentWorkflowCreatedAgent) -> Void) {
        self.creation = creation
        self.onCreated = onCreated
        self._selectedSession = State(initialValue: preferredSession)
        self._newSessionName = State(initialValue: workflowName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "workflow" : workflowName)
    }

    var body: some View {
        VStack(alignment: .leading) {
            Picker("Session", selection: $selectedSession) {
                Text("New session").tag(AgentWorkflowSessionReference?.none)
                ForEach(creation.sessions) { Text($0.name).tag(Optional(AgentWorkflowSessionReference($0.identity))) }
                if let selectedSession, session == nil {
                    Text("Previous session unavailable · choose a destination").tag(Optional(selectedSession))
                }
            }.padding([.horizontal, .top])
                .disabled(launching)
            if selectedSession == nil {
                TextField("Session name", text: $newSessionName)
                    .textFieldStyle(.roundedBorder).padding(.horizontal).disabled(launching)
            }
            NewAgentTabPanel(
                configuration: configuration,
                destinationDescription: selectedSession == nil ? "Create a session for this Agent" : nil
            ).id(selectedSession)
        }
        .interactiveDismissDisabled(launching)
    }

    private var configuration: NewAgentTabConfiguration {
        return NewAgentTabConfiguration(
            id: .init(hostID: creation.directorySource.id, sessionName: session?.name ?? newSessionName),
            initialDirectory: session?.directory ?? "~/", agents: creation.agents,
            directorySource: creation.directorySource,
            unavailableReason: selectedSession != nil && session == nil
                ? "Choose an available session or New session."
                : (session == nil && newSessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter a session name." : nil)
        ) { request in
            launching = true
            defer { launching = false }
            let created = try await creation.launch(session, request)
            onCreated(created)
        }
    }

    private var session: AgentWorkflowAgentCreation.Session? {
        creation.sessions.first { AgentWorkflowSessionReference($0.identity) == selectedSession }
    }
}
