import CtrlxNetworking
import Dependencies
import SwiftUI

@MainActor
public struct ViewerRelayAccessSettingsSections: View {
    let server: String
    let hosts: [PairedHost]
    let restriction: (String) -> RelayAccessFailure?
    let reconnect: @MainActor (String) async -> Void

    @Dependency(RelayAccessClient.self) private var client
    @State private var responses: [String: ViewerRelayAccessSnapshot.Response] = [:]
    @State private var loadedScope: Scope?
    @State private var working = false
    @State private var requestID = UUID()

    private struct Scope: Hashable {
        let server: String
        let hosts: [PairedHost]
    }

    private var scope: Scope {
        Scope(server: server, hosts: hosts)
    }

    public init(
        server: String,
        hosts: [PairedHost],
        restriction: @escaping (String) -> RelayAccessFailure?,
        reconnect: @escaping @MainActor (String) async -> Void
    ) {
        self.server = server
        self.hosts = hosts
        self.restriction = restriction
        self.reconnect = reconnect
    }

    public var body: some View {
        Group {
            if loadedScope == scope {
                let snapshot = ViewerRelayAccessSnapshot(server: server, hosts: hosts, responses: responses)
                ForEach(snapshot.accounts) { account in
                    Section {
                        RelayQuotaRows(quota: account.quota)
                        LabeledContent("Hosts", value: account.hosts.map(\.displayName).joined(separator: ", "))
                        ForEach(account.hosts) { host in
                            hostError(host)
                        }
                        Button("Check and Reconnect") {
                            Task { await refresh(hosts: account.hosts, account: account.id, retry: true) }
                        }
                        .disabled(working)
                        .accessibilityIdentifier("relay-quota-retry-\(account.quota.accountID)")
                    } header: {
                        Text("Relay Traffic · \(account.quota.accountName)")
                    } footer: {
                        Text("These Hosts share one allowance. Extra quota applies only to its month. Agent model quotas are separate.")
                    }
                }
                ForEach(snapshot.unresolvedHosts) { host in
                    Section {
                        hostError(host)
                        Button("Check and Reconnect") {
                            Task { await refresh(hosts: [host], retry: true) }
                        }
                        .disabled(working)
                    } header: {
                        Text("Relay Traffic · \(host.displayName)")
                    }
                }
            }
            if working || loadedScope != scope {
                Section("Relay Traffic") { ProgressView().controlSize(.small) }
            }
        }
        .task(id: scope) {
            requestID = UUID()
            loadedScope = scope
            responses = [:]
            working = false
            while !Task.isCancelled {
                await refresh(hosts: hosts)
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            }
        }
        .onDisappear { requestID = UUID() }
    }

    @ViewBuilder
    private func hostError(_ host: PairedHost) -> some View {
        if let message = responses[host.id]?.error ?? responses[host.id]?.status?.failure?.message ?? restriction(host.id)?.message {
            LabeledContent(host.displayName) {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    private func refresh(hosts candidates: [PairedHost], account: ViewerRelayAccessSnapshot.Account.ID? = nil, retry: Bool = false) async {
        guard !working else { return }
        let idForRequest = UUID()
        let requestedScope = scope
        requestID = idForRequest
        working = true
        defer {
            if requestID == idForRequest {
                working = false
            }
        }
        let updated = await ViewerRelayAccessSnapshot.fetch(server: server, hosts: candidates, client: client)
        guard !Task.isCancelled, requestID == idForRequest, loadedScope == requestedScope else { return }
        responses.merge(updated) { _, new in new }
        if retry {
            let snapshot = ViewerRelayAccessSnapshot(server: server, hosts: hosts, responses: responses)
            let ids = snapshot.reconnectableHostIDs(in: account, candidates: candidates, restriction: restriction)
            for id in ids {
                guard !Task.isCancelled, requestID == idForRequest, loadedScope == requestedScope else { return }
                await reconnect(id)
            }
        }
    }
}
