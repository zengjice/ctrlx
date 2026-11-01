import CtrlxNetworking
import Dependencies
import SwiftUI

@MainActor
public struct RelayAccessSettingsSection: View {
    let server: String
    let pairID: String?
    let role: String?
    let title: String
    let restriction: RelayAccessFailure?
    let onMeteredChange: (Bool) -> Void
    let reconnect: @MainActor () async -> Void

    @Dependency(RelayCredentials.self) private var credentials
    @Dependency(RelayAccessClient.self) private var client
    @State private var access: RelayAccessStatus?
    @State private var keyDraft = ""
    @State private var keyServer: String?
    @State private var error: String?
    @State private var working = false
    @State private var requestID = UUID()

    public init(
        server: String,
        pairID: String? = nil,
        role: String? = nil,
        title: String = "Relay Traffic",
        restriction: RelayAccessFailure? = nil,
        onMeteredChange: @escaping (Bool) -> Void = { _ in },
        reconnect: @escaping @MainActor () async -> Void
    ) {
        self.server = server
        self.pairID = pairID
        self.role = role
        self.title = title
        self.restriction = restriction
        self.onMeteredChange = onMeteredChange
        self.reconnect = reconnect
    }

    public var body: some View {
        Group {
            if access?.metered != false {
                Section {
                    if pairID == nil {
                        SecureField("Access Key", text: $keyDraft)
                            .autocorrectionDisabled()
                            .disabled(keyServer != server)
                            .accessibilityIdentifier("relay-access-key")
                        Button("Save Access Key") {
                            Task { await saveKey() }
                        }
                        .disabled(working || keyServer != server || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("relay-access-save")
                    }
                    if let quota = access?.quota {
                        LabeledContent("Shared account", value: quota.accountName)
                        LabeledContent("Used this month", value: "\(bytes(quota.usedBytes)) / \(bytes(quota.totalBytes))")
                        LabeledContent("Monthly allowance", value: bytes(quota.baseBytes))
                        LabeledContent("Extra this month", value: bytes(quota.extraBytes))
                        LabeledContent("Resets") {
                            Text(quota.resetsAt, format: .dateTime.year().month().day().hour().minute())
                        }
                        if !quota.enabled {
                            Text("This Relay account is disabled. Contact the administrator.")
                                .foregroundStyle(.red)
                        } else if quota.remainingBytes == 0 {
                            Text("Relay traffic quota is exhausted. Add quota or wait for the monthly reset.")
                                .foregroundStyle(.orange)
                        }
                    }
                    if let message = error ?? access?.failure?.message ?? restriction?.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    Button("Check and Reconnect") {
                        Task { await refresh(retry: true) }
                    }
                    .disabled(working)
                    .accessibilityIdentifier("relay-quota-retry")
                    if working {
                        ProgressView().controlSize(.small)
                    }
                } header: {
                    Text(title)
                } footer: {
                    Text("Hosts in the same Relay account share this allowance. Extra quota applies only to its month. Agent model quotas are separate.")
                }
            }
        }
        .task(id: [server, pairID ?? "", role ?? ""]) {
            let id = UUID()
            requestID = id
            working = false
            access = nil
            error = nil
            onMeteredChange(false)
            if pairID == nil {
                keyServer = nil
                keyDraft = ""
                do {
                    let key = try await credentials.load(server, nil, nil) ?? ""
                    guard !Task.isCancelled, requestID == id else { return }
                    keyDraft = key
                    keyServer = server
                } catch {
                    guard !Task.isCancelled, requestID == id else { return }
                    self.error = error.localizedDescription
                    keyServer = server
                }
            }
            while !Task.isCancelled {
                if !working {
                    await refresh(retry: false)
                }
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            }
        }
        .onDisappear { requestID = UUID() }
    }

    private func saveKey() async {
        guard keyServer == server else { return }
        let id = UUID()
        requestID = id
        working = true
        defer {
            if requestID == id {
                working = false
            }
        }
        do {
            let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await client.validateKey(server, key)
            guard !Task.isCancelled, requestID == id else { return }
            try await credentials.save(key, server, nil, nil)
            guard !Task.isCancelled, requestID == id else { return }
            access = result
            error = nil
            onMeteredChange(result.metered)
        } catch {
            guard !Task.isCancelled, requestID == id else { return }
            self.error = error.localizedDescription
        }
    }

    private func refresh(retry: Bool) async {
        let id = UUID()
        requestID = id
        working = true
        defer {
            if requestID == id {
                working = false
            }
        }
        do {
            let result = try await client.status(server, pairID, role)
            guard !Task.isCancelled, requestID == id else { return }
            access = result
            error = nil
            onMeteredChange(result.metered)
            if
                retry, result.failure == nil,
                restriction.map({ RelayAccessRecovery.canResume($0, status: result) }) ?? true,
                !result.metered || (result.quota?.enabled == true && (result.quota?.remainingBytes ?? 0) > 0) {
                await reconnect()
            }
        } catch {
            guard !Task.isCancelled, requestID == id else { return }
            self.error = error.localizedDescription
        }
    }

    private func bytes(_ value: Int64) -> String {
        String(format: "%.3f GiB", Double(value) / Double(1 << 30))
    }
}
