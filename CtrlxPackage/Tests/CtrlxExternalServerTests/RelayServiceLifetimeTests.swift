import Foundation
import Testing
import VaporTesting
@testable import CtrlxExternalServerLib

extension EnvSerializedSuites {
    @Suite("Relay service lifetime")
    struct RelayServiceLifetimeTests {
        @Test("Pairing and APNs services are released after application shutdown")
        func releasesServices() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-lifetime-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            weak var pairing: PairingService?
            weak var apns: APNsService?
            try await withApp {
                try await configure($0, env: ["DATA_DIRECTORY": directory.path])
                pairing = $0.pairingService
                apns = $0.apnsService
                #expect(pairing != nil)
                #expect(apns != nil)
            }
            #expect(pairing == nil)
            #expect(apns == nil)
        }
    }
}
