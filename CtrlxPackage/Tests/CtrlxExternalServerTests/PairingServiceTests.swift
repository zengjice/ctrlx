import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxExternalServerLib

@Suite("PairingService Tests")
struct PairingServiceTests {
    // Test public keys (32-byte base64 encoded)
    private let testMacPublicKey = "dGVzdC1tYWMtcHVibGljLWtleS0wMTIzNDU2Nzg5MDEyMw=="
    private let testMacKeyId = "mac-key-id-1"
    private let testIOSPublicKey = "dGVzdC1pb3MtcHVibGljLWtleS0wMTIzNDU2Nzg5MDEyMw=="
    private let testIOSKeyId = "ios-key-id-1"

    @Test("Registration changes persist together and unchanged registrations do not rewrite pairs")
    func registrationPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-persistence-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = PairingService(dataDirectory: directory)
        let result = await service.registerCode(
            code: "PERSIST", deviceId: "mac-persist", deviceName: "My Mac", username: "testuser",
            publicKey: testMacPublicKey, publicKeyId: testMacKeyId
        )
        guard case let .registered(info) = result else {
            Issue.record("Expected pairing registration")
            return
        }
        _ = await service.completePairing(
            code: "PERSIST", deviceId: "ios-persist", deviceName: "My iPhone",
            publicKey: testIOSPublicKey, publicKeyId: testIOSKeyId
        )
        await service.updateHostRegistration(
            pairId: info.pairId, publicKey: "new-host-key", publicKeyId: "new-host-id",
            username: "new-user", deviceName: "Renamed Mac"
        )
        await service.updateViewerRegistration(
            pairId: info.pairId, publicKey: "new-viewer-key", publicKeyId: "new-viewer-id", deviceName: "Renamed iPhone"
        )
        await service.registerPushToken("new-token", for: info.pairId)

        let restored = PairingService(dataDirectory: directory)
        let pair = try #require(await restored.getPair(pairId: info.pairId))
        #expect(pair.hostPublicKey == "new-host-key")
        #expect(pair.hostPublicKeyId == "new-host-id")
        #expect(pair.hostUsername == "new-user")
        #expect(pair.hostDeviceName == "Renamed Mac")
        #expect(pair.viewerPublicKey == "new-viewer-key")
        #expect(pair.viewerPublicKeyId == "new-viewer-id")
        #expect(pair.viewerDeviceName == "Renamed iPhone")
        #expect(pair.pushToken == "new-token")

        let file = directory.appendingPathComponent("pairs.json")
        let marker = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: file.path)
        await service.updateHostRegistration(
            pairId: info.pairId, publicKey: "new-host-key", publicKeyId: "new-host-id",
            username: "new-user", deviceName: "Renamed Mac"
        )
        await service.updateViewerRegistration(
            pairId: info.pairId, publicKey: "new-viewer-key", publicKeyId: "new-viewer-id", deviceName: "Renamed iPhone"
        )
        await service.registerPushToken("new-token", for: info.pairId)
        #expect(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == marker)

        await service.removePushToken(for: info.pairId)
        let withoutToken = PairingService(dataDirectory: directory)
        #expect(await withoutToken.getPair(pairId: info.pairId)?.pushToken == nil)
        try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: file.path)
        await service.removePushToken(for: info.pairId)
        #expect(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == marker)
    }

    @Test("Registering a pairing code succeeds")
    func registerPairingCode() async throws {
        let service = PairingService()

        let result = await service.registerCode(
            code: "ABC123",
            deviceId: "mac-device-id",
            deviceName: "My Mac",
            username: "testuser",
            publicKey: testMacPublicKey,
            publicKeyId: testMacKeyId
        )

        guard case let .registered(info) = result else {
            Issue.record("Expected .registered, got \(result)")
            return
        }
        #expect(!info.pairId.isEmpty)
    }

    @Test("Completing pairing with valid code succeeds")
    func completePairingWithValidCode() async throws {
        let service = PairingService()

        // First register the code
        let registerResult = await service.registerCode(
            code: "XYZ789",
            deviceId: "mac-device-id",
            deviceName: "My Mac",
            username: "testuser",
            publicKey: testMacPublicKey,
            publicKeyId: testMacKeyId
        )

        guard case let .registered(registerInfo) = registerResult else {
            Issue.record("Expected .registered, got \(registerResult)")
            return
        }

        // Then complete pairing from iOS
        let result = await service.completePairing(
            code: "XYZ789",
            deviceId: "ios-device-id",
            deviceName: "My iPhone",
            publicKey: testIOSPublicKey,
            publicKeyId: testIOSKeyId
        )

        guard case let .paired(pairedInfo) = result else {
            Issue.record("Expected .paired, got \(result)")
            return
        }

        #expect(pairedInfo.partnerDeviceName == "My Mac")
        // Critical: both Mac and iOS should get the same pairId
        #expect(pairedInfo.pairId == registerInfo.pairId)
        // Verify partner's public key is returned
        #expect(pairedInfo.partnerPublicKey == testMacPublicKey)
        #expect(pairedInfo.partnerPublicKeyId == testMacKeyId)
        // Verify partner's username is returned
        #expect(pairedInfo.partnerUsername == "testuser")
    }

    @Test("Completing pairing with invalid code fails")
    func completePairingWithInvalidCode() async throws {
        let service = PairingService()

        let result = await service.completePairing(
            code: "INVALID",
            deviceId: "ios-device-id",
            deviceName: "My iPhone",
            publicKey: testIOSPublicKey,
            publicKeyId: testIOSKeyId
        )

        guard case let .error(errorInfo) = result else {
            Issue.record("Expected .error, got \(result)")
            return
        }
        #expect(!errorInfo.message.isEmpty)
    }

    @Test("Duplicate pairing code registration fails")
    func duplicatePairingCodeFails() async throws {
        let service = PairingService()

        // Register first code
        let first = await service.registerCode(
            code: "SAME01",
            deviceId: "mac-1",
            deviceName: "Mac 1",
            username: "user1",
            publicKey: testMacPublicKey,
            publicKeyId: testMacKeyId
        )

        guard case .registered = first else {
            Issue.record("Expected .registered, got \(first)")
            return
        }

        // Try to register same code again
        let second = await service.registerCode(
            code: "SAME01",
            deviceId: "mac-2",
            deviceName: "Mac 2",
            username: "user2",
            publicKey: "other-public-key",
            publicKeyId: "other-key-id"
        )

        guard case .error = second else {
            Issue.record("Expected .error, got \(second)")
            return
        }
    }
}
