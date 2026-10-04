import CtrlxNetworking
import SwiftUI

@MainActor
public struct AgentForkConfiguration: Identifiable {
    public let id = UUID()
    let sources: [AgentForkSource]
    let usingWorktree: Bool
    let prepare: @MainActor (AgentForkSource) async throws -> AgentForkPreparation
    let fork: @MainActor (ForkAgentSession) async throws -> Void

    public init(
        sources: [AgentForkSource], usingWorktree: Bool,
        prepare: @escaping @MainActor (AgentForkSource) async throws -> AgentForkPreparation,
        fork: @escaping @MainActor (ForkAgentSession) async throws -> Void
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

    func forkRequest(
        source: AgentForkSource, preparation: AgentForkPreparation?,
        name: String, allowUncommittedChanges: Bool
    ) throws -> ForkAgentSession {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let worktree = try worktreeRequest(
            source: source, preparation: preparation, name: name, allowUncommittedChanges: allowUncommittedChanges
        )
        let request = ForkAgentSession(source: source, windowName: name, worktree: worktree)
        try request.validateName()
        return request
    }
}

@MainActor
public struct AgentForkMenu: View {
    let sources: [AgentForkSource]
    let unavailableReason: String?
    let sourceUnavailableReason: String?
    let choose: (Bool) -> Void

    public init(sources: [AgentForkSource], unavailableReason: String?, sourceUnavailableReason: String? = nil, choose: @escaping (Bool) -> Void) {
        self.sources = sources
        self.unavailableReason = unavailableReason
        self.sourceUnavailableReason = sourceUnavailableReason
        self.choose = choose
    }

    private var disabledReason: String? {
        unavailableReason ?? (sources.isEmpty ? sourceUnavailableReason ?? "Fork requires a recognized Codex or Claude Code conversation." : nil)
    }

    public var body: some View {
        Menu {
            Button("In Current Directory") { choose(false) }
                .disabled(disabledReason != nil)
            Button("In New Worktree…") { choose(true) }
                .disabled(disabledReason != nil)
            if let reason = disabledReason {
                Text(reason)
            }
        } label: {
            Label("Fork", symbol: .arrowTriangleBranch)
        }
        .help(disabledReason ?? "Fork this Agent into a new window.")
        .accessibilityHint(disabledReason ?? "Fork this Agent into a new window.")
        .accessibilityIdentifier("agentFork.menu")
    }
}

@MainActor
public struct AgentForkPanel: View {
    let configuration: AgentForkConfiguration
    @Environment(\.dismiss) private var dismiss
    @State private var sourceID: String
    @State private var preparation: AgentForkPreparation?
    @State private var forkName: String
    @State private var acceptsCleanWorktree = false
    @State private var isLoading = false
    @State private var isLaunching = false
    @State private var errorMessage: String?
    @State private var request: ForkAgentSession?

    public init(configuration: AgentForkConfiguration) {
        self.configuration = configuration
        self._sourceID = State(initialValue: configuration.sources.first?.paneID ?? "")
        let agentName = configuration.sources.first?.pluginID == "codex" ? "codex" : "claude"
        self._forkName = State(initialValue: configuration.usingWorktree ? "\(agentName)-\(UUID().uuidString.prefix(8).lowercased())" : "\(agentName) fork")
    }

    private var source: AgentForkSource? { configuration.sources.first { $0.paneID == sourceID } }
    private var canLaunch: Bool {
        guard source != nil, !isLoading, !isLaunching else { return false }
        do {
            _ = try makeRequest()
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
            guard configuration.usingWorktree else { return }
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
        .onChange(of: forkName) {
            if request != nil { errorMessage = nil }
            request = nil
        }
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
            VStack(alignment: .leading, spacing: 8) {
                #if os(iOS)
                    Text(configuration.usingWorktree ? "Window / Worktree Name" : "Window Name")
                        .font(.subheadline.weight(.semibold))
                #endif
                TextField("Name", text: $forkName).disabled(isLaunching)
                    .autocorrectionDisabled()
                    #if os(iOS)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityLabel("Fork Name")
                    .accessibilityIdentifier("agentFork.name")
                Text(configuration.usingWorktree ? "Used for the window, branch and worktree directory." : "Used for the new window.")
                    .font(.caption).foregroundStyle(.secondary)
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
            Text("Use letters, numbers, ., _ or -; start with a letter or number. Do not use HEAD, .., or end with . or .lock.")
                .font(.caption).foregroundStyle(.secondary)
            let name = forkName.trimmingCharacters(in: .whitespacesAndNewlines)
            Text("Branch: \(name)\nDirectory: \(worktree.directory(name: name))\nBase: \(worktree.head.prefix(12))")
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

    private func makeRequest() throws -> ForkAgentSession {
        guard let source else { throw AgentForkError("Choose a source Agent.") }
        return try configuration.forkRequest(
            source: source, preparation: preparation, name: forkName,
            allowUncommittedChanges: acceptsCleanWorktree
        )
    }

    private func start() async {
        guard canLaunch else { return }
        isLaunching = true
        errorMessage = nil
        defer { isLaunching = false }
        do {
            let next = try request ?? makeRequest()
            request = next
            try await configuration.fork(next)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
