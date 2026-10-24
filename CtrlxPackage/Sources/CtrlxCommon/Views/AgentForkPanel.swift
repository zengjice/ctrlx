import CtrlxNetworking
import SwiftUI

public enum AgentForkDestination: Sendable, Equatable {
    case currentDirectory
    case otherDirectory
    case worktree
}

@MainActor
public struct AgentForkConfiguration: Identifiable {
    public let id = UUID()
    let sources: [AgentForkSource]
    let destination: AgentForkDestination
    let directorySource: SessionDirectorySource?
    let prepare: @MainActor (AgentForkSource) async throws -> AgentForkPreparation
    let fork: @MainActor (ForkAgentSession) async throws -> Void

    public init(
        sources: [AgentForkSource], destination: AgentForkDestination, directorySource: SessionDirectorySource? = nil,
        prepare: @escaping @MainActor (AgentForkSource) async throws -> AgentForkPreparation,
        fork: @escaping @MainActor (ForkAgentSession) async throws -> Void
    ) {
        self.sources = sources
        self.destination = destination
        self.directorySource = directorySource
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
        guard destination == .worktree else { return nil }
        guard let preparation, preparation.source == source, let plan = preparation.worktree else {
            throw AgentForkError("Check the selected source before creating a worktree.")
        }
        return try plan.request(name: name, allowUncommittedChanges: allowUncommittedChanges)
    }

    func forkRequest(
        source: AgentForkSource, preparation: AgentForkPreparation?,
        name: String, allowUncommittedChanges: Bool, targetProviderID: String?,
        directory: String? = nil
    ) throws -> ForkAgentSession {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let worktree = try worktreeRequest(
            source: source, preparation: preparation, name: name, allowUncommittedChanges: allowUncommittedChanges
        )
        let targetDirectory: String?
        switch destination {
        case .currentDirectory,
             .worktree:
            targetDirectory = nil
        case .otherDirectory:
            guard directorySource != nil else {
                throw AgentForkError("Forking into another directory is unavailable on this Host.")
            }
            let directory = directory ?? source.workingDirectory
            guard SessionDirectoryPath.isValid(directory) else {
                throw AgentForkError("Enter an absolute Host directory or ~/… without control characters.")
            }
            targetDirectory = directory == source.workingDirectory ? nil : directory
        }
        let request = ForkAgentSession(
            source: source,
            windowName: name,
            worktree: worktree,
            workingDirectory: targetDirectory,
            targetProviderID: targetProviderID
        )
        try request.validateName()
        return request
    }
}

@MainActor
public struct AgentForkMenu: View {
    let sources: [AgentForkSource]
    let unavailableReason: String?
    let sourceUnavailableReason: String?
    let allowsOtherDirectory: Bool
    let choose: (AgentForkDestination) -> Void

    public init(
        sources: [AgentForkSource], unavailableReason: String?, sourceUnavailableReason: String? = nil,
        allowsOtherDirectory: Bool = true, choose: @escaping (AgentForkDestination) -> Void
    ) {
        self.sources = sources
        self.unavailableReason = unavailableReason
        self.sourceUnavailableReason = sourceUnavailableReason
        self.allowsOtherDirectory = allowsOtherDirectory
        self.choose = choose
    }

    private var disabledReason: String? {
        unavailableReason ?? (sources.isEmpty ? sourceUnavailableReason ?? "Fork requires a recognized Codex or Claude Code conversation." : nil)
    }

