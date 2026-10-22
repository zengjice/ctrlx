import CtrlxCommon
import CtrlxPluginProtocol
import Darwin
import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct WorkspaceAgentProcessClient: Sendable {
    var invocation: @Sendable (_ processID: String, _ runtimeID: String) async throws -> AgentResumeInvocation
    var version: @Sendable (_ executable: String) async -> String?
}

extension WorkspaceAgentProcessClient: DependencyKey {
    static let liveValue: Self = {
        let reader = WorkspaceAgentProcessReader()
        return Self(invocation: { try await reader.invocation(processID: $0, runtimeID: $1) }, version: { await reader.version($0) })
    }()
}

private actor WorkspaceAgentProcessReader {
    @Dependency(ProcessRunner.self) private var processes
    private var versions: [String: (modified: Date?, size: UInt64, value: String?)] = [:]

    func version(_ executable: String) async -> String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: executable)
        let modified = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        if let known = versions[executable], known.modified == modified, known.size == size {
            return known.value
        }
        do {
            let result = try await processes.run(executable: executable, arguments: ["--version"], environment: nil, timeout: 5)
            let text = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = result.isSuccess && text.count <= 100 && !text.contains("\n") ? text : nil
            versions[executable] = (modified, size, value)
            return value
        } catch {
            return nil
        }
    }

    func invocation(processID: String, runtimeID: String) async throws -> AgentResumeInvocation {
        guard let pid = Int32(processID), AgentSessionIdentityClient.processRuntimeID(processID) == runtimeID else {
            throw WorkspaceRecoveryError("The Agent process changed before its startup configuration could be recorded.")
        }
        var path = [UInt8](repeating: 0, count: 4_096)
        let count = proc_pidpath(pid, &path, UInt32(path.count))
        guard count > 0, let executable = String(bytes: path.prefix { $0 != 0 }, encoding: .utf8), executable.hasPrefix("/") else {
            throw WorkspaceRecoveryError("The Agent executable could not be identified.")
        }
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 4, length <= 2 * 1_024 * 1_024 else {
            throw WorkspaceRecoveryError("The Agent startup configuration is unavailable.")
        }
        var bytes = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &length, nil, 0) == 0 else {
            throw WorkspaceRecoveryError("The Agent startup configuration could not be read.")
        }
        let parsed = try WorkspaceAgentProcessArguments.parse(Data(bytes.prefix(length)))
        let cliVersion = await version(executable)
        guard AgentSessionIdentityClient.processRuntimeID(processID) == runtimeID else {
            throw WorkspaceRecoveryError("The Agent process changed while its startup configuration was being recorded.")
        }
        return AgentResumeInvocation(
            executable: executable,
            arguments: Array(parsed.arguments.dropFirst()),
            configurationRoots: parsed.configurationRoots,
            providerID: parsed.providerID,
            version: cliVersion
        )
    }
}

enum WorkspaceAgentProcessArguments {
    struct Parsed: Equatable {
        var arguments: [String]
        var configurationRoots: [String: String]
        var providerID: String?
    }

    static func parse(_ data: Data) throws -> Parsed {
        guard data.count >= 4 else { throw WorkspaceRecoveryError("Invalid Agent process argument data.") }
        let argc = data.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0, argc <= 8_192 else { throw WorkspaceRecoveryError("Invalid Agent process argument count.") }
        let bytes = Array(data)
        var offset = 4
        func string() throws -> String {
            guard
                offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0),
                let value = String(bytes: bytes[offset..<end], encoding: .utf8) else {
                throw WorkspaceRecoveryError("Incomplete Agent process arguments.")
            }
            offset = end + 1
            return value
        }
        _ = try string() // Kernel executable path precedes argv and padding.
        while offset < bytes.count, bytes[offset] == 0 {
            offset += 1
        }
        var arguments: [String] = []
        for _ in 0..<argc {
            try arguments.append(string())
        }
        var roots: [String: String] = [:]
        var providerID: String?
        var hasEnvironment = false
        while offset < bytes.count {
            if bytes[offset] == 0 {
                offset += 1
                continue
            }
            let entry = try string()
            guard let equal = entry.firstIndex(of: "=") else { continue }
            hasEnvironment = true
            let name = String(entry[..<equal])
            let value = String(entry[entry.index(after: equal)...])
            if name == AgentProviderEnvironment.markerKey {
                guard !value.isEmpty, value.utf8.count <= 128, providerID == nil || providerID == value else {
                    throw WorkspaceRecoveryError("The Agent Provider identity is not unambiguous.")
                }
                providerID = value
                continue
            }
            guard name == "CODEX_HOME" || name == "CLAUDE_CONFIG_DIR" else { continue }
            guard value.hasPrefix("/"), roots[name] == nil || roots[name] == value else {
                throw WorkspaceRecoveryError("The Agent configuration directory is not an unambiguous absolute path.")
            }
            roots[name] = value
        }
        // macOS may return only argv for protected processes. That is not
        // evidence that CODEX_HOME / CLAUDE_CONFIG_DIR was unset.
        guard hasEnvironment else { throw WorkspaceRecoveryError("The Agent process environment is unavailable; its configuration directory cannot be verified.") }
        return Parsed(arguments: arguments, configurationRoots: roots, providerID: providerID)
    }
}
