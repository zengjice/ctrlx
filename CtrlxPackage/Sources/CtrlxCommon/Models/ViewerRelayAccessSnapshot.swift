import CtrlxNetworking
import Foundation

/// A settings-page snapshot. Credentials stay scoped to each pairing even when
/// several successful queries describe the same account's allowance.
struct ViewerRelayAccessSnapshot: Sendable {
    struct Response: Sendable {
        let status: RelayAccessStatus?
        let error: String?

        var quota: RelayQuotaStatus? {
            status?.quota ?? status?.failure?.quota
        }

        func canReconnect(restriction: RelayAccessFailure?) -> Bool {
            guard let status, error == nil, status.failure == nil else { return false }
            if let restriction {
                return RelayAccessRecovery.canResume(restriction, status: status)
            }
            return !status.metered || (status.quota?.enabled == true && (status.quota?.remainingBytes ?? 0) > 0)
        }
    }

    struct Account: Identifiable {
        struct ID: Hashable {
            let server: String
            let accountID: String
        }

        let id: ID
        var quota: RelayQuotaStatus
        var hosts: [PairedHost]
    }

    let server: String
    let hosts: [PairedHost]
    let responses: [String: Response]

    var accounts: [Account] {
        var result: [Account] = []
        for host in hosts {
            guard let quota = responses[host.id]?.quota else { continue }
            let id = Account.ID(server: server, accountID: quota.accountID)
            if let index = result.firstIndex(where: { $0.id == id }) {
                result[index].hosts.append(host)
                let previous = result[index].quota
                if quota.period > previous.period || (quota.period == previous.period && quota.revision > previous.revision) {
                    result[index].quota = quota
                }
            } else {
                result.append(Account(id: id, quota: quota, hosts: [host]))
            }
        }
        return result
    }

    var unresolvedHosts: [PairedHost] {
        hosts.filter { responses[$0.id]?.status?.metered != false && responses[$0.id]?.quota == nil }
    }

    func reconnectableHostIDs(in account: Account.ID?, candidates: [PairedHost], restriction: (String) -> RelayAccessFailure?) -> [String] {
        candidates.compactMap { host in
            guard let response = responses[host.id], response.canReconnect(restriction: restriction(host.id)) else { return nil }
            if let account {
                guard server == account.server, response.quota?.accountID == account.accountID else { return nil }
            }
            return host.id
        }
    }

    static func fetch(server: String, hosts: [PairedHost], client: RelayAccessClient) async -> [String: Response] {
        await withTaskGroup(of: (String, Response).self) { group in
            for host in hosts {
                group.addTask {
                    do {
                        let status = try await client.status(server, host.id, "viewer")
                        return (host.id, Response(status: status, error: nil))
                    } catch {
                        return (host.id, Response(status: nil, error: error.localizedDescription))
                    }
                }
            }
            var responses: [String: Response] = [:]
            for await (id, response) in group {
                responses[id] = response
            }
            return responses
        }
    }
}
