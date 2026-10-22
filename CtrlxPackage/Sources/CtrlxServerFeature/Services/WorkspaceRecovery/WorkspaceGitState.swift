import Foundation
import GitWorkbench
import Observation

struct WorkspaceGitState: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        var path: String
        var staged: Bool
    }

    var directory: String
    var view: String
    var file: File?
    var historyBranch: String?
    var commitID: String?
    var commitFile: String?
    var stashID: String?
    var stashFile: String?
    var commitMessage: String

    @MainActor
    init(directory: String, store: GitWorkbenchStore) {
        let state = store.state
        self.directory = directory
        self.view = state.activeView.rawValue
        self.file = state.repo.files.first { $0.id == state.selectedFileID }.map { .init(path: $0.path, staged: $0.isStaged) }
        self.historyBranch = state.historyBranch
        self.commitID = state.selectedCommitID
        self.commitFile = state.commits.first { $0.id == state.selectedCommitID }?.files.first { $0.id == state.selectedCommitFileID }?.path
        // Live providers use object IDs, never the reusable stash@{N} ordinal.
        self.stashID = state.selectedStashID.flatMap { WorkspaceGitProvider.isObjectID($0) ? $0 : nil }
        self.stashFile = state.stashes.first { $0.id == state.selectedStashID }?.files.first { $0.id == state.selectedStashFileID }?.path
        self.commitMessage = state.commitMessage
    }

    @MainActor
    func restoreSelection(in store: GitWorkbenchStore) async throws {
        guard let view = WorkspaceView(rawValue: view) else {
            throw WorkspaceRecoveryError("The saved Git view is unsupported.")
        }
        store.select(view)
        switch view {
        case .changes:
            if let file {
                guard let selected = store.state.repo.files.first(where: { $0.path == file.path && $0.isStaged == file.staged }) else {
                    throw WorkspaceRecoveryError("The saved Git change is unavailable: \(file.path)")
                }
                store.select(file: selected.id)
            }
        case .history:
            if let historyBranch {
                if let branch = store.state.branches.first(where: { $0.name == historyBranch }) {
                    await store.showHistory(of: branch)
                } else if let branch = store.state.remoteBranches.first(where: { $0.id == historyBranch }) {
                    await store.showHistory(of: branch)
                } else {
                    throw WorkspaceRecoveryError("The saved Git branch is unavailable: \(historyBranch)")
                }
                if store.state.toast?.style == .error {
                    throw WorkspaceRecoveryError("Unable to load the saved Git history: \(historyBranch)")
                }
            }
            if let commitID {
                guard let commit = store.state.commits.first(where: { $0.id == commitID }) else {
                    throw WorkspaceRecoveryError("The saved Git commit is unavailable: \(commitID)")
                }
                let selected = try commitFile.map { path in
                    guard let file = commit.files.first(where: { $0.path == path }) else {
                        throw WorkspaceRecoveryError("The saved commit file is unavailable: \(path)")
                    }
                    return file
                }
                await store.selectCommit(commit.id)
                if let selected {
                    store.selectCommitFile(selected.id)
                }
            }
        case .stashes:
            if let stashID {
                guard let stash = store.state.stashes.first(where: { $0.id == stashID }) else {
                    throw WorkspaceRecoveryError("The saved Stash is unavailable: \(stashID)")
                }
                let selected = try stashFile.map { path in
                    guard let file = stash.files.first(where: { $0.path == path }) else {
                        throw WorkspaceRecoveryError("The saved Stash file is unavailable: \(path)")
                    }
                    return file
                }
                await store.selectStash(stash.id)
                if let selected {
                    store.selectStashFile(selected.id)
                }
            }
        }
        try Task.checkCancellation()
    }
}

/// A cached Git store and its one-time restoration, owned by one native scene.
@MainActor @Observable
final class GitStoreEntry {
    let path: String
    let store: GitWorkbenchStore
    let retainsRecoveredDirectory: Bool
    private(set) var pendingRecovery: WorkspaceGitState?
    private(set) var recoveryIssue: String?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(path: String, provider: any GitWorkbenchProvider, configuration: WorkbenchConfiguration, recovery: WorkspaceGitState? = nil) {
        let pendingRecovery = recovery?.directory == path ? recovery : nil
        self.path = path
        self.retainsRecoveredDirectory = pendingRecovery != nil
        self.pendingRecovery = pendingRecovery
        self.store = GitWorkbenchStore(provider: WorkspaceGitProvider.recovering(provider, state: pendingRecovery), configuration: configuration)
        if let pendingRecovery {
            store.setCommitMessage(pendingRecovery.commitMessage)
        }
    }

    var snapshot: WorkspaceGitState {
        if var pendingRecovery {
            pendingRecovery.commitMessage = store.state.commitMessage
            return pendingRecovery
        }
        return WorkspaceGitState(directory: path, store: store)
    }

    func load() async {
        if let loadTask {
            await loadTask.value
            return
        }
        // The eager badge load and the Git view share this finite operation. A
        // disappearing view must not strand another caller's restoration spinner.
        let task = Task { await performLoad() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad() async {
        if pendingRecovery != nil {
            store.dismissToast()
        }
        await store.reload()
        guard let pendingRecovery, !Task.isCancelled else { return }
        guard store.hasLoaded, store.state.toast?.style != .error else {
            recoveryIssue = "Unable to load the saved Git directory: \(path)"
            return
        }
        do {
            try await pendingRecovery.restoreSelection(in: store)
            self.pendingRecovery = nil
            recoveryIssue = nil
        } catch is CancellationError {
            // Keep the original selection for the owning view's next task.
            return
        } catch {
            recoveryIssue = error.localizedDescription
        }
    }

    func openWithoutSavedSelection() {
        pendingRecovery = nil
        recoveryIssue = nil
    }
}
