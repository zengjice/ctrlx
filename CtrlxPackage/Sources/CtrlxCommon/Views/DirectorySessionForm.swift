import CtrlxNetworking
import SwiftUI

/// Shared by the Mac popover and iOS picker; owns no navigation container.
@MainActor
public struct DirectorySessionForm: View {
    public let agents: [SessionLaunchAgent]
    public let directorySource: SessionDirectorySource
    public let isCreating: Bool
    public let onStart: (SessionLaunchRequest) -> Void
    public let onCancel: () -> Void

    @State private var path = "~/"
    @State private var selectedAgentID: String?
    @State private var selectedProviderID: String?
    @State private var isCreatingDirectory = false
    @State private var usingWorktree = false
    @State private var worktreeName = "work-\(UUID().uuidString.prefix(8).lowercased())"
    @State private var worktreeState = SessionWorktreeState()
    @State private var worktreeRetry = 0
    @FocusState private var isPathFocused: Bool

    public init(
        agents: [SessionLaunchAgent],
        directorySource: SessionDirectorySource,
        isCreating: Bool,
        onStart: @escaping (SessionLaunchRequest) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.agents = agents
        self.directorySource = directorySource
        self.isCreating = isCreating
        self.onStart = onStart
        self.onCancel = onCancel
    }

    private var agentID: String? {
        AgentLaunchDefaults.selectedID(availableIDs: agents.map(\.id), selection: selectedAgentID)
    }

    private var selectedAgent: SessionLaunchAgent? {
        agents.first { $0.id == agentID }
    }

    private var canStart: Bool {
        !isCreating && !isCreatingDirectory && SessionDirectoryPath.isValid(path)
            && agents.contains(where: { $0.id == agentID })
            && (!usingWorktree || (try? worktreeState.request(for: worktreeQuery, name: worktreeName)) != nil)
    }

    private var worktreeQuery: SessionWorktreeState.Query {
        .init(
            hostID: directorySource.id,
            path: path,
            enabled: usingWorktree,
            unavailableReason: directorySource.worktreeUnavailableReason,
            retry: worktreeRetry
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start in Directory")
                .font(.headline)
            Text("Choose a folder on the Host, or type a path to find it. Opening a folder does not start a session.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #if os(macOS)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            #endif
            TextField("Directory on Host", text: $path, prompt: Text("~/Projects/my-project"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
                .focused($isPathFocused)
                .onSubmit { isPathFocused = false }
                .accessibilityIdentifier("new-session-directory")

            SessionDirectoryBrowser(path: $path, source: directorySource, isCreatingDirectory: $isCreatingDirectory)

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
                .onChange(of: agentID) { selectedProviderID = nil }

                if let agent = selectedAgent, !agent.providers.isEmpty {
                    Picker("Provider", selection: $selectedProviderID) {
                        Text(agent.defaultProviderLabel).tag(String?.none)
                        ForEach(agent.providers) { provider in
                            Text(provider.name).tag(Optional(provider.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("new-session-provider")
                }
            }

            if !path.isEmpty && !SessionDirectoryPath.isValid(path) {
                Text("Use /… or ~/… and enter only one directory.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Toggle("Create a new branch and worktree", isOn: $usingWorktree)
                .disabled(directorySource.worktreeUnavailableReason != nil)
                .accessibilityIdentifier("new-session-use-worktree")
            if let reason = directorySource.worktreeUnavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if usingWorktree {
                worktreeFields
            }
            HStack {
                Button("Back", action: onCancel)
                    .buttonStyle(.borderless)
                    .disabled(isCreating)
                Spacer()
                if isCreating {
                    ProgressView().controlSize(.small)
                }
                Button(usingWorktree ? "Start in New Worktree" : "Start in This Directory", action: start)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
                    .accessibilityIdentifier("start-directory-session")
            }
        }
        .disabled(isCreating || isCreatingDirectory)
        .task(id: worktreeQuery) { await prepareWorktree() }
    }

    private var worktreeFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Worktree Name", text: $worktreeName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
                .accessibilityIdentifier("new-session-worktree-name")
            Text("Used for the session, branch and worktree directory.")
                .font(.caption).foregroundStyle(.secondary)
            if worktreeState.query == worktreeQuery, let plan = worktreeState.plan {
                WorktreeReview(
                    plan: plan,
                    name: worktreeName,
                    allowUncommittedChanges: $worktreeState.allowUncommittedChanges,
                    acknowledgementIdentifier: "new-session-allow-uncommitted-changes"
                )
            } else if worktreeState.isLoading {
                ProgressView("Checking directory…").controlSize(.small)
            } else if let error = worktreeState.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Button("Refresh Worktree Preview") { worktreeRetry += 1 }
                .buttonStyle(.borderless)
                .disabled(directorySource.worktreeUnavailableReason != nil || worktreeState.isLoading)
        }
    }

    private func prepareWorktree() async {
        let query = worktreeQuery
        let id = worktreeState.begin(query)
        guard worktreeState.isLoading, let prepare = directorySource.prepareWorktree else { return }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let plan = try await prepare(query.path)
            try Task.checkCancellation()
            worktreeState.finish(id, plan: plan)
        } catch {
            guard !Task.isCancelled else { return }
            worktreeState.fail(id, message: error.localizedDescription)
        }
    }

    private func start() {
        guard canStart, let agentID else { return }
        let worktree = usingWorktree ? try? worktreeState.request(for: worktreeQuery, name: worktreeName) : nil
        guard !usingWorktree || worktree != nil else { return }
        onStart(.directory(
            path: path,
            pluginID: agentID,
            worktree: worktree,
            providerID: selectedProviderID
        ))
    }
}
