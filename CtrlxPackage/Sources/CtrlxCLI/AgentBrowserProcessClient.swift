import Darwin
import Dependencies
import DependenciesMacros
import Foundation

/// Kernel identity, not argv[0], a tmux pane, or an inherited environment token.
struct AgentBrowserProcess: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let uid: uid_t
    let executable: String
    let startSeconds: UInt64
    let startMicros: UInt64

    var runtimeKey: String { "\(pid)-\(startSeconds)-\(startMicros)" }

    func isSameRuntime(as other: Self) -> Bool {
        pid == other.pid && uid == other.uid && executable == other.executable
            && startSeconds == other.startSeconds && startMicros == other.startMicros
    }
}

@DependencyClient
struct AgentBrowserProcessClient: Sendable {
    var inspect: @Sendable (Int32) throws -> AgentBrowserProcess

    /// The nearest native Codex owns the call. A nested Codex must never borrow
    /// its parent's group, even if it inherited CTRLX_BROWSER_CONTEXT.
    func callingCodex(from firstPID: Int32, uid: uid_t) throws -> AgentBrowserProcess {
        var pid = firstPID
        var visited = Set<Int32>()
        for _ in 0..<64 {
            guard pid > 1, visited.insert(pid).inserted else { break }
            let process = try inspect(pid)
            guard process.pid == pid, process.uid == uid else { break }
            if URL(fileURLWithPath: process.executable).lastPathComponent == "codex" {
                try validate(process)
                return process
            }
            pid = process.parentPID
        }
        throw AgentBrowserTransport.Failure(
            "Cannot identify a calling Codex process. Run this browser action from a local Codex tool; no tab was selected or changed."
        )
    }

    func validate(_ process: AgentBrowserProcess) throws {
        guard try process.isSameRuntime(as: inspect(process.pid)) else {
            throw AgentBrowserTransport.Failure("Calling Codex exited or changed identity. No browser action was sent.")
        }
    }
}

extension AgentBrowserProcessClient: DependencyKey {
    static let liveValue = Self(inspect: { pid in
        func info() throws -> proc_bsdinfo {
            var value = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, Int32(MemoryLayout.size(ofValue: value)))
                == MemoryLayout.size(ofValue: value) else {
                throw AgentBrowserTransport.Failure("Cannot inspect browser caller process \(pid); refusing to guess its identity.")
            }
            return value
        }
        let before = try info()
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro, not imported by Swift.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
            throw AgentBrowserTransport.Failure("Cannot read browser caller executable \(pid).")
        }
        let after = try info()
        guard before.pbi_start_tvsec == after.pbi_start_tvsec,
              before.pbi_start_tvusec == after.pbi_start_tvusec,
              before.pbi_uid == after.pbi_uid else {
            throw AgentBrowserTransport.Failure("Browser caller changed while resolving its identity.")
        }
        return AgentBrowserProcess(
            pid: pid, parentPID: Int32(after.pbi_ppid), uid: after.pbi_uid,
            executable: String(decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self),
            startSeconds: after.pbi_start_tvsec, startMicros: after.pbi_start_tvusec
        )
    })
}
