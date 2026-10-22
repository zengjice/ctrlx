import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation

actor CodexAccountReporter {
    @Dependency(CodexAccountClient.self) private var client
    @Dependency(AccountConfigurationClient.self) private var files
    @Dependency(\.date.now) private var now
    private var cached: [String: (identity: CodexAccountParser.AuthIdentity?, accounts: [DashboardAccount])] = [:]

    func accounts(command: String, roots: [URL]) async -> [DashboardAccount] {
        var result: [DashboardAccount] = []
        var seen: Set<String> = []
        for root in roots.map(\.standardizedFileURL) where seen.insert(root.path).inserted {
            let label = root.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path ? "Default" : root.lastPathComponent
            let authURL = root.appendingPathComponent("auth.json")
            var observedIdentity: CodexAccountParser.AuthIdentity?
            do {
                observedIdentity = try CodexAccountParser.identity(auth: await files.read(authURL))
                let reply = try await client.read(command, root.path)
                let after = try CodexAccountParser.identity(auth: await files.read(authURL))
                guard after == observedIdentity else {
                    cached[root.path] = nil
                    throw CodexAccountError.unavailable
                }
                let accounts = try CodexAccountParser.accounts(reply: reply, identity: after, sourceID: root.path, label: label, date: now)
                cached[root.path] = (after, accounts)
                result += accounts
            } catch {
                let failure: String
                if case CodexAccountError.timeout = error {
                    failure = "Codex quota refresh timed out."
                } else {
                    failure = "Could not refresh Codex quotas."
                }
                if let previous = cached[root.path], previous.identity == observedIdentity {
                    result += previous.accounts.map { account in
                        var account = account
                        account.availability = .failed
                        account.authentication = .unknown
                        account.detail = failure + " Showing the last observation."
                        return account
                    }
                } else {
                    result.append(.init(
                        id: root.path,
                        pluginID: "codex",
                        providerName: "Codex",
                        label: label,
                        configurationLabel: label,
                        availability: .failed,
                        detail: failure + " Check CLI sign-in and version."
                    ))
                }
            }
        }
        cached = cached.filter { seen.contains($0.key) }
        return result
    }
}
