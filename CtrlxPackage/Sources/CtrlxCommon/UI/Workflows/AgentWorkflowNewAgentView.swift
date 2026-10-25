import CtrlxNetworking
import SwiftUI

@MainActor
struct AgentWorkflowNewAgentView: View {
    let creation: AgentWorkflowAgentCreation
    let onCreated: (AgentWorkflowCreatedAgent) -> Void
    @State private var sessionID: UUID?
    @State private var newSessionName = "workflow"
    @State private var launching = false

    var body: some View {
        VStack(alignment: .leading) {
            Picker("Session", selection: $sessionID) {
                Text("New session").tag(UUID?.none)
                ForEach(creation.sessions) { Text($0.name).tag(Optional($0.id)) }
            }.padding([.horizontal, .top])
                .disabled(launching)
            if sessionID == nil {
                TextField("Session name", text: $newSessionName)
                    .textFieldStyle(.roundedBorder).padding(.horizontal).disabled(launching)
            }
            NewAgentTabPanel(
                configuration: configuration,
                destinationDescription: sessionID == nil ? "Create a session for this Agent" : nil
            ).id(sessionID)
        }
        .interactiveDismissDisabled(launching)
    }

    private var configuration: NewAgentTabConfiguration {
        let session = creation.sessions.first { $0.id == sessionID }
        return NewAgentTabConfiguration(
            id: .init(hostID: creation.directorySource.id, sessionName: session?.name ?? newSessionName),
            initialDirectory: session?.directory ?? "~/", agents: creation.agents,
            directorySource: creation.directorySource,
            unavailableReason: session == nil && newSessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Enter a session name." : nil
        ) { request in
            launching = true
            defer { launching = false }
            let created = try await creation.launch(session, request)
            onCreated(created)
        }
    }
}
