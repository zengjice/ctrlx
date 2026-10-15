import CtrlxCommon
import CtrlxNetworking
import Dependencies
import DependenciesMacros
import Foundation

struct WorktreeStatusRefresh: Sendable {
    struct Location: Sendable {
        let root: String
        let branch: String?
    }

    var locations: [String: Location] = [:]
    var repositories: [RepositoryWorktreeStatus] = []
}

@DependencyClient
struct WorktreeStatusClient: Sendable {
    var refresh: @Sendable (_ paths: [String]) async -> WorktreeStatusRefresh = { _ in .init() }
}

extension WorktreeStatusClient: DependencyKey {
    static let liveValue = Self(refresh: { await WorktreeStatusReader.shared.refresh(paths: $0) })
}

/// All filesystem and Git access stays on the Host. One inspection per common
/// Git directory also covers worktrees that have no running tmux session.
actor WorktreeStatusReader {
    static let shared = WorktreeStatusReader()
    @Dependency(ProcessRunner.self) private var processes

    private struct Comparison: Hashable {
        let repository: String
        let main: String
        let head: String
    }

    private var counts: [Comparison: Int] = [:]

    func refresh(paths: [String]) async -> WorktreeStatusRefresh {
        var result = WorktreeStatusRefresh()
        var rootsByPath: [String: String] = [:]
        var directoryByRepository: [String: String] = [:]
        var rootsByRepository: [String: Set<String>] = [:]
        var branchesByRoot: [String: String] = [:]
        for path in Set(paths).sorted() {
            // A pane can leave Git or enter a nested repository between polls;
            // resolve its actual repository instead of caching path prefixes.
            guard
                let root = try? await git(path, ["rev-parse", "--show-toplevel"]), !root.isEmpty,
                let common = try? await git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
            else { continue }
            let canonicalRoot = canonical(root)
            rootsByPath[path] = canonicalRoot
            directoryByRepository[canonical(common)] = canonicalRoot
            rootsByRepository[canonical(common), default: []].insert(canonicalRoot)
        }

        var usedComparisons: Set<Comparison> = []
        for (repository, directory) in directoryByRepository.sorted(by: { $0.key < $1.key }) {
            do {
                let entries = try Self.parse(await git(directory, ["worktree", "list", "--porcelain", "-z"]))
                    .filter { !$0.prunable && !$0.bare && FileManager.default.fileExists(atPath: $0.path) }
                let main = try? await git(directory, ["rev-parse", "--verify", "refs/heads/main^{commit}"])
                var worktrees: [WorktreeMergeStatus] = []
                for entry in entries {
                    let listedPath = canonical(entry.path)
                    let path: String
                    if listedPath == repository {
                        do {
                            path = try await primaryWorktreePath(repository: repository, knownRoots: rootsByRepository[repository] ?? [])
                        } catch {
                            worktrees.append(.init(
                                path: listedPath, branch: entry.branch,
                                unavailableReason: "Unable to resolve worktree directory: \(error.localizedDescription)"
                            ))
                            continue
                        }
                    } else {
                        path = listedPath
                    }
                    branchesByRoot[path] = entry.branch ?? "(detached)"
                    var count: Int?
                    var reason: String?
                    if entry.branch == nil {
                        reason = "Detached HEAD — no branch to compare."
                    } else if let main, let head = entry.head, !head.allSatisfy({ $0 == "0" }) {
                        let comparison = Comparison(repository: repository, main: main, head: head)
                        usedComparisons.insert(comparison)
                        if let cached = counts[comparison] {
                            count = cached
                        } else {
                            do {
                                let output = try await git(directory, ["rev-list", "--count", "\(main)..\(head)", "--"])
                                guard let value = Int(output), value >= 0 else {
                                    throw WorktreeStatusError("Git returned an invalid commit count.")
                                }
                                counts[comparison] = value
                                count = value
                            } catch {
                                reason = "Unable to compare with main: \(error.localizedDescription)"
                            }
                        }
                    } else {
                        reason = main == nil ? "Local main is unavailable." : "This worktree has no commits yet."
                    }
                    worktrees.append(.init(path: path, branch: entry.branch, pendingCommitCount: count, unavailableReason: reason))
                }
                result.repositories.append(.init(id: repository, worktrees: worktrees))
            } catch {
                let reason = "Unable to read worktrees: \(error.localizedDescription)"
                let known = (rootsByRepository[repository] ?? []).sorted().map {
                    WorktreeMergeStatus(path: $0, branch: nil, unavailableReason: reason)
                }
                result.repositories.append(.init(id: repository, worktrees: known, unavailableReason: reason))
            }
        }
        counts = counts.filter { usedComparisons.contains($0.key) }
        for (path, root) in rootsByPath {
            result.locations[path] = .init(root: root, branch: branchesByRoot[root])
        }
        return result
    }

    private func primaryWorktreePath(repository: String, knownRoots: Set<String>) async throws -> String {
        // --separate-git-dir has no reverse pointer to its checkout. Only an
        // observed root whose own Git directory is the common directory is primary.
        for root in knownRoots.sorted() {
            if let gitDirectory = try? await git(root, ["rev-parse", "--absolute-git-dir"]), canonical(gitDirectory) == repository {
                return root
            }
        }
        // Absorbed submodules have core.worktree, so Git can resolve their
        // primary checkout even when only a linked worktree was observed.
        return try canonical(await git(repository, ["rev-parse", "--show-toplevel"]))
    }

    struct Entry: Equatable {
        var path = ""
        var head: String?
        var branch: String?
        var prunable = false
        var bare = false
    }

    /// -z preserves spaces, newlines and non-ASCII paths without Git quoting.
    static func parse(_ output: String) -> [Entry] {
        var entries: [Entry] = []
        var entry = Entry()
        for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty {
                if !entry.path.isEmpty {
                    entries.append(entry)
                }
                entry = Entry()
            } else if field.hasPrefix("worktree ") {
                entry.path = String(field.dropFirst(9))
            } else if field.hasPrefix("HEAD ") {
                entry.head = String(field.dropFirst(5))
            } else if field.hasPrefix("branch refs/heads/") {
                entry.branch = String(field.dropFirst(18))
            } else if field == "prunable" || field.hasPrefix("prunable ") {
                entry.prunable = true
            } else if field == "bare" {
                entry.bare = true
            }
        }
        if !entry.path.isEmpty {
            entries.append(entry)
        }
        return entries
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func git(_ directory: String, _ arguments: [String]) async throws -> String {
        let result = try await processes.runOrThrow(executable: "/usr/bin/git", arguments: ["-C", directory] + arguments, timeout: 5)
        // Remove only Git's final line ending; spaces may belong to a path.
        let output = result.stdoutString
        return output.hasSuffix("\n") ? String(output.dropLast()) : output
    }
}

private struct WorktreeStatusError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) {
        self.errorDescription = message
    }
}
