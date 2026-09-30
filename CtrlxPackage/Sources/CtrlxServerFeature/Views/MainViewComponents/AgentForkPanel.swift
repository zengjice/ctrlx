import CtrlxCommon
import CtrlxNetworking
import SwiftUI

@MainActor
struct AgentForkConfiguration: Identifiable {
    let id = UUID()
    let sources: [AgentForkSource]
    let usingWorktree: Bool
    let prepare: (AgentForkSource) async throws -> AgentForkPreparation
    let fork: (ForkAgentSession) async throws -> Void
}

struct AgentForkMenu: View {
    let sources: [AgentForkSource]
    let unavailableReason: String?
    let choose: (Bool) -> Void

    var body: some View {
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
    }
}

struct AgentForkPanel: View {
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

    init(configuration: AgentForkConfiguration) {
        self.configuration = configuration
        self._sourceID = State(initialValue: configuration.sources.first?.paneID ?? "")
        self._worktreeName = State(initialValue: "\(configuration.sources.first?.pluginID == "codex" ? "codex" : "claude")-\(UUID().uuidString.prefix(8).lowercased())")
    }

    private var source: AgentForkSource? { configuration.sources.first { $0.paneID == sourceID } }
    private var canLaunch: Bool {
        guard source != nil, !isLoading, !isLaunching else { return false }
        guard configuration.usingWorktree else { return true }
        guard let worktree = preparation?.worktree, preparation?.source == source else { return false }
        return AgentForkWorktree.isValidName(worktreeName) && (!worktree.hasUncommittedChanges || acceptsCleanWorktree)
    }

    var body: some View {
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
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.disabled(isLaunching)
                Button(request == nil ? "Fork" : "Retry Same Request") { Task { await start() } }
                    .buttonStyle(.borderedProminent).disabled(!canLaunch).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("agentFork.create")
            }
        }
        .padding(24).frame(width: 560)
        .interactiveDismissDisabled(isLaunching)
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

    @ViewBuilder
    private var worktreeFields: some View {
        if let worktree = preparation?.worktree {
            TextField("Worktree name", text: $worktreeName).disabled(isLaunching)
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
            }
        } else if let reason = preparation?.worktreeUnavailableReason {
            Text("New worktree is unavailable: \(reason)\nFork in Current Directory is still available.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func start() async {
        guard canLaunch, let source else { return }
        let worktree: ForkAgentSession.Worktree?
        if configuration.usingWorktree, let plan = preparation?.worktree {
            worktree = .init(name: worktreeName, expectedHead: plan.head, allowUncommittedChanges: acceptsCleanWorktree)
        } else { worktree = nil }
        let next = request ?? ForkAgentSession(source: source, worktree: worktree)
        request = next
        isLaunching = true
        errorMessage = nil
        defer { isLaunching = false }
        do {
            try await configuration.fork(next)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
