import CtrlxCommon
import Dependencies
import Foundation
import GitWorkbench

/// The upstream provider identifies Stashes by a reusable ordinal. Bind its loaded
/// entries and diffs to immutable objects before they become recovery descriptors.
struct WorkspaceGitProvider: GitWorkbenchProvider {
    let base: any GitWorkbenchProvider
    var stashIdentities: (@Sendable () async throws -> [String: String])?
    var recovery: WorkspaceGitState?

    static func live(base: any GitWorkbenchProvider, directory: String) -> Self {
        @Dependency(ProcessRunner.self) var processes
        return Self(base: base, stashIdentities: {
            let output = try await processes.runOrThrow(
                executable: "/usr/bin/git", arguments: ["-C", directory, "stash", "list", "--format=%gd %H"], timeout: 10
            ).stdoutString
            var result: [String: String] = [:]
            for line in output.split(separator: "\n") {
                let fields = line.split(separator: " ")
                guard fields.count == 2, isObjectID(String(fields[1])), result[String(fields[0])] == nil else {
                    throw WorkspaceRecoveryError("Git returned an invalid Stash identity.")
                }
                result[String(fields[0])] = String(fields[1])
            }
            return result
        })
    }

    static func recovering(_ provider: any GitWorkbenchProvider, state: WorkspaceGitState?) -> any GitWorkbenchProvider {
        guard let state else { return provider }
        var result = (provider as? Self) ?? Self(base: provider)
        result.recovery = state
        return result
    }

    static func isObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    func loadStashes() async throws -> [Stash] {
        guard let stashIdentities else { return try await base.loadStashes() }
        let before = try await stashIdentities()
        let entries = try await base.loadStashes()
        guard try before == (await stashIdentities()), entries.allSatisfy({ before[$0.ref] != nil }) else {
            throw WorkspaceRecoveryError("Stashes changed while loading. Refresh Git to try again.")
        }
        return entries.map { entry in
            var result = entry
            result.id = before[entry.ref] ?? entry.id
            return result
        }
    }

    func loadHistory(of ref: String?, before: Commit.ID?, limit: Int) async throws -> [Commit] {
        var commits = try await base.loadHistory(of: ref, before: before, limit: limit)
        // The saved preview may now be older than the first page. Load that exact
        // object, without scanning all history or changing HEAD/the checked-out branch.
        if
            before == nil, ref == recovery?.historyBranch, let id = recovery?.commitID,
            Self.isObjectID(id), !commits.contains(where: { $0.id == id }) {
            do {
                if let saved = try await base.loadHistory(of: id, before: nil, limit: 1).first, saved.id == id {
                    commits.append(saved)
                }
            } catch {
                // Selection restoration reports the missing object; ordinary history remains usable.
                return commits
            }
        }
        return commits
    }

    func loadStatus() async throws -> RepositoryStatus {
        try await base.loadStatus()
    }

    func loadBranches() async throws -> [Branch] {
        try await base.loadBranches()
    }

    func loadRemoteBranches() async throws -> [RemoteBranch] {
        try await base.loadRemoteBranches()
    }

    func loadDiff(_ request: DiffRequest) async throws -> FileDiff {
        try await base.loadDiff(request)
    }

    func repositoryChanges() -> AsyncStream<Void>? {
        base.repositoryChanges()
    }

    /// Existing actions remain explicit UI intents; restoration calls only read APIs.
    func stage(_ files: [FileChange]) async throws {
        try await base.stage(files)
    }

    func unstage(_ files: [FileChange]) async throws {
        try await base.unstage(files)
    }

    func discard(_ file: FileChange) async throws {
        try await base.discard(file)
    }

    func commit(message: String, staged: [FileChange]) async throws -> Commit {
        try await base.commit(message: message, staged: staged)
    }

    func pull() async throws -> SyncResult {
        try await base.pull()
    }

    func push() async throws -> SyncResult {
        try await base.push()
    }

    func fetch() async throws -> SyncResult {
        try await base.fetch()
    }

    func switchBranch(to branch: Branch) async throws {
        try await base.switchBranch(to: branch)
    }

    func checkoutRemoteBranch(_ branch: RemoteBranch) async throws {
        try await base.checkoutRemoteBranch(branch)
    }

    func checkout(_ commit: Commit) async throws {
        try await base.checkout(commit)
    }

    func resetHEAD(to commit: Commit, mode: ResetMode) async throws {
        try await base.resetHEAD(to: commit, mode: mode)
    }

    func revert(_ commit: Commit) async throws {
        try await base.revert(commit)
    }

    func cherryPick(_ commit: Commit) async throws {
        try await base.cherryPick(commit)
    }

    func createBranch(named name: String, at commit: Commit) async throws {
        try await base.createBranch(named: name, at: commit)
    }

    func createTag(named name: String, at commit: Commit) async throws {
        try await base.createTag(named: name, at: commit)
    }

    private func currentStash(_ stash: Stash) async throws -> Stash {
        guard let stashIdentities else { return stash }
        let identities = try await stashIdentities()
        guard identities[stash.ref] == stash.id else {
            throw WorkspaceRecoveryError("The selected Stash has moved or disappeared. Refresh Git before using it.")
        }
        return stash
    }

    func applyStash(_ stash: Stash) async throws {
        try await base.applyStash(currentStash(stash))
    }

    func popStash(_ stash: Stash) async throws {
        try await base.popStash(currentStash(stash))
    }

    func dropStash(_ stash: Stash) async throws {
        try await base.dropStash(currentStash(stash))
    }
}
