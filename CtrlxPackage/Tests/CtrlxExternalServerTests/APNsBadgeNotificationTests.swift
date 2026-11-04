import Foundation
import Testing
@testable import CtrlxExternalServerLib

@Suite("APNs badge-only notifications")
struct APNsBadgeNotificationTests {
    @Test("iOS applies badge changes without a banner, sound or background wake", arguments: [0, 3])
    func systemBadgeRequest(count: Int) throws {
        let request = EncryptedBadgeNotification(
            badge: count, payload: .init(encrypted: "opaque", pairId: "host")
        ).request(deviceToken: "device", topic: "com.example.ctrlx")
        #expect(request.headers["apns-push-type"] == "alert")
        #expect(request.headers["apns-priority"] == "5")
        #expect(request.headers["apns-topic"] == "com.example.ctrlx")
        #expect(request.deviceToken == "device")
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request.message)) as? [String: Any])
        let aps = try #require(json["aps"] as? [String: Int])
        #expect(aps == ["badge": count])
        #expect(json["pairId"] as? String == "host")
        #expect(json["encrypted"] as? String == "opaque")
    }
}
