import CtrlxSimulatorProtocol
import Darwin
import Dependencies
import DependenciesMacros
import Foundation

/// Kernel identity, not argv[0], a tmux pane, or an inherited environment token.
struct AgentBrowserProcess: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let uid: uid_t
    /// Absolute path, or an exact kernel executable name after its file is removed.
    let executable: String
    let startSeconds: UInt64
    let startMicros: UInt64

    var runtimeKey: String {
        "\(pid)-\(startSeconds)-\(startMicros)"
    }

    var agentName: String? {
        let path = URL(fileURLWithPath: executable)
        switch path.lastPathComponent {
        case "codex": return "Codex"
        case "claude": return "Claude Code"
        default:
            // Claude's native installer resolves its launcher to claude/versions/<version>.
            let directory = path.deletingLastPathComponent()
            guard
                directory.lastPathComponent == "versions",
                directory.deletingLastPathComponent().lastPathComponent == "claude",
                path.lastPathComponent.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { return nil }
            return "Claude Code"
        }
    }

    func isSameRuntime(as other: Self) -> Bool {
        pid == other.pid && uid == other.uid && AgentExecutableIdentity.matches(executable, other.executable)
            && startSeconds == other.startSeconds && startMicros == other.startMicros
    }
}

@DependencyClient
struct AgentBrowserProcessClient: Sendable {
    var inspect: @Sendable (Int32) throws -> AgentBrowserProcess

    /// The nearest supported native agent owns the call. A nested agent must never borrow
    /// its parent's group, even if it inherited CTRLX_BROWSER_CONTEXT.
    func callingAgent(from firstPID: Int32, uid: uid_t) throws -> AgentBrowserProcess {
        var pid = firstPID
        var visited = Set<Int32>()
        for _ in 0..<64 {
            guard pid > 1, visited.insert(pid).inserted else { break }
            let process = try inspect(pid)
            guard process.pid == pid, process.uid == uid else { break }
            if process.agentName != nil {
                try validate(process)
                return process
            }
            pid = process.parentPID
        }
        throw AgentBrowserTransport.Failure(
            "Cannot identify a calling agent process. Run this browser action from a local native Codex or Claude Code tool; no tab was selected or changed."
        )
    }

    func validate(_ process: AgentBrowserProcess) throws {
        guard try process.isSameRuntime(as: inspect(process.pid)) else {
            throw AgentBrowserTransport.Failure("Calling agent exited or changed identity. No browser action was sent.")
        }
    }
}

extension AgentBrowserProcessClient: DependencyKey {
    static let liveValue = Self(inspect: { pid in
        func info() throws -> proc_bsdinfo {
            var value = proc_bsdinfo()
            guard
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, Int32(MemoryLayout.size(ofValue: value)))
                == MemoryLayout.size(ofValue: value) else {
                throw AgentBrowserTransport.Failure("Cannot inspect browser caller process \(pid); refusing to guess its identity.")
            }
            return value
        }
        let before = try info()
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro, not imported by Swift.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &path, UInt32(path.count))
        let pathError = count > 0 ? 0 : errno
        let kernelName = withUnsafeBytes(of: before.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let after = try info()
        guard
            before.pbi_start_tvsec == after.pbi_start_tvsec,
            before.pbi_start_tvusec == after.pbi_start_tvusec,
            before.pbi_uid == after.pbi_uid, before.pbi_ppid == after.pbi_ppid,
            before.pbi_status != SZOMB, after.pbi_status != SZOMB,
            withUnsafeBytes(of: after.pbi_name, { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }) == kernelName else {
            throw AgentBrowserTransport.Failure("Browser caller changed while resolving its identity.")
        }
        let executablePath = count > 0 ? String(bytes: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) : nil
        guard let executable = AgentExecutableIdentity.resolve(path: executablePath, errorCode: pathError, kernelName: kernelName) else {
            throw AgentBrowserTransport.Failure("Cannot read browser caller executable \(pid) (errno \(pathError)).")
        }
        return AgentBrowserProcess(
            pid: pid, parentPID: Int32(after.pbi_ppid), uid: after.pbi_uid,
            executable: executable,
            startSeconds: after.pbi_start_tvsec, startMicros: after.pbi_start_tvusec
        )
    })
}
