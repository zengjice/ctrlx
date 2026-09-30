@testable import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing

@MainActor
@Suite("Quick phrase drag ordering")
struct QuickPhraseReorderingTests {
    private func store(_ preferences: PreferencesService = .inMemory()) -> QuickPhraseStore {
        withDependencies { $0[PreferencesService.self] = preferences } operation: { QuickPhraseStore() }
    }

    private func populated(_ preferences: PreferencesService = .inMemory()) throws -> QuickPhraseStore {
        let library = store(preferences)
        for text in ["one", "two", "three"] { try library.add(text) }
        return library
    }

    @Test("Moves in both directions persist without changing IDs, text, keys or records")
    func persistence() throws {
        let preferences = PreferencesService.inMemory()
        let library = try populated(preferences)
        let original = library.phrases, records = library.records
        #expect(try library.move(original[0].id, to: original[2].id))
        #expect(library.phrases == [original[1], original[2], original[0]])
        #expect(store(preferences).phrases == library.phrases)
        #expect(try library.move(original[0].id, to: original[1].id))
        #expect(library.phrases == original)
        #expect(library.records == records)
        #expect(library.ordering?.revision == 2)
        #expect(store(preferences).ordering == library.ordering)
        #expect(library.phrases[0].keys == [.text("one"), .delay(200), .enter])
    }

    @Test("Self drops and stale IDs do not write or notify")
    func noOp() throws {
        let library = try populated()
        var changes = 0
        let observer = library.observe { changes += 1 }
        defer { library.removeObserver(observer) }
        let id = library.phrases[0].id
        #expect(try !library.move(id, to: id))
        #expect(try !library.move(UUID(), to: id))
        #expect(try !library.move(id, to: UUID()))
        #expect(library.ordering == nil)
        #expect(changes == 0)
        #expect(try library.move(id, to: library.phrases[1].id))
        #expect(changes == 1)
    }

    private struct OldLibrary: Codable {
        let version: Int
        let records: [QuickPhraseRecord]
    }

    @Test("Existing v2 storage loads; reordered storage is still readable by old clients")
    func legacyStorage() throws {
        let preferences = PreferencesService.inMemory()
        let records = [QuickPhraseRecord(id: UUID(), order: 0, text: "one"),
                       QuickPhraseRecord(id: UUID(), order: 1, text: "two")]
        let data = try JSONEncoder().encode(OldLibrary(version: 2, records: records))
        preferences.setData(data, QuickPhraseStore.syncStorageKey)
        let library = store(preferences)
        #expect(library.loadError == nil)
        #expect(library.phrases.map(\.text) == ["one", "two"])
        #expect(preferences.data(QuickPhraseStore.syncStorageKey) == data)
        try library.move(records[1].id, to: records[0].id)
        let saved = try #require(preferences.data(QuickPhraseStore.syncStorageKey))
        #expect(try JSONDecoder().decode(OldLibrary.self, from: saved).records == records)
        #expect(store(preferences).phrases.map(\.text) == ["two", "one"])
    }

    @Test("New phrases append; reordered aliases remain deduplicated and delete together")
    func aliasesAndAdditions() throws {
        let library = try populated(), peer = store()
        try peer.add("one")
        try library.merge(peer.records)
        let one = try #require(library.phrases.first { $0.text == "one" })
        try library.move(one.id, to: library.phrases[2].id)
        #expect(library.phrases.map(\.text) == ["two", "three", "one"])
        #expect(library.ordering?.phraseIDs.count == 4)
        try library.add("four")
        #expect(library.phrases.map(\.text) == ["two", "three", "one", "four"])
        try library.remove(one.id)
        try library.merge(peer.records)
        #expect(library.phrases.map(\.text) == ["two", "three", "four"])
    }

    @Test("Concurrent offline orders converge in either merge order with no duplicate entries")
    func concurrency() throws {
        let a = try populated(), b = store()
        try b.merge(a.records)
        let original = a.phrases
        try a.move(original[0].id, to: original[2].id)
        try b.move(original[2].id, to: original[0].id)
        let aOrder = try #require(a.ordering), bOrder = try #require(b.ordering)
        let expected = aOrder.isNewer(than: bOrder) ? a.phrases : b.phrases
        try a.merge(b.records, ordering: bOrder)
        try b.merge(a.records, ordering: aOrder)
        #expect(a.phrases == expected)
        #expect(a.phrases == b.phrases)
        #expect(a.ordering == b.ordering)
        let winner = a.ordering
        try a.merge(b.records, ordering: bOrder)
        try b.merge(a.records, ordering: aOrder)
        #expect(a.ordering == winner)
        #expect(b.ordering == winner)
        try b.move(b.phrases[0].id, to: b.phrases[1].id)
        #expect(b.ordering?.revision == 2)
        try a.merge(b.records, ordering: b.ordering)
        #expect(a.phrases == b.phrases)
    }

