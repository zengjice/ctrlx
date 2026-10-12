import Foundation

public enum SimulatorAppearance: String, CaseIterable, Sendable {
    case light, dark
}

public enum SimulatorPrivacyAction: String, CaseIterable, Sendable {
    case grant, revoke, reset
}

public enum SimulatorPrivacyService: String, CaseIterable, Sendable {
    case all, calendar, contacts, location, photos, microphone, motion, reminders, siri
    case contactsLimited = "contacts-limited"
    case locationAlways = "location-always"
    case photosAdd = "photos-add"
    case mediaLibrary = "media-library"
}

public struct SimulatorLocation: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw SimulatorFailure("Location requires finite latitude -90...90 and longitude -180...180")
        }
        self.latitude = latitude
        self.longitude = longitude
    }

    public var coordinate: String { "\(latitude),\(longitude)" }
}

public struct SimulatorPrivacyRequest: Sendable {
    public let action: SimulatorPrivacyAction
    public let service: SimulatorPrivacyService
    public let bundle: String

    public init(action: SimulatorPrivacyAction, service: SimulatorPrivacyService, bundle: String) throws {
        try validateSimulatorBundle(bundle)
        self.action = action
        self.service = service
        self.bundle = bundle
    }
}

public struct SimulatorPushNotification: Sendable {
    public let bundle: String
    public let payload: Data

    public init(bundle: String, payload: Data) throws {
        try validateSimulatorBundle(bundle)
        guard payload.count <= 4096, String(data: payload, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              object["aps"] is [String: Any] else {
            throw SimulatorFailure("Push requires a UTF-8 JSON object with an aps object, up to 4096 bytes")
        }
        self.bundle = bundle
        self.payload = payload
    }
}

public func validateSimulatorBundle(_ bundle: String) throws {
    guard !bundle.isEmpty, bundle.utf8.count <= 255, !bundle.hasPrefix("-"),
          bundle.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }) else {
        throw SimulatorFailure("Provide a bundle identifier using letters, digits, dots or hyphens, up to 255 bytes")
    }
}
