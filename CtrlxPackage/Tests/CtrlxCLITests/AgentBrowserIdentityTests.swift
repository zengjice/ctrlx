import Darwin
import Dependencies
import Foundation
import Testing
@testable import CtrlxCLI

struct AgentBrowserIdentityTests {
    private func process(_ pid: Int32, parent: Int32 = 1, name: String = "codex", start: UInt64 = 100, uid: uid_t = 501) -> AgentBrowserProcess {
        .init(pid: pid, parentPID: parent, uid: uid, executable: "/fixture/\(name)", startSeconds: start, startMicros: 42)
    }

    private func client(_ values: [AgentBrowserProcess]) -> AgentBrowserProcessClient {
        let table = Dictionary(uniqueKeysWithValues: values.map { ($0.pid, $0) })
        return .init(inspect: { pid in
            guard let value = table[pid] else { throw AgentBrowserTransport.Failure("Process unavailable") }
            return value
        })
    }

    @Test(arguments: ["codex", "claude", "home/.local/share/claude/versions/2.1.276", "Caskroom/claude-code/2.1.276/claude"])
    func nativeAgentThroughToolShellAndHelper(_ name: String) throws {
        let agent = process(10, name: name)
        let processes = client([agent, process(11, parent: 10, name: "codex-code-mode-host"), process(12, parent: 11, name: "zsh")])
        #expect(try processes.callingAgent(from: 12, uid: 501) == agent)
        #expect(agent.agentName == (name == "codex" ? "Codex" : "Claude Code"))
    }

    @Test(arguments: ["codex", "claude"], ["codex", "claude"])
    func nestedAgentsUseNearestNativeProcess(_ outerName: String, _ innerName: String) throws {
        let inner = process(20, parent: 11, name: innerName)
        let processes = client([process(10, name: outerName), process(11, parent: 10, name: "zsh"), inner, process(21, parent: 20, name: "sh")])
        #expect(try processes.callingAgent(from: 21, uid: 501) == inner)
    }

    @Test func independentInstancesDoNotUseSharedShellOrPane() throws {
        let processes = client([process(9, name: "tmux"), process(10, parent: 9), process(20, parent: 9, name: "claude")])
        let a = try processes.callingAgent(from: 10, uid: 501)
        let b = try processes.callingAgent(from: 20, uid: 501)
        #expect(a.runtimeKey != b.runtimeKey)
    }

