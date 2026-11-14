import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing
import Vapor
@testable import CtrlxServerFeature

@MainActor
@Suite(.dependency(SecretsService.inMemory()), .dependency(RelayCredentials.inMemory()), .dependency(PushNotificationLogService.previewValue))
struct StableNotificationTransportTests {
    @Test("Offline APNs retains authenticated targets; new keys and legacy Hello do not inherit them")
    func offlinePushCapabilities() async throws {
        let relay = PhraseTestRelay()
        let app = try await Application.make(.testing)
        app.webSocket("api", "ws") { _, ws in
            ws.onBinary { ws, bytes in
                let data = Data(bytes.readableBytesView)
                Task { await relay.receive(data, from: ws) }
            }
        }
        try await app.asyncBoot()
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        let hostEncryption = try await encryption()
        let viewerEncryption = try await encryption()
        let host = ConnectedViewer(
            pairedViewer: .init(id: "pair", deviceName: "Viewer", partnerPublicKey: viewerEncryption.publicKey.base64EncodedString(), partnerPublicKeyId: viewerEncryption.keyId),
            e2eeService: hostEncryption
        )
        do {
            let port = try #require(app.http.server.shared.localAddress?.port)
            let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
            try await viewerEncryption.establishSession(partnerPublicKey: hostEncryption.publicKey, partnerKeyId: hostEncryption.keyId, pairId: "pair")
            let id = AgentID(hostID: UUID(), paneID: UUID())
            var pane = PaneState(paneId: "%1", agentSession: .init(paneId: "%1", pluginID: "pi"), claudeSessionID: "A", workspaceIdentity: .init(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: id.paneID))
            pane.agentSession?.processRuntimeID = "runtime"
            let binding = try #require(AgentNotificationBinding(agentID: id, pane: pane))
            let action = NotificationActionContext(sessionId: "%1", pluginId: "pi", requestId: "request", form: .permission(.init(alwaysSuggestionID: nil)), agent: binding)

            func connect() async throws {
                await host.connect(serverURL: url, deviceId: "host", deviceName: "Host", username: "test", publicKey: hostEncryption.publicKey.base64EncodedString(), publicKeyId: hostEncryption.keyId)
                try await waitUntil { host.state.isConnected }
            }
            func hello(_ supports: Bool?, using encryption: E2EEService) async throws {
                let message = WebSocketMessage.peerHello(.init(appVersion: "3.1.0", minRequiredPartnerVersion: "", supportsStableAgentNotifications: supports))
                let encrypted = try await message.encrypt(using: encryption)
                try await relay.sendToHost(encrypted)
                try await waitUntil { host.isViewerConnected }
            }
            func offline() async throws {
                try await relay.sendToHost(.viewerDisconnected)
                try await waitUntil { !host.isViewerConnected }
            }
            func checkPush(using encryption: E2EEService, actionable: Bool) async throws {
                let count = await relay.pushes.count
                await host.sendCustomPushNotification(title: "Question", body: "Allow?", paneId: "%1", action: action, isQuestion: true, agentID: id)
                try await waitUntil { await relay.pushes.count == count + 1 }
                let payload = try #require(await relay.pushes.last)
                let content = try await encryption.decrypt(payload.encryptedContent, as: NotificationContent.self)
                #expect(content.agentID == (actionable ? id : nil))
                #expect(content.paneId == (actionable ? "%1" : nil))
                #expect(content.action == (actionable ? action : nil))
            }

            try await connect()
            try await checkPush(using: viewerEncryption, actionable: false) // not yet advertised
            try await hello(true, using: viewerEncryption)
            try await offline()
            try await checkPush(using: viewerEncryption, actionable: true)
            await host.disconnect() // Relay connection cleanup also preserves capability.
            try await connect()
            try await checkPush(using: viewerEncryption, actionable: true)

            let replacement = try await encryption()
            try await replacement.establishSession(partnerPublicKey: hostEncryption.publicKey, partnerKeyId: hostEncryption.keyId, pairId: "pair")
            var learnedReplacement = false
            host.onPartnerKeyReceived = { _, key in learnedReplacement = key == replacement.keyId }
            try await relay.sendToHost(.viewerConnected(.init(publicKey: replacement.publicKey.base64EncodedString(), publicKeyId: replacement.keyId)))
            try await waitUntil { learnedReplacement }
            try await checkPush(using: replacement, actionable: false)
            try await hello(true, using: replacement)
            try await offline()
            try await checkPush(using: replacement, actionable: true)
            try await hello(nil, using: replacement) // older client on the same key
            try await offline()
            try await checkPush(using: replacement, actionable: false)
            try await hello(true, using: replacement)
            try await relay.sendToHost(.unpaired)
            try await waitUntil { host.state == .disconnected }
            try await connect()
            try await checkPush(using: replacement, actionable: false)
            #expect(await relay.errors.isEmpty)
        } catch {
            await host.disconnect()
            await app.server.shutdown()
            try await app.asyncShutdown()
            throw error
        }
        await host.disconnect()
        await app.server.shutdown()
        try await app.asyncShutdown()
    }

    private func encryption() async throws -> E2EEService {
        try await withDependencies { $0[SecretsService.self] = .inMemory() } operation: { try await E2EEService() }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(await condition(), "Notification transport did not converge")
    }
}
