import CtrlxSimulatorProtocol
import Foundation
import Testing

struct SimulatorEnvironmentTests {
    @Test(arguments: [(-90.0, -180.0), (90.0, 180.0), (0.0, 0.0), (37.3349, -122.009)])
    func acceptsValidCoordinates(_ coordinates: (Double, Double)) throws {
        let value = try SimulatorLocation(latitude: coordinates.0, longitude: coordinates.1)
        #expect(value.latitude == coordinates.0)
        #expect(value.longitude == coordinates.1)
        #expect(value.coordinate.split(separator: ",").count == 2)
    }

    @Test(arguments: [(90.1, 0.0), (0.0, -180.1), (Double.nan, 0.0), (0.0, Double.infinity)])
    func rejectsInvalidCoordinates(_ coordinates: (Double, Double)) {
        #expect(throws: SimulatorFailure.self) {
            try SimulatorLocation(latitude: coordinates.0, longitude: coordinates.1)
        }
    }

    @Test(arguments: ["", "--help", "com.example app", "com.example/other", String(repeating: "a", count: 256)])
    func rejectsUnscopedPermissionAndPushTargets(_ bundle: String) {
        #expect(throws: SimulatorFailure.self) { try SimulatorPrivacyRequest(action: .reset, service: .all, bundle: bundle) }
        #expect(throws: SimulatorFailure.self) { try SimulatorPushNotification(bundle: bundle, payload: Data("{\"aps\":{}}".utf8)) }
    }

    @Test func boundsPayloadByUTF8BytesAndRequiresAnAPSObject() throws {
        let prefix = "{\"aps\":{},\"text\":\""
        let suffix = "\"}"
        let data = Data((prefix + String(repeating: "a", count: 4096 - prefix.utf8.count - suffix.utf8.count) + suffix).utf8)
        #expect(try SimulatorPushNotification(bundle: "com.example.app", payload: data).payload.count == 4096)
        for invalid in [data + Data(" ".utf8), Data("[]".utf8), Data("{\"aps\":null}".utf8), Data("{\"aps\":[]}".utf8), Data([0xFF])] {
            #expect(throws: SimulatorFailure.self) { try SimulatorPushNotification(bundle: "com.example.app", payload: invalid) }
        }
        let unicode = Data("{\"aps\":{\"alert\":\"测试 🙂\"}}".utf8)
        #expect(try SimulatorPushNotification(bundle: "com.example.app", payload: unicode).payload == unicode)
    }
}
