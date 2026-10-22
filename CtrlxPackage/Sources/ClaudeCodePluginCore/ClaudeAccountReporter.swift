import CtrlxNetworking
import Dependencies
import Foundation

actor ClaudeAccountReporter {
    @Dependency(ClaudeAccountClient.self) private var client
    @Dependency(\.date.now) private var now
    /// Token comparison only protects the local cached observation during account changes.
    /// Credentials never become wire identities and are never written by this reporter.
    private var cache: [String: (token: String, account: DashboardAccount)] = [:]

    func accounts(command: String, roots: [URL]) async -> [DashboardAccount] {
        var result: [DashboardAccount] = []
        var seen: Set<String> = []
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        for root in roots.map(\.standardizedFileURL) where seen.insert(root.path).inserted {
            let isDefault = root.path == defaultPath
            let label = isDefault ? "Default" : root.lastPathComponent
            var base = DashboardAccount(id: root.path, pluginID: "claude-code", providerName: "Claude Code", label: label, configurationLabel: label)
            var token: String?
            var readStatus = false
            do {
                let status = try JSONDecoder().decode(Status.self, from: await client.status(command, root.path, isDefault))
                readStatus = true
                base.authentication = status.loggedIn ? .signedIn : .signedOut
                base.label = status.email ?? label
                guard status.loggedIn, status.authMethod == "claude.ai" else {
                    cache[root.path] = nil
                    base.availability = .unsupported
                    base.detail = status.loggedIn ? "This sign-in method does not provide subscription quotas." : "Sign in with Claude Code on this Host."
                    result.append(base)
                    continue
                }
                token = try await client.token(root.path, isDefault)
                guard let token, !token.isEmpty else { throw ClaudeAccountError.unavailable }
                let profile = try JSONDecoder().decode(Profile.self, from: await client.request("/api/oauth/profile", token))
                guard
                    profile.organization.uuid == status.orgId, profile.account.email == status.email,
                    !profile.account.uuid.isEmpty, !profile.organization.uuid.isEmpty else {
                    cache[root.path] = nil
                    throw ClaudeAccountError.authentication
                }
                let data = try await client.request("/api/oauth/usage", token)
                guard try await client.token(root.path, isDefault) == token else {
                    cache[root.path] = nil
                    throw ClaudeAccountError.authentication
                }
                base.identity = .init(providerID: "anthropic", accountID: profile.account.uuid, workspaceID: profile.organization.uuid, poolID: "claude-code")
                base.windows = try Self.windows(data)
                base.quotaObservedAt = now
                base.availability = base.windows.isEmpty ? .waiting : .available
                base.detail = base.windows.isEmpty ? "Waiting for subscription quota information." : nil
                cache[root.path] = (token, base)
                result.append(base)
            } catch {
                if let cached = cache[root.path], token == cached.token || !readStatus {
                    base = cached.account
                    if !readStatus {
                        base.authentication = .unknown
                    }
                } else {
                    cache[root.path] = nil
                }
                if case ClaudeAccountError.authentication = error {
                    base.authentication = .signedOut
                }
                base.availability = .failed
                base.detail = "Could not read Claude subscription quotas. Check sign-in and credential access on this Host."
                result.append(base)
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return result
    }

    static func windows(_ data: Data) throws -> [DashboardQuotaWindow] {
        guard let windows = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeAccountError.unavailable }
        let primary = ["five_hour", "seven_day"]
        let keys = primary + windows.keys.filter { !primary.contains($0) }.sorted()
        return keys.compactMap { key in
            guard let window = windows[key] as? [String: Any], let used = window["utilization"] as? Double, used.isFinite, used >= 0 else { return nil }
            let duration = key == "five_hour" ? 300 : key.hasPrefix("seven_day") ? 10_080 : nil
            let title = key == "five_hour" ? "5 hours" : key == "seven_day" ? "7 days" : key.replacingOccurrences(of: "_", with: " ").capitalized
            let reset = (window["resets_at"] as? String).flatMap { value in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
            }
            return .init(id: key, title: title, usedPercent: used, durationMinutes: duration, resetsAt: reset)
        }
    }

    private struct Status: Decodable {
        let loggedIn: Bool
        let authMethod: String
        let email: String?
        let orgId: String?
    }

    private struct Profile: Decodable {
        struct Account: Decodable { let uuid: String
            let email: String
        }

        struct Organization: Decodable { let uuid: String }
        let account: Account
        let organization: Organization
    }
}
