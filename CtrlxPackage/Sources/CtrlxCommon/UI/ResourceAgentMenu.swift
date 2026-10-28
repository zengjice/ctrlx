import CtrlxNetworking
import SwiftUI

public struct ResourceTabActions: Sendable {
    public var request: @MainActor @Sendable (ResourceTabRequest) async throws -> ResourceTabResponse
    public init(request: @escaping @MainActor @Sendable (ResourceTabRequest) async throws -> ResourceTabResponse) {
        self.request = request
    }
}

private struct ResourceTabActionsKey: EnvironmentKey {
    static let defaultValue: ResourceTabActions? = nil
}

public extension EnvironmentValues {
    var resourceTabActions: ResourceTabActions? {
        get { self[ResourceTabActionsKey.self] }
        set { self[ResourceTabActionsKey.self] = newValue }
    }
}

/// Authorization stays separate from ownership and the Viewer input lease.
public struct ResourceAgentMenu: View {
    let kind: ResourceTabKind
    let tabID: UUID
    let sessionID: UUID
    let grant: ResourceTabGrant?
    let path: String?
    let request: @MainActor (ResourceTabRequest) async throws -> ResourceTabResponse
    @State private var choosing = false
    @State private var agents: [ResourceAgent] = []
    @State private var loading = false
    @State private var operation: ResourceTabRequest.Operation?
    @State private var error: String?

    public init(kind: ResourceTabKind, tabID: UUID, sessionID: UUID, grant: ResourceTabGrant?, path: String? = nil, request: @escaping @MainActor (ResourceTabRequest) async throws -> ResourceTabResponse) {
        self.kind = kind
        self.tabID = tabID
        self.sessionID = sessionID
        self.grant = grant
        self.path = path
        self.request = request
    }

    public var body: some View {
        Menu {
            if path != nil {
                Button("Send Path to Agent…") { choosing = true }
            } else if let grant {
                Text(grant.agent.title)
                Text(grant.canWrite ? "Agent can operate this tab" : "Agent paused by human control")
                if !grant.canWrite {
                    Button("Return Control to Agent") { operation = .returnControl(kind: kind, tabID: tabID) }
                }
                Button("Change Agent…") { choosing = true }
                Button("Revoke Agent Access", role: .destructive) { operation = .revoke(kind: kind, tabID: tabID) }
            } else {
                Button("Allow Agent to Use…") { choosing = true }
            }
        } label: {
            Label(path != nil ? "Send Path to Agent" : (grant?.agent.title ?? "Allow Agent to Use"), symbol: .sparkles).labelStyle(.iconOnly)
        }
        .disabled(operation != nil)
        .help(path != nil ? "Insert the current path into a chosen Agent's input" : grant.map { "\($0.agent.title) · \($0.canWrite ? "Agent control" : "Paused")" } ?? "Allow one running Agent to use this tab")
        .accessibilityIdentifier("resource-agent-authorization")
        .task(id: operation) {
            guard let operation else { return }
            defer { self.operation = nil }
            do { _ = try await request(.init(sessionID: sessionID, operation: operation)) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $choosing) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(path == nil ? "Allow Agent to Use" : "Send Path to Agent").font(.headline)
                    Spacer()
                    Button("Cancel") { choosing = false }
                }
                Text(path == nil ? "Choose a running Agent in this session. It can observe and operate this tab until you revoke access. Human input pauses Agent control." : "Choose the recipient. The path is inserted into its input without sending Return.")
                    .font(.callout).foregroundStyle(.secondary)
                if loading {
                    ProgressView()
                } else if agents.isEmpty {
                    Text("No running Agent is available in this session.").foregroundStyle(.secondary)
                } else {
                    List(agents) { agent in
                        Button(agent.title) {
                            choosing = false
                            if let path {
                                operation = .sendPath(tabID: tabID, path: path, agentID: agent.id)
                            } else {
                                operation = .authorize(kind: kind, tabID: tabID, agentID: agent.id)
                            }
                        }
                    }
                }
            }
            .padding()
            #if os(macOS)
                .frame(width: 440, height: 320)
            #else
                .presentationDetents([.medium, .large])
            #endif
                .task {
                    loading = true
                    defer { loading = false }
                    do { agents = try await request(.init(sessionID: sessionID, operation: .agents)).agents ?? [] }
                    catch is CancellationError { }
                    catch { choosing = false
                        self.error = error.localizedDescription
                    }
                }
        }
        .alert("Agent Access", isPresented: .init(get: { error != nil }, set: {
            if !$0 {
                error = nil
            }
        })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}
