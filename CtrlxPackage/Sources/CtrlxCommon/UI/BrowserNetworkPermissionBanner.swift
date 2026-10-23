import CtrlxNetworking
import SwiftUI

@MainActor
public struct BrowserNetworkPermissionBanner: View {
    private let permission: BrowserNetworkPermission?
    private let canRespond: Bool
    private let respond: (UUID, Bool) async throws -> Void
    @State private var submitting = false
    @State private var error: String?

    public init(permission: BrowserNetworkPermission?, canRespond: Bool, respond: @escaping (UUID, Bool) async throws -> Void) {
        self.permission = permission
        self.canRespond = canRespond
        self.respond = respond
    }

    public var body: some View {
        if let permission {
            VStack(alignment: .leading, spacing: 8) {
                Text(permission.origin).font(.headline).textSelection(.enabled)
                Text(permission.localNetwork
                    ? (permission.loopbackNetwork ? "Allow this site to access apps on the Host Mac and devices on its local network?" : "Allow this site to access devices on the Host Mac’s local network?")
                    : "Allow this site to access apps and services on the Host Mac? This may be needed for device authorization.")
                    .font(.callout)
                if !canRespond {
                    Text("Take Control to respond.").font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Don’t Allow") { answer(permission.id, allow: false) }
                    Button("Allow") { answer(permission.id, allow: true) }.buttonStyle(.borderedProminent)
                }.disabled(!canRespond || submitting)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .accessibilityIdentifier("browser-network-permission")
            .onChange(of: permission.id) { _, _ in error = nil }
        }
    }

    private func answer(_ id: UUID, allow: Bool) {
        submitting = true
        error = nil
        Task {
            defer { submitting = false }
            do { try await respond(id, allow) }
            catch { self.error = error.localizedDescription }
        }
    }
}
