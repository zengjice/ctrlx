import Clocks
import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CodexPluginCore
#if os(macOS)
    import Darwin
#endif

struct CodexAccountTests {
    private let date = Date(timeIntervalSince1970: 1_792_232_400)
    private let signedIn = Data(#"{"account":{"type":"chatgpt","email":"person@example.test","planType":"pro"}}"#.utf8)
    private let limits = Data(#"{"accountId":"workspace","rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":54,"windowDurationMins":10080,"resetsAt":1792816153},"secondary":null,"credits":{"balance":"12.50","unlimited":false}}}}"#.utf8)

    private func auth(user: String = "person", key: String? = nil) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": ["chatgpt_account_id": "workspace", "chatgpt_user_id": user]])
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        var object: [String: Any] = ["auth_mode": "chatgpt", "tokens": ["account_id": "workspace", "id_token": "header.\(payload).signature"]]
        if let key {
            object["OPENAI_API_KEY"] = key
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test
    func usesActualWindowDurationAndKeepsCreditsSeparate() throws {
        let identity = try #require(CodexAccountParser.identity(auth: auth()))
        let result = try CodexAccountParser.accounts(reply: .init(account: signedIn, limits: limits), identity: identity, sourceID: "config", label: "Default", date: date)
        let account = try #require(result.first)
        #expect(account.identity == .init(providerID: "openai", accountID: "person", workspaceID: "workspace", poolID: "codex"))
        #expect(account.windows.count == 1)
        #expect(account.windows[0].title == "7 days")
        #expect(account.windows[0].remainingPercent(at: date) == 46)
        #expect(account.credits?.balance == "12.50")
        #expect(account.quotaObservedAt == date)
        let json = try String(decoding: JSONEncoder().encode(account), as: UTF8.self)
        #expect(!json.contains("id_token"))
        #expect(!json.contains("signature"))
    }

    @Test
    func incompleteOrMismatchedIdentityNeverMerges() throws {
        #expect(CodexAccountParser.identity(auth: Data(#"{"tokens":{"account_id":"workspace"}}"#.utf8)) == nil)
        #expect(try CodexAccountParser.identity(auth: auth(key: "test-key")) == nil)
        let mismatched = CodexAccountParser.AuthIdentity(accountID: "another-workspace", userID: "person")
        let result = try CodexAccountParser.accounts(reply: .init(account: signedIn, limits: limits), identity: mismatched, sourceID: "config", label: "Default", date: date)
        #expect(result.first?.identity == nil)
        #expect(result.first?.windows.count == 1)
    }

    @Test
    func apiKeysAndSignedOutHaveNoInventedQuota() throws {
        for input in [#"{"account":{"type":"apiKey"}}"#, #"{"account":null}"#] {
            let result = try CodexAccountParser.accounts(reply: .init(account: Data(input.utf8), limits: nil), identity: nil, sourceID: "config", label: "Default", date: date)
            #expect(result.first?.windows.isEmpty == true)
            #expect(result.first?.availability == .unsupported)
            #expect(result.first?.identity == nil)
        }
    }

    @Test(arguments: [false, true])
    func refreshFailurePreservesTheOriginalObservation(timeout: Bool) async throws {
        let auth = try auth()
        let signedIn = signedIn
        let limits = limits
        let calls = Calls()
        try await withDependencies {
            $0.date.now = date
            $0[AccountConfigurationClient.self].read = { _ in auth }
            $0[CodexAccountClient.self].read = { _, _ in
                if await calls.next() > 1 {
                    throw timeout ? CodexAccountError.timeout : CodexAccountError.unavailable
                }
                return .init(account: signedIn, limits: limits)
            }
        } operation: {
            let reporter = CodexAccountReporter()
            let roots = [URL(fileURLWithPath: "/private/test-codex")]
            let first = await reporter.accounts(command: "fixture", roots: roots)
            let second = await withDependencies {
                $0.date.now = date.addingTimeInterval(120)
            } operation: { await reporter.accounts(command: "fixture", roots: roots) }
            #expect(first.first?.availability == .available)
            #expect(second.first?.availability == .failed)
            #expect(second.first?.authentication == .unknown)
            #expect(second.first?.windows == first.first?.windows)
            #expect(second.first?.quotaObservedAt == first.first?.quotaObservedAt)
            #expect(second.first?.detail?.contains("timed out") == timeout)
        }
    }

    private actor Calls {
        var count = 0
        func next() -> Int {
            count += 1
            return count
        }
    }

    #if os(macOS)
        @Test
        func closedChildStdinThrowsWithoutTerminatingHost() async {
            await #expect(processExitsWith: .success) {
                // Test the default signal disposition without changing the test runner.
                signal(SIGPIPE, SIG_DFL)
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-dashboard-closed-stdin-\(UUID())")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let executable = directory.appendingPathComponent("fixture codex")
                let script = #"""
                #!/usr/bin/env python3
                import json, os, sys, time
                from pathlib import Path
                (Path(__file__).parent/'pid').write_text(str(os.getpid()))
                request=json.loads(sys.stdin.readline())
                os.close(0)
                print(json.dumps({'id':request['id'],'result':{}}),flush=True)
                time.sleep(10)
                """#
                try Data(script.utf8).write(to: executable)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
                do {
                    _ = try await withDependencies {
                        $0.continuousClock = ContinuousClock()
                    } operation: { try await CodexAccountClient.liveValue.read(executable.path, directory.path) }
                    exit(2)
                } catch {
                    let failure = error as NSError
                    let posix = failure.userInfo[NSUnderlyingErrorKey] as? NSError ?? failure
                    guard posix.domain == NSPOSIXErrorDomain, posix.code == Int(EPIPE) else { exit(3) }
                }
                let pid = try Int32(String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8))
                guard let pid, kill(pid, 0) == -1, errno == ESRCH else { exit(4) }
            }
        }

        @Test
        func rpcOnlyReadsAccountAndStopsItsChild() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-dashboard-rpc-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appendingPathComponent("fixture codex")
            let script = #"""
            #!/usr/bin/env python3
            import json, os, sys
            from pathlib import Path
            root=Path(__file__).parent
            (root/'pid').write_text(str(os.getpid()))
            for line in sys.stdin:
                request=json.loads(line)
                method=request['method']
                with (root/'methods').open('a') as f: f.write(method+'\n')
                if method=='initialized': continue
                if method=='initialize': result={}
                elif method=='account/read': result={'account':{'type':'chatgpt','email':'fixture@example.test'}}
                elif method=='account/rateLimits/read': result={'accountId':'fixture','rateLimitsByLimitId':{}}
                else: sys.exit(10)
                print(json.dumps({'method':'account/updated','params':{}}),flush=True)
                print(json.dumps({'id':request['id'],'result':result}),flush=True)
            """#
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            // Repeated reads exercise process cleanup across executor hops.
            for _ in 0..<5 {
                let reply = try await withDependencies {
                    $0.continuousClock = ContinuousClock()
                } operation: { try await CodexAccountClient.liveValue.read(executable.path, directory.path) }
                #expect(reply.limits != nil)
                let pid = try #require(Int32(String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8)))
                #expect(kill(pid, 0) == -1)
                #expect(errno == ESRCH)
            }
            let methods = try String(contentsOf: directory.appendingPathComponent("methods"), encoding: .utf8)
            #expect(methods.split(separator: "\n").map(String.init) == Array(repeating: ["initialize", "initialized", "account/read", "account/rateLimits/read"], count: 5).flatMap { $0 })
        }

        @Test(arguments: [false, true])
        func stalledReadEndsOnTimeoutOrCancellation(cancel: Bool) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-dashboard-stalled-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appendingPathComponent("fixture codex")
            let script = #"""
            #!/usr/bin/env python3
            import os, sys, time
            from pathlib import Path
            sys.stdin.readline()
            (Path(__file__).parent/'pid').write_text(str(os.getpid()))
            time.sleep(60)
            """#
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let clock = TestClock()
            try await withDependencies {
                $0.continuousClock = clock
            } operation: {
                let task = Task { try await CodexAccountClient.liveValue.read(executable.path, directory.path) }
                let watchdog = Task {
                    do { try await Task.sleep(for: .seconds(5)) }
                    catch { return }
                    task.cancel()
                    Issue.record("Account query did not finish within the test deadline")
                }
                defer { watchdog.cancel()
                    task.cancel()
                }
                let pidFile = directory.appendingPathComponent("pid")
                for _ in 0..<200 {
                    if FileManager.default.fileExists(atPath: pidFile.path) {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
                defer {
                    if kill(pid, 0) == 0 {
                        kill(pid, SIGKILL)
                    }
                }
                for _ in 0..<200 {
                    do { try await clock.checkSuspension() }
                    catch { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                if cancel {
                    task.cancel()
                } else {
                    await clock.advance(by: .seconds(20))
                }
                do {
                    _ = try await task.value
                    Issue.record("Stalled account query unexpectedly succeeded")
                } catch {
                    if cancel {
                        #expect(error is CancellationError)
                    } else if case CodexAccountError.timeout = error { }
                    else {
                        Issue.record("Expected timeout, got \(error)")
                    }
                }
                // Timeout/cancellation does not block on Foundation's exit notification.
                for _ in 0..<200 {
                    if kill(pid, 0) == -1 {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(kill(pid, 0) == -1)
                #expect(errno == ESRCH)
            }
        }
    #endif
}
