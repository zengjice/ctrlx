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
    var modelContext: @Sendable (_ processID: String, _ runtimeID: String, _ directory: String, _ discoveryCommand: String?) async throws -> AgentModelContext = { _, _, _, _ in
        throw AgentModelError("The Agent's model discovery environment is unavailable.")
    }
}

extension WorkspaceAgentProcessClient: DependencyKey {
    static let liveValue: Self = {
        let reader = WorkspaceAgentProcessReader()
        return Self(invocation: { try await reader.invocation(processID: $0, runtimeID: $1) }, version: { await reader.version($0) }, modelContext: { try await reader.modelContext(processID: $0, runtimeID: $1, directory: $2, discoveryCommand: $3) })
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
        let startup = try readStartup(processID: processID, runtimeID: runtimeID, allowsRemovedExecutable: false)
        let cliVersion = await version(startup.executable)
        try verifyProcess(processID, runtimeID)
        return invocation(startup, version: cliVersion)
    }

    func modelContext(processID: String, runtimeID: String, directory: String, discoveryCommand: String?) async throws -> AgentModelContext {
        let startup = try readStartup(processID: processID, runtimeID: runtimeID, allowsRemovedExecutable: true)
        let executable = try discoveryExecutable(startup, directory: directory, command: discoveryCommand)
        let cliVersion = await version(executable)
        try Task.checkCancellation()
        try verifyProcess(processID, runtimeID)
        return AgentModelContext(invocation: invocation(startup, version: nil), environment: startup.parsed.environment, directory: directory, discoveryExecutable: executable, discoveryVersion: cliVersion)
    }

    private struct Startup {
        let executable: String
        let parsed: WorkspaceAgentProcessArguments.Parsed
    }

    private func invocation(_ startup: Startup, version: String?) -> AgentResumeInvocation {
        AgentResumeInvocation(executable: startup.executable, arguments: Array(startup.parsed.arguments.dropFirst()), configurationRoots: startup.parsed.configurationRoots, providerID: startup.parsed.providerID, version: version)
    }

    private func verifyProcess(_ processID: String, _ runtimeID: String) throws {
        guard AgentSessionIdentityClient.processRuntimeID(processID) == runtimeID else {
            throw WorkspaceRecoveryError("The Agent process changed while its startup configuration was being recorded.")
        }
    }

    private func readStartup(processID: String, runtimeID: String, allowsRemovedExecutable: Bool) throws -> Startup {
        try verifyProcess(processID, runtimeID)
        guard let pid = Int32(processID) else { throw WorkspaceRecoveryError("Invalid Agent process identity.") }
        var path = [UInt8](repeating: 0, count: 4_096)
        let count = proc_pidpath(pid, &path, UInt32(path.count))
        let removed = count <= 0 && errno == ENOENT
        if removed && !allowsRemovedExecutable {
            throw WorkspaceRecoveryError("The Agent CLI was updated or removed while this session was running. Restart the Agent and resume this conversation.")
        }
        guard count > 0 || removed else { throw WorkspaceRecoveryError("The Agent executable could not be identified.") }
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
        let executable = removed ? parsed.executable : String(bytes: path.prefix { $0 != 0 }, encoding: .utf8)
        guard let executable, executable.hasPrefix("/") else { throw WorkspaceRecoveryError("The Agent executable could not be identified.") }
        try verifyProcess(processID, runtimeID)
        return Startup(executable: executable, parsed: parsed)
    }

    private func discoveryExecutable(_ startup: Startup, directory: String, command: String?) throws -> String {
        let manager = FileManager.default
        if manager.isExecutableFile(atPath: startup.executable) {
            return startup.executable
        }
        guard let command else {
            throw AgentModelError("This session's model discovery CLI is unavailable. Use /model in this terminal.")
        }
        if let original = startup.parsed.arguments.first, original.hasPrefix("/"), URL(fileURLWithPath: original).lastPathComponent == command, manager.isExecutableFile(atPath: original) {
            return original
        }
        for component in (startup.parsed.environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false) {
            let root = component.hasPrefix("/") ? URL(fileURLWithPath: String(component)) : URL(fileURLWithPath: directory).appendingPathComponent(String(component))
            let candidate = root.appendingPathComponent(command).path
            if manager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw AgentModelError("No installed model discovery CLI was found in this session's PATH. Use /model in this terminal.")
    }
}

enum WorkspaceAgentProcessArguments {
    struct Parsed: Equatable {
        var executable = ""
        var arguments: [String]
        var configurationRoots: [String: String]
        var providerID: String?
        var environment: [String: String] = [:]
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
        let executable = try string() // Kernel executable path survives removal of the running file.
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
        var environment: [String: String] = [:]
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
            environment[name] = value
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
        return Parsed(executable: executable, arguments: arguments, configurationRoots: roots, providerID: providerID, environment: environment)
    }
}
