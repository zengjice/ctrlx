import CtrlxNetworking
import Foundation

extension RelayAccessService {
    func register(_ registration: PairingRegistration, token: String?) async throws -> RegistrationInfo {
        let principal = try await authenticate(token, role: "account")
        try Self.validateStrings([
            registration.deviceId,
            registration.deviceName,
            registration.publicKey,
            registration.publicKeyId,
            registration.username,
        ])
        guard
            registration.pairingCode.count == 6,
            registration.pairingCode.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else {
            throw RelaySQLite.Failure(description: "Invalid pairing code")
        }
        let pairID = UUID().uuidString
        let credential = Self.newKey()
        let registrationJSON = try String(decoding: JSONEncoder().encode(registration), as: UTF8.self)
        return try await perform { db in
            _ = try db.principal(hash: principal.credentialHash)
            try db.requireEnabled(principal.accountID)
            let now = Int64(Date().timeIntervalSince1970)
            // Expired codes can be reused, but their credentials must first lose authority.
            try db.query("DELETE FROM credentials WHERE pair_id IN (SELECT id FROM access_pairs WHERE pair_json IS NULL AND expires_at<=?)", [.integer(now)])
            try db.query("DELETE FROM access_pairs WHERE pair_json IS NULL AND expires_at<=?", [.integer(now)])
            let count = try db.query("SELECT COUNT(*) AS count FROM access_pairs WHERE account_id=?", [.text(principal.accountID)]).first?["count"]
            guard (Int(count ?? "") ?? Int.max) < 128 else {
                throw RelayAccessFailure(code: .rateLimited, message: "Too many Relay pairings. Remove unused pairings first.")
            }
            try db.query(
                "INSERT INTO access_pairs(id,account_id,code_hash,expires_at,registration) VALUES(?,?,?,?,?)",
                [
                    .text(pairID),
                    .text(principal.accountID),
                    .text(Self.digest(registration.pairingCode)),
                    .integer(now + 300),
                    .text(registrationJSON),
                ]
            )
            try db.query(
                "INSERT INTO credentials(hash,account_id,pair_id,role,device_id) VALUES(?,?,?,'host',?)",
                [.text(Self.digest(credential)), .text(principal.accountID), .text(pairID), .text(registration.deviceId)]
            )
            return RegistrationInfo(pairId: pairID, relayCredential: credential)
        }
    }

    func complete(_ completion: PairingCompletion) async throws -> (Pair, PairedViewerInfo) {
        try Self.validateStrings([completion.deviceId, completion.deviceName, completion.publicKey, completion.publicKeyId])
        guard completion.pairingCode.utf8.count == 6 else { throw RelaySQLite.Failure(description: "Invalid pairing code") }
        let credential = Self.newKey()
        return try await perform { db in
            guard
                let row = try db.query(
                    "SELECT * FROM access_pairs WHERE code_hash=? AND pair_json IS NULL AND expires_at>?",
                    [.text(Self.digest(completion.pairingCode)), .integer(Int64(Date().timeIntervalSince1970))]
                ).first,
                let pairID = row["id"], let account = row["account_id"], let registration = row["registration"] else {
                throw RelayAccessFailure(code: .accessDenied, message: "Invalid or expired pairing code.")
            }
            try db.requireEnabled(account)
            let host = try JSONDecoder().decode(PairingRegistration.self, from: Data(registration.utf8))
            let pair = Pair(
                id: pairID,
                hostDeviceId: host.deviceId,
                hostDeviceName: host.deviceName,
                hostUsername: host.username,
                hostPublicKey: host.publicKey,
                hostPublicKeyId: host.publicKeyId,
                viewerDeviceId: completion.deviceId,
                viewerDeviceName: completion.deviceName,
                viewerPublicKey: completion.publicKey,
                viewerPublicKeyId: completion.publicKeyId,
                createdAt: Date()
            )
            try db.query("UPDATE access_pairs SET code_hash=NULL,pair_json=? WHERE id=?", [.text(Self.encode(pair)), .text(pairID)])
            try db.query(
                "INSERT INTO credentials(hash,account_id,pair_id,role,device_id) VALUES(?,?,?,'viewer',?)",
                [.text(Self.digest(credential)), .text(account), .text(pairID), .text(completion.deviceId)]
            )
            return (pair, PairedViewerInfo(
                pairId: pairID,
                partnerDeviceName: host.deviceName,
                partnerPublicKey: host.publicKey,
                partnerPublicKeyId: host.publicKeyId,
                partnerUsername: host.username,
                relayCredential: credential
            ))
        }
    }

    func pairs() async throws -> [Pair] {
        try await perform { db in
            try db.query("SELECT pair_json FROM access_pairs WHERE pair_json IS NOT NULL").map { row in
                guard let json = row["pair_json"] else { throw RelaySQLite.Failure(description: "Missing pair metadata") }
                return try JSONDecoder().decode(Pair.self, from: Data(json.utf8))
            }
        }
    }

    func removePair(_ pairID: String) async throws {
        try await perform { db in
            try db.query("DELETE FROM credentials WHERE pair_id=?", [.text(pairID)])
            try db.query("DELETE FROM access_pairs WHERE id=?", [.text(pairID)])
        }
    }

    func updatePair(_ principal: RelayPrincipal, message: WebSocketMessage) async throws -> Pair? {
        try await perform { db in
            _ = try db.principal(hash: principal.credentialHash)
            try db.requireEnabled(principal.accountID)
            guard
                let pairID = principal.pairID,
                let json = try db.query("SELECT pair_json FROM access_pairs WHERE id=?", [.text(pairID)]).first?["pair_json"] else { return nil }
            var pair = try JSONDecoder().decode(Pair.self, from: Data(json.utf8))
            switch message {
            case let .registerHost(registration):
                guard principal.role == "host", registration.pairId == pairID, registration.deviceId == principal.deviceID else {
                    throw RelayAccessFailure(code: .accessDenied, message: "Host registration does not match its credential.")
                }
                try Self.validateStrings([registration.publicKey, registration.publicKeyId, registration.username, registration.deviceName])
                pair.hostDeviceName = registration.deviceName
                pair.hostUsername = registration.username
                pair.hostPublicKey = registration.publicKey
                pair.hostPublicKeyId = registration.publicKeyId
            case let .registerViewer(registration):
                guard principal.role == "viewer", registration.pairId == pairID, registration.deviceId == principal.deviceID else {
                    throw RelayAccessFailure(code: .accessDenied, message: "Viewer registration does not match its credential.")
                }
                try Self.validateStrings([registration.publicKey, registration.publicKeyId, registration.deviceName])
                pair.viewerDeviceName = registration.deviceName
                pair.viewerPublicKey = registration.publicKey
                pair.viewerPublicKeyId = registration.publicKeyId
            case let .registerPushToken(registration):
                guard principal.role == "viewer", registration.deviceToken.utf8.count <= 512 else {
                    throw RelayAccessFailure(code: .accessDenied, message: "Invalid push registration.")
                }
                pair.pushToken = registration.deviceToken
            default: return nil
            }
            try db.query("UPDATE access_pairs SET pair_json=? WHERE id=?", [.text(Self.encode(pair)), .text(pairID)])
            return pair
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func validateStrings(_ strings: [String]) throws {
        guard strings.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1_024 }) else {
            throw RelayAccessFailure(code: .accessDenied, message: "Invalid Relay device metadata.")
        }
    }
}
