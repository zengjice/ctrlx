import CtrlxNetworking
import SwiftUI

@MainActor
public struct AgentForkConfiguration: Identifiable {
    public let id = UUID()
    let sources: [AgentForkSource]
    let usingWorktree: Bool
    let prepare: (AgentForkSource) async throws -> AgentForkPreparation
    let fork: (ForkAgentSession) async throws -> Void

    public init(
        sources: [AgentForkSource], usingWorktree: Bool,
        prepare: @escaping (AgentForkSource) async throws -> AgentForkPreparation,
        fork: @escaping (ForkAgentSession) async throws -> Void
    ) {
        self.sources = sources
        self.usingWorktree = usingWorktree
        self.prepare = prepare
        self.fork = fork
    }

    public static func orderedSources(panes: [PaneState], focusedPaneID: String?) -> [AgentForkSource] {
        panes.sorted {
            let leftRank = $0.paneId == focusedPaneID ? 0 : ($0.isActive ? 1 : 2)
            let rightRank = $1.paneId == focusedPaneID ? 0 : ($1.isActive ? 1 : 2)
            return leftRank == rightRank ? $0.paneIndex < $1.paneIndex : leftRank < rightRank
        }.compactMap(AgentForkSource.init(pane:))
    }

    func worktreeRequest(
        source: AgentForkSource, preparation: AgentForkPreparation?,
        name: String, allowUncommittedChanges: Bool
    ) throws -> ForkAgentSession.Worktree? {
        guard sources.contains(source) else { throw AgentForkError("Choose a source Agent from this window.") }
        guard usingWorktree else { return nil }
        guard let preparation, preparation.source == source, let plan = preparation.worktree else {
            throw AgentForkError("Check the selected source before creating a worktree.")
        }
        guard AgentForkWorktree.isValidName(name) else { throw AgentForkError("Choose a valid worktree name.") }
        guard !plan.hasUncommittedChanges || allowUncommittedChanges else {
            throw AgentForkError("Confirm that uncommitted and untracked files will not be copied.")
        }
        return .init(name: name, expectedHead: plan.head, allowUncommittedChanges: allowUncommittedChanges)
    }
}

@MainActor
public struct AgentForkMenu: View {
    let sources: [AgentForkSource]
    let unavailableReason: String?
    let choose: (Bool) -> Void

    public init(sources: [AgentForkSource], unavailableReason: String?, choose: @escaping (Bool) -> Void) {
        self.sources = sources
        self.unavailableReason = unavailableReason
        self.choose = choose
    }

    public var body: some View {
        Menu {
            Button("In Current Directory") { choose(false) }
            Button("In New Worktree…") { choose(true) }
            if let reason = unavailableReason {
                Text(reason)
            } else if sources.isEmpty {
                Text("Fork requires a recognized Codex or Claude Code conversation.")
            }
        } label: {
            Label("Fork", symbol: .arrowTriangleBranch)
        }
        .disabled(sources.isEmpty || unavailableReason != nil)
        .help(unavailableReason ?? (sources.isEmpty ? "Wait for the Agent conversation to be recognized." : "Fork this Agent into a new window."))
        .accessibilityIdentifier("agentFork.menu")
    }
}

@MainActor
public struct AgentForkPanel: View {
    let configuration: AgentForkConfiguration
    @Environment(\.dismiss) private var dismiss
    @State private var sourceID: String
    @State private var preparation: AgentForkPreparation?
    @State private var worktreeName: String
    @State private var acceptsCleanWorktree = false
    @State private var isLoading = false
    @State private var isLaunching = false
    @State private var errorMessage: String?
    @State private var request: ForkAgentSession?

    public init(configuration: AgentForkConfiguration) {
        self.configuration = configuration
        self._sourceID = State(initialValue: configuration.sources.first?.paneID ?? "")
        self._worktreeName = State(initialValue: "\(configuration.sources.first?.pluginID == "codex" ? "codex" : "claude")-\(UUID().uuidString.prefix(8).lowercased())")
    }

