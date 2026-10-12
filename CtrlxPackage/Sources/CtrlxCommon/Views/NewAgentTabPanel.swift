import CtrlxNetworking
import SwiftUI

/// Captured when opening the menu. A later selection change must never reroute
/// a typed path or a launch to a different Host/session.
@MainActor
public struct NewAgentTabConfiguration: Identifiable {
    public struct Destination: Hashable, Sendable {
        public let hostID: String?
        public let sessionName: String

        public init(hostID: String?, sessionName: String) {
            self.hostID = hostID
            self.sessionName = sessionName
        }
    }

    public nonisolated let id: Destination
    let initialDirectory: String
    let agents: [SessionLaunchAgent]
    let directorySource: SessionDirectorySource
    let unavailableReason: String?
    let start: @MainActor (CreateTmuxWindow) async throws -> Void

    public init(
        id: Destination, initialDirectory: String, agents: [SessionLaunchAgent],
        directorySource: SessionDirectorySource, unavailableReason: String?,
        start: @escaping @MainActor (CreateTmuxWindow) async throws -> Void
    ) {
        self.id = id
        self.initialDirectory = initialDirectory
        self.agents = agents
        self.directorySource = directorySource
        self.unavailableReason = unavailableReason
        self.start = start
    }

    var orderedAgents: [SessionLaunchAgent] {
        agents.sorted {
            if ($0.id == AgentLaunchDefaults.pluginID) != ($1.id == AgentLaunchDefaults.pluginID) {
                return $0.id == AgentLaunchDefaults.pluginID
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func request(agentID: String, directory: String) throws -> CreateTmuxWindow {
        if let unavailableReason { throw LaunchError(unavailableReason) }
        guard agents.contains(where: { $0.id == agentID }) else {
            throw LaunchError("This agent is no longer available on the selected Host.")
        }
        guard SessionDirectoryPath.isValid(directory) else {
            throw LaunchError("Choose an absolute directory or ~/… on the Host.")
        }
        return CreateTmuxWindow(sessionName: id.sessionName, workingDirectory: directory, pluginID: agentID)
    }

    public struct LaunchError: LocalizedError {
        let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}

@MainActor
public struct NewAgentTabPanel: View {
    let configuration: NewAgentTabConfiguration
    @Environment(\.dismiss) private var dismiss
    @State private var launchingAgentID: String?
    @State private var errorMessage: String?

    public init(configuration: NewAgentTabConfiguration) {
        self.configuration = configuration
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("New Agent").font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .disabled(launchingAgentID != nil)
            }
            Text("New tab in \(configuration.id.sessionName)")
                .font(.caption).foregroundStyle(.secondary)
            if let reason = configuration.unavailableReason {
                Text(reason).foregroundStyle(.secondary)
            } else if configuration.agents.isEmpty {
                Text("No agents available from this Host. Check Settings → Agents on the Host.")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(configuration.orderedAgents) { agent in
                        AgentTabLaunchCard(
                            agent: agent,
                            initialDirectory: configuration.initialDirectory,
                            directorySource: configuration.directorySource,
                            isDisabled: launchingAgentID != nil || configuration.unavailableReason != nil,
                            isLaunching: launchingAgentID == agent.id,
                            onStart: { directory in start(agentID: agent.id, directory: directory) }
                        )
                    }
                }
            }
            #if os(macOS)
                .frame(maxHeight: 500)
            #endif
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding()
        #if os(macOS)
            .frame(width: 420)
        #endif
        .interactiveDismissDisabled(launchingAgentID != nil)
        .accessibilityIdentifier("new-agent-tab-panel")
    }

    private func start(agentID: String, directory: String) {
        guard launchingAgentID == nil else { return }
        launchingAgentID = agentID
        errorMessage = nil
        Task {
            defer { launchingAgentID = nil }
            do {
                let request = try configuration.request(agentID: agentID, directory: directory)
                try await configuration.start(request)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Each supported agent gets its own editable draft; switching/expanding a
/// card cannot overwrite another card's path. Directory browsing is opt-in.
@MainActor
private struct AgentTabLaunchCard: View {
    let agent: SessionLaunchAgent
    let directorySource: SessionDirectorySource
    let isDisabled: Bool
    let isLaunching: Bool
    let onStart: (String) -> Void
    @State private var directory: String
    @State private var showsDirectories = false
    @State private var isCreatingDirectory = false

    init(agent: SessionLaunchAgent, initialDirectory: String, directorySource: SessionDirectorySource,
         isDisabled: Bool, isLaunching: Bool, onStart: @escaping (String) -> Void) {
        self.agent = agent
        self.directorySource = directorySource
        self.isDisabled = isDisabled
        self.isLaunching = isLaunching
        self.onStart = onStart
        // Seed a user-owned draft once, not a binding to a moving terminal cwd.
        _directory = State(initialValue: initialDirectory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(agent.name, symbol: .sparkles).font(.headline)
            TextField("Directory on Host", text: $directory)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                .accessibilityLabel("\(agent.name) directory on Host")
                .accessibilityIdentifier("new-agent-directory-\(agent.id)")
            DisclosureGroup("Choose Directory…", isExpanded: $showsDirectories) {
                if showsDirectories {
                    SessionDirectoryBrowser(path: $directory, source: directorySource, isCreatingDirectory: $isCreatingDirectory)
                        .padding(.top, 8)
                }
            }
            HStack {
                Spacer()
                if isLaunching { ProgressView().controlSize(.small) }
                Button("Start \(agent.name)") {
                    guard !isCreatingDirectory else { return }
                    onStart(directory)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!SessionDirectoryPath.isValid(directory))
                    .accessibilityIdentifier("new-agent-start-\(agent.id)")
            }
        }
        .padding(12)
        .background(.quaternary, in: .rect(cornerRadius: 10))
        .disabled(isDisabled || isCreatingDirectory)
        .accessibilityIdentifier("new-agent-card-\(agent.id)")
    }
}
