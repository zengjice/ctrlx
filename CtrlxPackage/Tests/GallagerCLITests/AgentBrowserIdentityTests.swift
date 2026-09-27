import Darwin
import Dependencies
import Foundation
import Testing
@testable import GallagerCLI

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

    @Test func plainCodexThroughToolShellAndHelper() throws {
        let codex = process(10)
        let processes = client([codex, process(11, parent: 10, name: "codex-code-mode-host"), process(12, parent: 11, name: "zsh")])
        #expect(try processes.callingCodex(from: 12, uid: 501) == codex)
    }

    @Test func nestedCodexUsesNearestNativeProcess() throws {
        let inner = process(20, parent: 11)
        let processes = client([process(10), process(11, parent: 10, name: "zsh"), inner, process(21, parent: 20, name: "sh")])
        #expect(try processes.callingCodex(from: 21, uid: 501) == inner)
    }

    @Test func independentInstancesDoNotUseSharedShellOrPane() throws {
        let processes = client([process(9, name: "tmux"), process(10, parent: 9), process(20, parent: 9)])
        let a = try processes.callingCodex(from: 10, uid: 501)
        let b = try processes.callingCodex(from: 20, uid: 501)
        #expect(a.runtimeKey != b.runtimeKey)
    }

    @Test(arguments: ["zsh", "codex-code-mode-host", "not-codex", "codex-fake"])
    func nonCodexNamesDoNotGrantIdentity(_ name: String) {
        #expect(throws: AgentBrowserTransport.Failure.self) {
            try client([process(10, name: name)]).callingCodex(from: 10, uid: 501)
        }
    }

    @Test func unknownForeignAndCyclicAncestryFailsClosed() {
        for processes in [client([]), client([process(10, uid: 502)]), client([process(10, parent: 10, name: "zsh")])] {
            #expect(throws: AgentBrowserTransport.Failure.self) { try processes.callingCodex(from: 10, uid: 501) }
        }
        let longChain = (10...74).map { process(Int32($0), parent: Int32($0 + 1), name: "zsh") } + [process(75)]
        #expect(throws: AgentBrowserTransport.Failure.self) { try client(longChain).callingCodex(from: 10, uid: 501) }
    }

    @Test func exitedAndReusedPIDCannotValidateOldOwner() {
        let old = process(10)
        for processes in [client([]), client([process(10, start: 101)]), client([process(10, name: "zsh")])] {
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

    @Test func repeatedCallsReusePrivateContextAndPIDReuseIsIsolated() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = process(10)
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
        for new in [process(11), process(10, start: 101)] {
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
}