    private var source: AgentForkSource? { configuration.sources.first { $0.paneID == sourceID } }
    private var canLaunch: Bool {
        guard source != nil, !isLoading, !isLaunching else { return false }
        do {
            _ = try makeWorktreeRequest()
            return true
        } catch { return false }
    }

    public var body: some View {
        Group {
            #if os(iOS)
                ScrollView {
                    fields.padding(24)
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom) {
                    actions.padding().background(.bar)
                }
            #else
                VStack(alignment: .leading, spacing: 18) {
                    fields
                    actions
                }
                .padding(24).frame(width: 560)
            #endif
        }
        .interactiveDismissDisabled(isLaunching)
        .accessibilityIdentifier("agentFork.panel")
        .task(id: sourceID) {
            request = nil
            acceptsCleanWorktree = false
            preparation = nil
            errorMessage = nil
            guard let source else { return }
            if !configuration.usingWorktree {
                if configuration.sources.count == 1 { await start() }
                return
            }
            isLoading = true
            defer { if sourceID == source.paneID { isLoading = false } }
            do {
                let prepared = try await configuration.prepare(source)
                try Task.checkCancellation()
                preparation = prepared
            }
            catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
        .onChange(of: worktreeName) { request = nil }
        .onChange(of: acceptsCleanWorktree) { request = nil }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(configuration.usingWorktree ? "Fork in New Worktree" : "Fork in Current Directory")
                .font(.headline)
            if configuration.sources.count > 1 {
                Picker("Source Agent", selection: $sourceID) {
                    ForEach(configuration.sources) { source in
                        Text("\(source.pluginID == "codex" ? "Codex" : "Claude Code") · pane \(source.paneID)").tag(source.paneID)
                    }
                }
                .disabled(isLaunching)
                .accessibilityIdentifier("agentFork.source")
            }
            if let source {
                Text(source.workingDirectory).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Opens a new conversation with the saved history. The original Agent keeps running; no prompt is sent automatically.")
                    .font(.callout)
            }
            if configuration.usingWorktree {
                worktreeFields
            }
            if isLoading || isLaunching { ProgressView(isLaunching ? "Creating Fork…" : "Checking source…").controlSize(.small) }
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.disabled(isLaunching)
            Button(request == nil ? "Fork" : "Retry Same Request") { Task { await start() } }
                .buttonStyle(.borderedProminent).disabled(!canLaunch).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("agentFork.create")
        }
    }

    @ViewBuilder
    private var worktreeFields: some View {
        if let worktree = preparation?.worktree {
            TextField("Worktree name", text: $worktreeName).disabled(isLaunching)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("agentFork.worktreeName")
            Text("Use letters, numbers, ., _ or -; start with a letter or number.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Branch: fork/\(worktreeName)\nDirectory: \(worktree.directory(name: worktreeName))\nBase: \(worktree.head.prefix(12))")
                .font(.callout).textSelection(.enabled)
            Text("Starts from HEAD. Uncommitted, untracked and ignored files are not copied. The worktree remains after closing its tab.")
                .font(.callout).foregroundStyle(.secondary)
            if worktree.hasUncommittedChanges {
                Toggle("I understand the source has changes that will not be copied", isOn: $acceptsCleanWorktree)
                    .disabled(isLaunching)
                    .accessibilityIdentifier("agentFork.allowUncommittedChanges")
            }
        } else if let reason = preparation?.worktreeUnavailableReason {
            Text("New worktree is unavailable: \(reason)\nFork in Current Directory is still available.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func makeWorktreeRequest() throws -> ForkAgentSession.Worktree? {
        guard let source else { throw AgentForkError("Choose a source Agent.") }
        return try configuration.worktreeRequest(
            source: source, preparation: preparation, name: worktreeName,
            allowUncommittedChanges: acceptsCleanWorktree
        )
    }

    private func start() async {
        guard canLaunch, let source else { return }
        isLaunching = true
        errorMessage = nil
        defer { isLaunching = false }
        do {
            let worktree = try makeWorktreeRequest()
            let next = request ?? ForkAgentSession(source: source, worktree: worktree)
            request = next
            try await configuration.fork(next)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
