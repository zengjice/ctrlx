import CryptoKit
import Foundation

/// A trusted pairing's identity, independent of its terminal Host/Viewer role.
package struct QuickPhraseSyncPairing: Equatable, Sendable {
    package let pairID: String
    package let name: String
    package let publicKey: String

    package init(pairID: String, name: String, publicKey: String) {
        self.pairID = pairID
        self.name = name
        self.publicKey = publicKey
    }

    package var deviceID: String {
        // Only valid Curve25519 keys can join two pairings. Corrupt/missing keys
        // must not collapse unrelated devices into one consent switch.
        if let bytes = Data(base64Encoded: publicKey), bytes.count == 32 {
            return Self.fingerprint(bytes)
        }
        return "unverified-" + Self.fingerprint(Data("\(pairID):\(publicKey)".utf8))
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

package struct QuickPhraseSyncDevice: Identifiable, Equatable, Sendable {
    package let id: String
    package let name: String
    package let pairIDs: [String]

    package static func grouped(_ pairings: [QuickPhraseSyncPairing]) -> [Self] {
        Dictionary(grouping: pairings, by: \.deviceID).map { id, pairs in
            Self(
                id: id,
                name: Set(pairs.map(\.name)).sorted().joined(separator: " / "),
                pairIDs: Set(pairs.map(\.pairID)).sorted()
            )
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}

package enum QuickPhraseSyncConsent: Equatable, Sendable {
    case enabled, disabled, needsConfirmation
}

/// Handshake state, not a claim that a remote peer has saved every record.
package enum QuickPhraseSyncStatus: Equatable, Sendable {
    case disabled, needsConfirmation, offline, waitingForPeer, ready, unsupported, unavailable
}
