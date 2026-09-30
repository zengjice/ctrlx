import Foundation

/// Immutable additions plus permanent deletion markers. A new save gets a new ID.
public struct QuickPhraseRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let order: Int
    public let text: String?

    public init(id: UUID, order: Int, text: String?) {
        self.id = id
        self.order = order
        self.text = text
    }
}

/// Optional hello capability: absent on older clients. Epochs bind consent and
/// snapshots to one live peer connection, not a previous connection's consent.
public struct QuickPhraseSyncOffer: Codable, Equatable, Sendable {
    public let version: Int
    public let epoch: UUID
    public let enabled: Bool

    public init(version: Int = 1, epoch: UUID, enabled: Bool) {
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