    public var body: some View {
        Menu {
            Button("In Current Directory") { choose(.currentDirectory) }
                .disabled(disabledReason != nil)
                .accessibilityIdentifier("agentFork.currentDirectory")
            Button("In Other Directory…") { choose(.otherDirectory) }
                .disabled(disabledReason != nil || !allowsOtherDirectory)
                .accessibilityIdentifier("agentFork.otherDirectory")
            Button("In New Worktree…") { choose(.worktree) }
                .disabled(disabledReason != nil)
                .accessibilityIdentifier("agentFork.worktree")
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
    @State private var directory: String
    @State private var targetProviderID: String?
    @State private var acceptsCleanWorktree = false
    @State private var showsDirectoryBrowser: Bool
    @State private var isCreatingDirectory = false
    @State private var isLoading = false
    @State private var isLaunching = false
    @State private var errorMessage: String?
    @State private var request: ForkAgentSession?

    public init(configuration: AgentForkConfiguration) {
        self.configuration = configuration
        self._sourceID = State(initialValue: configuration.sources.first?.paneID ?? "")
        self._directory = State(initialValue: configuration.sources.first?.workingDirectory ?? "")
        self._showsDirectoryBrowser = State(initialValue: configuration.destination == .otherDirectory)
        let agentName = configuration.sources.first?.pluginID == "codex" ? "codex" : "claude"
        self._forkName = State(initialValue: configuration.destination == .worktree ? "\(agentName)-\(UUID().uuidString.prefix(8).lowercased())" : "\(agentName) fork")
    }

    private var source: AgentForkSource? {
        configuration.sources.first { $0.paneID == sourceID }
    }

    private var title: String {
        switch configuration.destination {
        case .currentDirectory:
            "Fork in Current Directory"
        case .otherDirectory:
            "Fork in Other Directory"
        case .worktree:
            "Fork in New Worktree"
        }
    }

    private var canLaunch: Bool {
        guard source != nil, !isLoading, !isLaunching, !isCreatingDirectory else { return false }
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
            showsDirectoryBrowser = configuration.destination == .otherDirectory
            isCreatingDirectory = false
            targetProviderID = nil
            preparation = nil
            errorMessage = nil
            guard let source else { return }
            directory = source.workingDirectory
            isLoading = true
            defer {
                if sourceID == source.paneID {
                    isLoading = false
                }
            }
            do {
                let prepared = try await configuration.prepare(source)
                try Task.checkCancellation()
                preparation = prepared
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
        .onChange(of: forkName) {
            if request != nil {
                errorMessage = nil
            }
            request = nil
        }
        .onChange(of: acceptsCleanWorktree) { request = nil }
        .onChange(of: directory) {
            errorMessage = nil
            request = nil
        }
        .onChange(of: targetProviderID) { request = nil }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.headline)
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
                switch configuration.destination {
                case .currentDirectory,
                     .worktree:
                    Text(source.workingDirectory).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                case .otherDirectory:
                    if let directorySource = configuration.directorySource {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Directory on Host", text: $directory, prompt: Text(source.workingDirectory))
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                            #if os(iOS)
                                .textInputAutocapitalization(.never)
                            #endif
                                .disabled(isLaunching || isCreatingDirectory)
                                .accessibilityLabel("Fork directory on Host")
                                .accessibilityIdentifier("agentFork.directory")
                            if !SessionDirectoryPath.isValid(directory) {
                                Text("Enter an absolute Host directory or ~/… without control characters.")
                                    .font(.caption).foregroundStyle(.red)
                            }
                            DisclosureGroup("Choose Directory…", isExpanded: $showsDirectoryBrowser) {
                                if showsDirectoryBrowser {
                                    SessionDirectoryBrowser(
                                        path: $directory, source: directorySource, isCreatingDirectory: $isCreatingDirectory
                                    )
                                    .padding(.top, 8)
                                }
                            }
                            .disabled(isLaunching || isCreatingDirectory)
                            Text("Defaults to the source directory. The copied conversation opens in this directory on the Host.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Forking into another directory is unavailable on this Host.")
                            .font(.callout).foregroundStyle(.red)
                    }
                }
                Text("Opens a new conversation with the saved history. The original Agent keeps running; no prompt is sent automatically.")
                    .font(.callout)
            }
            if let providers = preparation?.providers, !providers.isEmpty {
                Picker("Target Provider", selection: $targetProviderID) {
                    Text("Current CLI configuration").tag(String?.none)
                    ForEach(providers) { provider in
                        Text(provider.name).tag(Optional(provider.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(isLaunching)
                .accessibilityIdentifier("agentFork.provider")
                Text("The source conversation root stays unchanged; only the copied conversation's Provider changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                #if os(iOS)
                    Text(configuration.destination == .worktree ? "Window / Worktree Name" : "Window Name")
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
                Text(configuration.destination == .worktree ? "Used for the window, branch and worktree directory." : "Used for the new window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if configuration.destination == .worktree {
                worktreeFields
            }
            if isLoading || isLaunching {
                ProgressView(isLaunching ? "Creating Fork…" : "Checking source…").controlSize(.small)
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
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
            WorktreeReview(
                plan: worktree,
                name: forkName,
                allowUncommittedChanges: $acceptsCleanWorktree,
                acknowledgementIdentifier: "agentFork.allowUncommittedChanges"
            )
            .disabled(isLaunching)
        } else if let reason = preparation?.worktreeUnavailableReason {
            Text("New worktree is unavailable: \(reason)\nYou can still fork in an existing directory.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func makeRequest() throws -> ForkAgentSession {
        guard let source else { throw AgentForkError("Choose a source Agent.") }
        return try configuration.forkRequest(
            source: source, preparation: preparation, name: forkName,
            allowUncommittedChanges: acceptsCleanWorktree,
            targetProviderID: targetProviderID,
            directory: directory
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
