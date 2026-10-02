import CtrlxCommon
import CtrlxNetworking
import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct AgentForkWorktreeClient: Sendable {
    var inspect: @Sendable (_ directory: String) async throws -> AgentForkWorktree
    var create: @Sendable (_ directory: String, _ request: ForkAgentSession.Worktree) async throws -> String
}

extension AgentForkWorktreeClient: DependencyKey {
    static let liveValue = Self(
        inspect: { try await AgentForkWorktreeManager.shared.inspect($0) },
        create: { try await AgentForkWorktreeManager.shared.create($0, request: $1) }
    )
}

actor AgentForkWorktreeManager {
    static let shared = AgentForkWorktreeManager()
    @Dependency(ProcessRunner.self) private var processes

    func inspect(_ directory: String) async throws -> AgentForkWorktree {
        let rootPath = try await git(directory, ["rev-parse", "--show-toplevel"])
        let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path
        let head = try await git(directory, ["rev-parse", "--verify", "HEAD"])
        let worktrees = try await git(directory, ["worktree", "list", "--porcelain", "-z"])
        guard let primary = worktrees.split(separator: "\0").first(where: { $0.hasPrefix("worktree ") }) else {
            throw AgentForkError("Git did not return a primary worktree.")
        }
        let canonical = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        guard canonical == root || canonical.hasPrefix(root + "/") else {
            throw AgentForkError("The source directory is outside its Git worktree.")
        }
        let relative = canonical == root ? "" : String(canonical.dropFirst(root.count + 1))
        let dirty = try await git(root, ["status", "--porcelain", "--untracked-files=normal"])
        return AgentForkWorktree(
            repositoryRoot: root, primaryRoot: URL(fileURLWithPath: String(primary.dropFirst("worktree ".count))).resolvingSymlinksInPath().path,
            head: head, relativeDirectory: relative, hasUncommittedChanges: !dirty.isEmpty
        )
    }

    func create(_ directory: String, request: ForkAgentSession.Worktree) async throws -> String {
        guard AgentForkWorktree.isValidName(request.name) else {
            throw AgentForkError("Use a worktree name starting with a letter or number, followed by letters, numbers, ., _ or -.")
        }
        let plan = try await inspect(directory)
        try validate(plan, request: request)
        let path = plan.directory(name: request.name)
        let branch = request.name
        let files = FileManager.default
        guard !files.fileExists(atPath: path) else { throw AgentForkError("Worktree directory already exists: \(path). Choose a different name.") }
        _ = try await git(plan.repositoryRoot, ["check-ref-format", "--branch", branch])
        let existing = try await processes.run("/usr/bin/git", ["-C", plan.repositoryRoot, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], nil, 15)
        guard existing.exitCode == 1 else {
            throw AgentForkError(existing.isSuccess ? "Branch already exists: \(branch). Choose a different name." : existing.stderrString)
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard parent.resolvingSymlinksInPath().path == plan.primaryRoot + "/.worktrees" else {
            throw AgentForkError("The .worktrees directory must not redirect outside the primary repository.")
        }
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        try await ignoreWorktrees(in: plan.primaryRoot, name: request.name)
        try validate(try await inspect(directory), request: request)
        do {
            _ = try await git(plan.repositoryRoot, ["worktree", "add", "-b", branch, "--", path, plan.head], timeout: 120)
            let target = plan.relativeDirectory.isEmpty ? path : (path as NSString).appendingPathComponent(plan.relativeDirectory)
            @Dependency(SessionDirectoryClient.self) var directories
            return try await directories.resolve(target)
        } catch {
            throw AgentForkError("Worktree creation did not finish: \(error.localizedDescription)\nCheck \(path) and branch \(branch) before retrying; any created worktree is kept.")
        }
    }

    private func validate(_ plan: AgentForkWorktree, request: ForkAgentSession.Worktree) throws {
        guard plan.head == request.expectedHead else { throw AgentForkError("Source HEAD changed. Reopen Fork to review the new base commit.") }
        guard !plan.hasUncommittedChanges || request.allowUncommittedChanges else {
            throw AgentForkError("The source has uncommitted or untracked files. Confirm that they will not be copied into the new worktree.")
        }
    }

    private func ignoreWorktrees(in root: String, name: String) async throws {
        if try await isWorktreeIgnored(in: root, name: name) { return }
        let excludePath = try await git(root, ["rev-parse", "--path-format=absolute", "--git-path", "info/exclude"])
        let url = URL(fileURLWithPath: excludePath)
        let files = FileManager.default
        var contents = files.fileExists(atPath: excludePath) ? try String(contentsOf: url, encoding: .utf8) : ""
        if !contents.hasSuffix("\n"), !contents.isEmpty { contents += "\n" }
        if !contents.components(separatedBy: "\n").contains("/.worktrees/") { contents += "/.worktrees/\n" }
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        guard try await isWorktreeIgnored(in: root, name: name) else {
            throw AgentForkError("Git ignore rules override info/exclude for .worktrees/\(name). Add /.worktrees/ after conflicting rules in the repository's .gitignore before retrying. No worktree was created.")
        }
    }

    private func isWorktreeIgnored(in root: String, name: String) async throws -> Bool {
        let result = try await processes.run("/usr/bin/git", ["-C", root, "check-ignore", "--quiet", "--no-index", ".worktrees/\(name)/"], nil, 15)
        guard result.exitCode == 0 || result.exitCode == 1 else { throw AgentForkError(result.stderrString) }
        return result.isSuccess
    }

    private func git(_ directory: String, _ arguments: [String], timeout: TimeInterval = 15) async throws -> String {
        let result = try await processes.runOrThrow(executable: "/usr/bin/git", arguments: ["-C", directory] + arguments, timeout: timeout)
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
