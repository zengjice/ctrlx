import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import ClaudeCodePluginCore

struct ClaudeAccountTests {
    private let status = Data(#"{"loggedIn":true,"authMethod":"claude.ai","email":"a@example.test","orgId":"org"}"#.utf8)
    private let profile = Data(#"{"account":{"uuid":"person","email":"a@example.test"},"organization":{"uuid":"org"}}"#.utf8)
    private let usage = Data(#"{"five_hour":{"utilization":24,"resets_at":"2026-10-18T00:00:00.123Z"},"seven_day":{"utilization":60,"resets_at":"2026-10-20T00:00:00Z"},"seven_day_sonnet":{"utilization":100,"resets_at":"2026-10-20T00:00:00Z"},"extra_usage":{"is_enabled":false,"utilization":null},"future":[],"other":null}"#.utf8)

    @Test
    func parsesWindowsAndAdditionalLimitsWithoutInventingMissingValues() throws {
        let values = try ClaudeAccountReporter.windows(usage)
        #expect(values.count == 3)
        #expect(values[0].id == "five_hour")
        #expect(values[0].resetsAt != nil)
        #expect(values[2].usedPercent == 100)
        #expect(values[1].durationMinutes == 10_080)
    }

    @Test
    func apiKeyNeverReadsCredentialsOrCallsSubscriptionService() async {
        await withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 1_792_232_400)
            $0[ClaudeAccountClient.self].status = { _, _, _ in Data(#"{"loggedIn":true,"authMethod":"api_key"}"#.utf8) }
            $0[ClaudeAccountClient.self].token = { _, _ in Issue.record("API key mode read OAuth credentials")
                return nil
            }
            $0[ClaudeAccountClient.self].request = { _, _ in Issue.record("API key mode queried subscription API")
                return Data()
            }
        } operation: {
            let result = await ClaudeAccountReporter().accounts(command: "fixture", roots: [URL(fileURLWithPath: "/private/claude-test")])
            #expect(result.first?.availability == .unsupported)
            #expect(result.first?.windows.isEmpty == true)
        }
    }

    @Test
    func verifiedProfileProducesSharedIdentityAndNoSecrets() async throws {
        let status = status, profile = profile, usage = usage
        try await withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 1_792_232_400)
            $0[ClaudeAccountClient.self].status = { _, _, _ in status }
            $0[ClaudeAccountClient.self].token = { _, _ in "fixture-credential" }
            $0[ClaudeAccountClient.self].request = { path, _ in path == "/api/oauth/profile" ? profile : usage }
        } operation: {
            let result = await ClaudeAccountReporter().accounts(command: "fixture", roots: [URL(fileURLWithPath: "/private/claude-test")])
            let account = try #require(result.first)
            #expect(account.identity == .init(providerID: "anthropic", accountID: "person", workspaceID: "org", poolID: "claude-code"))
            #expect(account.availability == .available)
            #expect(try !String(decoding: JSONEncoder().encode(result), as: UTF8.self).contains("fixture-credential"))
        }
    }

    @Test
    func credentialChangeDuringQueryDiscardsTheSample() async {
        let status = status, profile = profile, usage = usage
        let calls = Counter()
        await withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 1_792_232_400)
            $0[ClaudeAccountClient.self].status = { _, _, _ in status }
            $0[ClaudeAccountClient.self].token = { _, _ in await calls.next() == 1 ? "first" : "second" }
            $0[ClaudeAccountClient.self].request = { path, _ in path == "/api/oauth/profile" ? profile : usage }
        } operation: {
            let result = await ClaudeAccountReporter().accounts(command: "fixture", roots: [URL(fileURLWithPath: "/private/claude-test")])
            #expect(result.first?.identity == nil)
            #expect(result.first?.windows.isEmpty == true)
            #expect(result.first?.availability == .failed)
        }
    }

    @Test
    func failedRefreshRetainsOriginalSampleTime() async {
        let status = status, profile = profile, usage = usage
        let calls = Counter()
        await withDependencies {
            $0.date.now = Date(timeIntervalSince1970: 1_792_232_400)
            $0[ClaudeAccountClient.self].status = { _, _, _ in status }
            $0[ClaudeAccountClient.self].token = { _, _ in "credential" }
            $0[ClaudeAccountClient.self].request = { path, _ in
                if await calls.next() > 2 {
                    throw ClaudeAccountError.unavailable
                }
                return path == "/api/oauth/profile" ? profile : usage
            }
        } operation: {
            let reporter = ClaudeAccountReporter()
            let roots = [URL(fileURLWithPath: "/private/claude-test")]
            let first = await reporter.accounts(command: "fixture", roots: roots)
            let second = await reporter.accounts(command: "fixture", roots: roots)
            #expect(first.first?.availability == .available)
            #expect(second.first?.availability == .failed)
            #expect(second.first?.quotaObservedAt == first.first?.quotaObservedAt)
            #expect(second.first?.identity == first.first?.identity)
        }
    }

    private actor Counter {
        var value = 0
        func next() -> Int {
            value += 1
            return value
        }
    }
}
