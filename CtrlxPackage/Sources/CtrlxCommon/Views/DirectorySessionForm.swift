import SwiftUI

/// Shared by the Mac popover and iOS picker; owns no navigation container.
@MainActor
public struct DirectorySessionForm: View {
    public let agents: [SessionLaunchAgent]
    public let isCreating: Bool
    public let onStart: (SessionLaunchRequest) -> Void
    public let onCancel: () -> Void

    @State private var path = ""
    @State private var selectedAgentID: String?

    public init(
        agents: [SessionLaunchAgent],
        isCreating: Bool,
        onStart: @escaping (SessionLaunchRequest) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.agents = agents
        self.isCreating = isCreating
        self.onStart = onStart
        self.onCancel = onCancel
    }

    private var agentID: String? {
        if let selectedAgentID, agents.contains(where: { $0.id == selectedAgentID }) {
            return selectedAgentID
        }
        return agents.first?.id
    }

    private var canStart: Bool {
        !isCreating && SessionDirectoryPath.isValid(path)
            && agents.contains(where: { $0.id == agentID })
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start in Directory")
                .font(.headline)
            Text("Enter a directory on the Mac that will run this session. Use an absolute path or ~/… without shell quotes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Directory on Host", text: $path, prompt: Text("~/Projects/my-project"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                .onSubmit(start)
                .accessibilityIdentifier("new-session-directory")

            if agents.isEmpty {
                Text("No agents available from this Host. Check its connection and Settings → Agents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Agent", selection: Binding(
                    get: { agentID ?? "" },
                    set: { selectedAgentID = $0 }
                )) {
                    ForEach(agents) { agent in
                        Text(agent.name).tag(agent.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("new-session-agent")
            }

            if !path.isEmpty && !SessionDirectoryPath.isValid(path) {
                Text("Use /… or ~/… and enter only one directory.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Back", action: onCancel)
                    .buttonStyle(.borderless)
                    .disabled(isCreating)
                Spacer()
                if isCreating { ProgressView().controlSize(.small) }
                Button("Start", action: start)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
                    .accessibilityIdentifier("start-directory-session")
            }
        }
        .disabled(isCreating)
    }

    private func start() {
        guard canStart, let agentID else { return }
        onStart(.directory(path: path, pluginID: agentID))
    }
}