    @Test(arguments: ["zsh", "node", "codex-code-mode-host", "not-codex", "codex-fake", "claude-helper", "not-claude", "claude-code",
                      "other/versions/2.1.276", "claude/versions/helper", "claude/versions/2.1.276/helper", "claude/versions/2x1x276"])
    func unsupportedExecutablesDoNotGrantIdentity(_ name: String) {
        #expect(throws: AgentBrowserTransport.Failure.self) {
            try client([process(10, name: name)]).callingAgent(from: 10, uid: 501)
        }
    }

    @Test func unknownForeignAndCyclicAncestryFailsClosed() {
        for processes in [client([]), client([process(10, uid: 502)]), client([process(10, name: "claude", uid: 502)]), client([process(10, parent: 10, name: "zsh")])] {
            #expect(throws: AgentBrowserTransport.Failure.self) { try processes.callingAgent(from: 10, uid: 501) }
        }
        let longChain = (10...74).map { process(Int32($0), parent: Int32($0 + 1), name: "zsh") } + [process(75)]
        #expect(throws: AgentBrowserTransport.Failure.self) { try client(longChain).callingAgent(from: 10, uid: 501) }
    }

    @Test(arguments: ["codex", "claude"])
    func exitedAndReusedPIDCannotValidateOldOwner(_ name: String) {
        let old = process(10, name: name)
        for processes in [client([]), client([process(10, name: name, start: 101)]), client([process(10, name: "zsh")])] {
            #expect(throws: AgentBrowserTransport.Failure.self) { try processes.validate(old) }
        }
    }

    @Test func liveInspectorMatchesThisProcess() throws {
        let value = try AgentBrowserProcessClient.liveValue.inspect(getpid())
        #expect(value.pid == getpid())
        #expect(value.parentPID == getppid())
        #expect(value.uid == getuid())
        #expect(value.startSeconds > 0)
        #expect(value.executable.hasPrefix("/"))
        try AgentBrowserProcessClient.liveValue.validate(value)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-identity-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test(arguments: ["codex", "claude"])
    func repeatedCallsReusePrivateContextAndPIDReuseIsIsolated(_ name: String) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = process(10, name: name)
        let first = try AgentBrowserTransport.withRunContext(for: owner, root: root) { url, value in
            try AgentBrowserTransport.privatePath(url.path, type: S_IFREG)
            try AgentBrowserTransport.privatePath(url.deletingLastPathComponent().path, type: S_IFDIR)
            value["epoch"] = "test-registration"
            try AgentBrowserTransport.writePrivateJSON(value, to: url)
            return value
        }
        let again = try AgentBrowserTransport.withRunContext(for: owner, root: root) { _, value in value }
        #expect(first["run"] as? String == again["run"] as? String)
        #expect(first["secret"] as? String == again["secret"] as? String)
        #expect(again["epoch"] as? String == "test-registration")
        for new in [process(11, name: name), process(10, name: name, start: 101)] {
            let next = try AgentBrowserTransport.withRunContext(for: new, root: root) { _, value in value }
            #expect(first["run"] as? String != next["run"] as? String)
            #expect(first["secret"] as? String != next["secret"] as? String)
            #expect(next["epoch"] == nil)
        }
    }

    @Test func concurrentFirstCallsCreateOnlyOneIdentityAndRegistration() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = process(10)
        let identities = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try AgentBrowserTransport.withRunContext(for: owner, root: root) { url, value in
                        if value["epoch"] == nil {
                            value["epoch"] = UUID().uuidString
                            try AgentBrowserTransport.writePrivateJSON(value, to: url)
                        }
                        return "\(value["run"] ?? "")/\(value["epoch"] ?? "")"
                    }
                }
            }
            var values = Set<String>()
            for try await value in group { values.insert(value) }
            return values
        }
        #expect(identities.count == 1)
    }

    @Test func mismatchedSavedIdentityAndSymlinkAreRejected() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = process(10)
        let url = try AgentBrowserTransport.withRunContext(for: owner, root: root) { url, value in
            value["pid"] = 99
            try AgentBrowserTransport.writePrivateJSON(value, to: url)
            return url
        }
        #expect(throws: AgentBrowserTransport.Failure.self) {
            try AgentBrowserTransport.withRunContext(for: owner, root: root) { _, _ in }
        }
        let link = root.appendingPathComponent("symlink-root")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url.deletingLastPathComponent())
        #expect(throws: AgentBrowserTransport.Failure.self) {
            try AgentBrowserTransport.withRunContext(for: owner, root: link) { _, _ in }
        }
    }

    @Test func actionRejectsUnidentifiedCallerBeforeFilesystemOrBrowserAccess() throws {
        try withDependencies {
            $0[AgentBrowserProcessClient.self] = client([process(getppid(), name: "zsh", uid: getuid())])
        } operation: {
            #expect(throws: AgentBrowserTransport.Failure.self) {
                try AgentBrowserTransport.perform(["command": "tabs"])
            }
        }
    }

    @Test(arguments: ["codex", "claude"])
    func firstRegistrationActivatesTheSelectedHostBeforeDiscovery(_ name: String) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = process(getppid(), name: name, uid: getuid())
        struct HostUnavailable: Error {}
        try withDependencies {
            $0[AgentBrowserProcessClient.self] = client([owner])
            $0[AgentBrowserHostClient.self] = .init(prepare: { requested in
                #expect(requested == root)
                #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("endpoint.json").path))
                throw HostUnavailable()
            })
        } operation: {
            #expect(throws: HostUnavailable.self) { try AgentBrowserTransport.registeredContext(root: root) }
        }
        let saved = try AgentBrowserTransport.withRunContext(for: owner, root: root) { _, value in value }
        #expect(saved["socket"] == nil)
        #expect(saved["epoch"] == nil)
    }

    @Test(arguments: ["codex", "claude"], ["read", "click", "fill", "navigate", "close", "upstream", "batch"])
    func pageOperationsNeverActivateOrRegisterAgainstANewHost(_ name: String, _ operation: String) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = process(getppid(), name: name, uid: getuid())
        try AgentBrowserTransport.withRunContext(for: owner, root: root) { url, value in
            value["socket"] = "/fixture/old-control.sock"
            value["epoch"] = "old-host"
            try AgentBrowserTransport.writePrivateJSON(value, to: url)
        }
        try withDependencies {
            $0[AgentBrowserProcessClient.self] = client([owner])
            $0[AgentBrowserHostClient.self] = .init(prepare: { _ in
                Issue.record("An existing grant must not bootstrap a different browser host")
                throw AgentBrowserTransport.Failure("Unexpected startup")
            })
        } operation: {
            let (_, value) = try AgentBrowserTransport.registeredContext(for: operation, root: root)
            #expect(value["socket"] as? String == "/fixture/old-control.sock")
            #expect(value["epoch"] as? String == "old-host")
        }
    }

    @Test(arguments: ["codex", "claude"], ["tabs", "open"])
    func entryPointsKeepTheGrantWhenTheRuntimeHasNotChanged(_ name: String, _ operation: String) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = process(getppid(), name: name, uid: getuid())
        let original = try AgentBrowserTransport.withRunContext(for: owner, root: root) { url, value in
            value["socket"] = "/fixture/control.sock"
            value["epoch"] = "same-host"
            value["engine"] = "ctrlx"
            try AgentBrowserTransport.writePrivateJSON(value, to: url)
            return value
        }
        try withDependencies {
            $0[AgentBrowserProcessClient.self] = client([owner])
            $0[AgentBrowserHostClient.self] = .init(prepare: { requested in
                #expect(requested == root)
                try AgentBrowserTransport.writePrivateJSON([
                    "socket": "/fixture/control.sock", "epoch": "same-host", "mode": "embedded",
                ], to: root.appendingPathComponent("endpoint.json"))
            })
        } operation: {
            // No real socket exists: an unchanged epoch must not re-register.
            let (_, value) = try AgentBrowserTransport.registeredContext(for: operation, root: root)
            #expect(value["run"] as? String == original["run"] as? String)
            #expect(value["secret"] as? String == original["secret"] as? String)
            #expect(value["engine"] as? String == "ctrlx")
        }
    }

    @Test(arguments: ["tabs", "open"])
    func hostPreparationFailurePreservesTheOldGrant(_ operation: String) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = process(getppid(), uid: getuid())
        let url = try AgentBrowserTransport.withRunContext(for: owner, root: root) { url, value in
            value["socket"] = "/fixture/old.sock"
            value["epoch"] = "old-host"
            try AgentBrowserTransport.writePrivateJSON(value, to: url)
            return url
        }
        let original = try Data(contentsOf: url)
        struct WrongHost: Error { }
        try withDependencies {
            $0[AgentBrowserProcessClient.self] = client([owner])
            $0[AgentBrowserHostClient.self] = .init(prepare: { _ in throw WrongHost() })
        } operation: {
            #expect(throws: WrongHost.self) {
                try AgentBrowserTransport.registeredContext(for: operation, root: root)
            }
        }
        #expect(try Data(contentsOf: url) == original)
    }
}
