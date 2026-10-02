import Foundation

/// Stable phrase identity, versioned text, and permanent deletion markers.
public struct QuickPhraseRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let order: Int
    public let text: String?
    public let edit: QuickPhraseEdit?

    public init(id: UUID, order: Int, text: String?, edit: QuickPhraseEdit? = nil) {
        self.id = id
        self.order = order
        self.text = text
        self.edit = edit
    }
}

/// Logical versions avoid relying on device clocks. Concurrent edits converge
/// to one winner by UUID; subsequent edits increment the accepted revision.
public struct QuickPhraseEdit: Codable, Equatable, Sendable {
    public let revision: Int
    public let id: UUID

    public init(revision: Int, id: UUID = UUID()) {
        self.revision = revision
        self.id = id
    }

    public func isNewer(than other: Self) -> Bool {
        revision == other.revision ? id.uuidString > other.id.uuidString : revision > other.revision
    }
}

/// Optional hello capability: absent on older clients. Epochs bind consent and
/// snapshots to one live peer connection, not a previous connection's consent.
public struct QuickPhraseSyncOffer: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public let version: Int
    public let epoch: UUID
    public let enabled: Bool

    public init(version: Int = Self.currentVersion, epoch: UUID, enabled: Bool) {
        self.version = version
        self.epoch = epoch
        self.enabled = enabled
    }
}

/// A library-wide order, separate from immutable additions and tombstones.
/// Logical revisions and a UUID tie-breaker converge without synchronized clocks.
public struct QuickPhraseOrdering: Codable, Equatable, Sendable {
    public let revision: Int
    public let id: UUID
    public let phraseIDs: [UUID]

    public init(revision: Int, id: UUID = UUID(), phraseIDs: [UUID]) {
        self.revision = revision
        self.id = id
        self.phraseIDs = phraseIDs
    }

    public func isNewer(than other: Self) -> Bool {
        revision == other.revision ? id.uuidString > other.id.uuidString : revision > other.revision
    }
}

public struct QuickPhraseSyncMessage: Codable, Equatable, Sendable {
    public let senderEpoch: UUID
    public let recipientEpoch: UUID
    public let enabled: Bool
    /// nil is consent-only and contains no library data.
    public let records: [QuickPhraseRecord]?
    public let ordering: QuickPhraseOrdering?

    public init(senderEpoch: UUID, recipientEpoch: UUID, enabled: Bool, records: [QuickPhraseRecord]? = nil,
                ordering: QuickPhraseOrdering? = nil) {
        self.senderEpoch = senderEpoch
        self.recipientEpoch = recipientEpoch
        self.enabled = enabled
        self.records = records
        self.ordering = ordering
    }
}