    @Test("Stale snapshots and legacy record-only peers cannot reset an existing order")
    func staleSnapshots() throws {
        let library = try populated()
        let original = library.phrases, records = library.records
        try library.move(original[0].id, to: original[2].id)
        let stale = library.ordering
        try library.move(original[0].id, to: original[1].id)
        let current = library.ordering
        try library.merge(records, ordering: stale)
        try library.merge(records)
        #expect(library.ordering == current)
        #expect(library.phrases == original)
    }

    @Test("Concurrent deletion and sorting preserve tombstones")
    func deletion() throws {
        let a = try populated(), b = store()
        try b.merge(a.records)
        let original = a.phrases
        try a.move(original[0].id, to: original[2].id)
        try b.remove(original[0].id)
        let staleRecords = a.records
        try a.merge(b.records)
        try b.merge(staleRecords, ordering: a.ordering)
        #expect(a.phrases.map(\.text) == ["two", "three"])
        #expect(b.phrases == a.phrases)
        #expect(a.records == b.records)
    }

    @Test("Malformed orders fail atomically and cannot overwrite persisted data")
    func invalidOrdering() throws {
        let preferences = PreferencesService.inMemory()
        let library = try populated(preferences)
        let original = library.phrases, saved = preferences.data(QuickPhraseStore.syncStorageKey)
        for ordering in [
            QuickPhraseOrdering(revision: -1, phraseIDs: [original[0].id]),
            QuickPhraseOrdering(revision: 0, phraseIDs: [original[0].id]),
            QuickPhraseOrdering(revision: Int.max, phraseIDs: [original[0].id]),
            QuickPhraseOrdering(revision: 1, phraseIDs: [original[0].id, original[0].id]),
            QuickPhraseOrdering(revision: 1, phraseIDs: [UUID()]),
        ] {
            #expect(throws: (any Error).self) { try library.merge(library.records, ordering: ordering) }
            #expect(library.phrases == original)
            #expect(library.ordering == nil)
            #expect(preferences.data(QuickPhraseStore.syncStorageKey) == saved)
        }
        try library.move(original[0].id, to: original[2].id)
        let valid = try #require(library.ordering)
        let invalid = QuickPhraseOrdering(revision: valid.revision, id: valid.id, phraseIDs: [])
        #expect(throws: (any Error).self) { try library.merge(library.records, ordering: invalid) }
        #expect(library.ordering == valid)
    }

    @Test("The sync size bound includes ordering metadata")
    func capacity() throws {
        let library = store()
        let id = UUID(), secondID = UUID()
        let base = [QuickPhraseRecord(id: id, order: 0, text: ""),
                    QuickPhraseRecord(id: secondID, order: 1, text: "two")]
        let overhead = try JSONEncoder().encode(OldLibrary(version: 2, records: base)).count
        let records = [QuickPhraseRecord(id: id, order: 0, text: String(repeating: "a", count: 512 * 1024 - overhead - 10)), base[1]]
        try library.merge(records)
        #expect(throws: QuickPhraseStore.SyncError.self) { try library.move(id, to: secondID) }
        #expect(library.ordering == nil)
        #expect(library.records == records)
    }

    private struct OldMessage: Codable {
        let senderEpoch: UUID
        let recipientEpoch: UUID
        let enabled: Bool
        let records: [QuickPhraseRecord]?
    }

    @Test("Ordering is additive on the wire; legacy messages decode without it")
    func wireCompatibility() throws {
        let library = try populated()
        try library.move(library.phrases[0].id, to: library.phrases[2].id)
        let message = QuickPhraseSyncMessage(senderEpoch: UUID(), recipientEpoch: UUID(), enabled: true,
                                             records: library.records, ordering: library.ordering)
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(QuickPhraseSyncMessage.self, from: data) == message)
        let old = try JSONDecoder().decode(OldMessage.self, from: data)
        #expect(old.records == library.records)
        let legacy = try JSONDecoder().decode(QuickPhraseSyncMessage.self, from: JSONEncoder().encode(old))
        #expect(legacy.ordering == nil)
        #expect(legacy.records == library.records)
    }
}
