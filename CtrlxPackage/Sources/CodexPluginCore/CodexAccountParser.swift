import CtrlxNetworking
import Foundation

enum CodexAccountParser {
    struct AccountResponse: Decodable {
        struct Account: Decodable {
            let type: String
            let email: String?
            let planType: String?
        }

        let account: Account?
    }

    struct AuthIdentity: Equatable, Sendable {
        let accountID: String
        let userID: String
    }

    static func identity(auth: Data?) -> AuthIdentity? {
        guard
            let auth,
            let root = try? JSONSerialization.jsonObject(with: auth) as? [String: Any],
            root["OPENAI_API_KEY"] as? String == nil,
            root["auth_mode"] as? String == nil || root["auth_mode"] as? String == "chatgpt",
            let tokens = root["tokens"] as? [String: Any],
            let account = tokens["account_id"] as? String, !account.isEmpty,
            let token = tokens["id_token"] as? String else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard
            let bytes = Data(base64Encoded: payload),
            let claims = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            let metadata = claims["https://api.openai.com/auth"] as? [String: Any],
            metadata["chatgpt_account_id"] as? String == account,
            let user = metadata["chatgpt_user_id"] as? String, !user.isEmpty else { return nil }
        return AuthIdentity(accountID: account, userID: user)
    }

    static func accounts(reply: CodexAccountReply, identity: AuthIdentity?, sourceID: String, label: String, date: Date) throws -> [DashboardAccount] {
        let response = try JSONDecoder().decode(AccountResponse.self, from: reply.account)
        var base = DashboardAccount(
            id: sourceID,
            pluginID: "codex",
            providerName: "Codex",
            label: response.account?.email ?? label,
            configurationLabel: label,
            authentication: response.account == nil ? .signedOut : .signedIn
        )
        guard response.account?.type == "chatgpt" else {
            base.availability = .unsupported
            base.detail = response.account == nil ? "Sign in with Codex to see account information." : "This sign-in method does not provide subscription quotas."
            return [base]
        }
        guard let data = reply.limits else { throw CodexAccountError.invalidResponse }
        let result = try JSONDecoder().decode(Limits.self, from: data)
        let buckets = result.rateLimitsByLimitId ?? result.rateLimits.map { [$0.limitId ?? "codex": $0] } ?? [:]
        guard !buckets.isEmpty else {
            base.detail = "Waiting for quota information from Codex."
            return [base]
        }
        return buckets.keys.sorted().compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            var account = base
            account.id = sourceID + ":" + key
            if let identity, result.accountId == identity.accountID {
                account.identity = .init(providerID: "openai", accountID: identity.userID, workspaceID: identity.accountID, poolID: key)
            }
            account.quotaObservedAt = date
            account.windows = [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { id, window in
                guard let window, window.usedPercent.isFinite, window.usedPercent >= 0 else { return nil }
                return DashboardQuotaWindow(
                    id: id,
                    title: windowTitle(window.windowDurationMins),
                    usedPercent: window.usedPercent,
                    durationMinutes: window.windowDurationMins,
                    resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }
                )
            }
            account.availability = account.windows.isEmpty ? .waiting : .available
            account.detail = bucket.limitName ?? (key == "codex" ? nil : key)
            account.credits = bucket.credits.map { .init(balance: $0.balance, unlimited: $0.unlimited ?? false) }
            account.limitReached = bucket.rateLimitReachedType.map { !$0.isEmpty }
            if account.credits != nil {
                account.availability = .available
            }
            return account
        }
    }

    private static func windowTitle(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "Usage window" }
        if minutes % 1_440 == 0 {
            return "\(minutes / 1_440) days"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60) hours"
        }
        return "\(minutes) minutes"
    }

    private struct Limits: Decodable {
        let accountId: String?
        let rateLimits: Bucket?
        let rateLimitsByLimitId: [String: Bucket]?
    }

    private struct Bucket: Decodable {
        let limitId: String?
        let limitName: String?
        let primary: Window?
        let secondary: Window?
        let credits: Credits?
        let rateLimitReachedType: String?
    }

    private struct Credits: Decodable {
        let balance: String?
        let unlimited: Bool?
    }

    private struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: Double?
    }
}
