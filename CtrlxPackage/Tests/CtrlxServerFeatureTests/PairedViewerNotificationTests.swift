import CtrlxCommon
import CtrlxEncryption
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct PairedViewerNotificationTests {
    @Test("Authenticated capability survives restart, same-key refresh and rename, but not key replacement")
    func persistence() async throws {
        let prefs = PreferencesService.inMemory()
        try await withDependencies {
            $0[PreferencesService.self] = prefs
            $0[SecretsService.self] = .inMemory()
        } operation: {
            let settings = AppSettings()
            let viewer = PairedViewer(id: "pair", deviceName: "Phone", partnerPublicKey: "key", partnerPublicKeyId: "key-id")
            settings.addPairing(viewer)
            settings.recordStableAgentNotifications(true, pairID: "pair", publicKey: "key", keyID: "key-id")
            #expect(AppSettings().getPairing(id: "pair")?.supportsStableAgentNotifications == true)
            let manager = try PairingManager(settings: settings, e2eeService: await E2EEService())
            manager.updatePartnerPublicKey(deviceId: "pair", publicKey: "key", publicKeyId: "key-id")
            manager.updateViewerDeviceName(pairId: "pair", deviceName: "Renamed")
            #expect(AppSettings().getPairing(id: "pair")?.supportsStableAgentNotifications == true)

            manager.updatePartnerPublicKey(deviceId: "pair", publicKey: "replacement", publicKeyId: "key-id")
            #expect(AppSettings().getPairing(id: "pair")?.supportsStableAgentNotifications == nil)
            settings.recordStableAgentNotifications(true, pairID: "pair", publicKey: "key", keyID: "key-id")
            #expect(settings.getPairing(id: "pair")?.supportsStableAgentNotifications == nil) // Late Hello for the old key.
            settings.recordStableAgentNotifications(true, pairID: "pair", publicKey: "replacement", keyID: "key-id")
            manager.updatePartnerPublicKey(deviceId: "pair", publicKey: "replacement", publicKeyId: "new-id")
            #expect(AppSettings().getPairing(id: "pair")?.supportsStableAgentNotifications == nil)

            settings.recordStableAgentNotifications(true, pairID: "pair", publicKey: "replacement", keyID: "new-id")
            settings.recordStableAgentNotifications(false, pairID: "pair", publicKey: "replacement", keyID: "new-id")
            #expect(AppSettings().getPairing(id: "pair")?.supportsStableAgentNotifications == false)
            settings.removePairing(id: "pair")
            settings.recordStableAgentNotifications(true, pairID: "pair", publicKey: "replacement", keyID: "new-id")
            #expect(AppSettings().getPairing(id: "pair") == nil)
            settings.addPairing(viewer)
            #expect(AppSettings().getPairing(id: "pair")?.supportsStableAgentNotifications == nil)
        }
    }

    @Test("Older pairing records remain readable and do not claim unadvertised notification support")
    func oldPairing() throws {
        let viewer = PairedViewer(id: "pair", deviceName: "Phone", partnerPublicKey: "key", partnerPublicKeyId: "key-id")
        let data = try JSONEncoder().encode(viewer)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["supportsStableAgentNotifications"] == nil)
        let decoded = try JSONDecoder().decode(PairedViewer.self, from: data)
        #expect(decoded.supportsStableAgentNotifications == nil)
        #expect(decoded == viewer)
    }
}
