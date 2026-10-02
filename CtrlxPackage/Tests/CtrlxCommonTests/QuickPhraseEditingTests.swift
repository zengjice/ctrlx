@testable import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing

@MainActor
@Suite("Quick phrase editing")
struct QuickPhraseEditingTests {
    private func store(_ preferences: PreferencesService = .inMemory()) -> QuickPhraseStore {
        withDependencies { $0[PreferencesService.self] = preferences } operation: { QuickPhraseStore() }
    }

    @Test("Editing keeps the visible slot and other phrases, including after drag sorting",
          arguments: 0..<3, [false, true])
    func persistence(index: Int, reordered: Bool) throws {
        let preferences = PreferencesService.inMemory()
        let library = store(preferences)
        for text in ["one", "two", "three"] { try library.add(text) }
        if reordered { try library.move(library.phrases[0].id, to: library.phrases[2].id) }
        let original = library.phrases
        var changes = 0
        let observer = library.observe { changes += 1 }
        defer { library.removeObserver(observer) }

        let ordering = library.ordering
        try library.update(original[index], text: "  updated 👩‍💻  ")
        let replacement = library.phrases[index]
        #expect(replacement.text == "updated 👩‍💻")
        #expect(replacement.id == original[index].id)
        #expect(replacement.keys == [.text("updated 👩‍💻"), .delay(200), .enter])
        #expect(library.phrases.count == original.count)
        for other in original.indices where other != index {
            #expect(library.phrases[other] == original[other])
        }
        #expect(changes == 1)
        #expect(library.ordering == ordering)
        #expect(store(preferences).phrases == library.phrases)
        #expect(store(preferences).ordering == library.ordering)

        let context = TerminalPhraseContext(hostID: "host", paneID: "%1", inputRevision: 0,
                                            isConnected: true, isInputAvailable: true)
        let stale = TerminalPhraseRequest(phrase: original[index], context: context)
        #expect(!stale.isValid(in: context, savedPhrases: library.phrases))
    }

    @Test("Saving unchanged text neither replaces IDs nor writes or notifies")
    func unchanged() throws {
        let preferences = PreferencesService.inMemory()
        let library = store(preferences)
        try library.add("one")
        let original = library.phrases, records = library.records
        let saved = preferences.data(QuickPhraseStore.syncStorageKey)
        var changes = 0
        let observer = library.observe { changes += 1 }
        defer { library.removeObserver(observer) }
        try library.update(original[0], text: "  one  ")
        #expect(library.phrases == original)
        #expect(library.records == records)
        #expect(library.ordering == nil)
        #expect(preferences.data(QuickPhraseStore.syncStorageKey) == saved)
        #expect(changes == 0)
    }

    @Test("Invalid and duplicate edits fail without changing storage or syncing")
    func invalidInput() throws {
        let preferences = PreferencesService.inMemory()
        let library = store(preferences)
        try library.add("one")
        try library.add("two")
        let original = library.phrases, records = library.records
        let saved = preferences.data(QuickPhraseStore.syncStorageKey)
        var changes = 0
        let observer = library.observe { changes += 1 }
        defer { library.removeObserver(observer) }
        for text in ["", " \n ", "two", " two ", "a\nb", "a\rb", "a\tb", "a\u{1b}b", "a\u{2028}b"] {
            #expect(throws: (any Error).self) { try library.update(original[0], text: text) }
            #expect(library.phrases == original)
            #expect(library.records == records)
            #expect(library.ordering == nil)
            #expect(preferences.data(QuickPhraseStore.syncStorageKey) == saved)
        }
        #expect(changes == 0)
    }

    @Test("Deleted or remotely replaced phrases cannot be overwritten by a stale editor")
    func staleEditor() throws {
        let library = store(), peer = store()
        try library.add("original")
        let phrase = library.phrases[0]
        try peer.merge(library.records)
        try peer.update(phrase, text: "remote edit")
        try library.merge(peer.records, ordering: peer.ordering)
        let records = library.records, order = library.ordering
        #expect(throws: (any Error).self) { try library.update(phrase, text: "stale edit") }
        #expect(library.records == records)
        #expect(library.ordering == order)
        #expect(library.phrases.map(\.text) == ["remote edit"])
        let edited = library.phrases[0]
        try library.remove(edited.id)
        let deleted = library.records
        #expect(throws: (any Error).self) { try library.update(edited, text: "stale edit") }
        #expect(library.records == deleted)
        #expect(library.phrases.isEmpty)
    }

    @Test("Editing updates all known text aliases; stale snapshots never restore the old text")
    func aliases() throws {
        let library = store(), peer = store()
        try library.add("same")
        try peer.add("same")
        try library.merge(peer.records)
        let old = library.records
        try library.update(library.phrases[0], text: "edited")
        #expect(library.records.count == 2)
        #expect(library.records.allSatisfy { $0.text == "edited" && $0.edit?.revision == 1 })
        #expect(library.phrases.map(\.text) == ["edited"])
        try peer.merge(library.records, ordering: library.ordering)
        #expect(peer.phrases == library.phrases)
        try library.merge(old)
        #expect(library.phrases.map(\.text) == ["edited"])
        let firstEdit = library.records
        try library.update(library.phrases[0], text: "edited again")
        try library.merge(firstEdit)
        #expect(library.phrases.map(\.text) == ["edited again"])
        try library.remove(library.phrases[0].id)
        try library.merge(firstEdit)
        try library.merge(old)
        #expect(library.phrases.isEmpty)
    }

    @Test("Concurrent offline edits converge to one version on all four devices")
    func concurrentEdits() throws {
        let office = store(), home = store(), hk = store(), phone = store()
        try office.add("original")
        try home.merge(office.records)
        try phone.merge(office.records)
        try hk.merge(office.records)
        let stale = phone.records
        let phrase = office.phrases[0]
        try office.update(phrase, text: "office edit")
        try home.update(phrase, text: "home edit")
        let left = office.records, leftOrder = office.ordering
        let right = home.records, rightOrder = home.ordering
        try office.merge(right, ordering: rightOrder)
        try home.merge(left, ordering: leftOrder)
        #expect(office.records == home.records)
        #expect(office.ordering == home.ordering)
        #expect(office.phrases == home.phrases)
        let winningText = try #require(left[0].edit).id.uuidString > (try #require(right[0].edit)).id.uuidString
            ? "office edit" : "home edit"
        #expect(office.phrases == [QuickPhrase(id: phrase.id, text: winningText)])
        try phone.merge(right, ordering: rightOrder)
        try phone.merge(left, ordering: leftOrder)
        #expect(phone.phrases == office.phrases)
        try hk.merge(left, ordering: leftOrder)
        try hk.merge(right, ordering: rightOrder)
        #expect(hk.phrases == office.phrases)
        try office.merge(stale)
        try office.merge(right, ordering: rightOrder)
        #expect(office.phrases == home.phrases)
        try phone.update(phone.phrases[0], text: "later edit")
        try office.merge(phone.records)
        try home.merge(phone.records)
        try hk.merge(phone.records)
        try phone.merge(right)
        #expect(office.phrases == phone.phrases)
        #expect(home.phrases == phone.phrases)
        #expect(hk.phrases == phone.phrases)
        #expect(phone.phrases == [QuickPhrase(id: phrase.id, text: "later edit")])
        #expect(phone.records[0].edit?.revision == 2)
    }

    @Test("Legacy v2 storage loads without rewriting; the first edit writes versioned v3 storage")
    func legacyStorage() throws {
        struct Library: Codable {
            let version: Int
            let records: [QuickPhraseRecord]
        }
        let preferences = PreferencesService.inMemory()
        let records = [QuickPhraseRecord(id: UUID(), order: 0, text: "one"),
                       QuickPhraseRecord(id: UUID(), order: 1, text: "two")]
        let data = try JSONEncoder().encode(Library(version: 2, records: records))
        preferences.setData(data, QuickPhraseStore.syncStorageKey)
        let library = store(preferences)
        #expect(preferences.data(QuickPhraseStore.syncStorageKey) == data)
        try library.update(library.phrases[1], text: "edited")
        let saved = try JSONDecoder().decode(Library.self, from: #require(preferences.data(QuickPhraseStore.syncStorageKey)))
        #expect(saved.version == 3)
        #expect(saved.records[1].id == records[1].id)
        #expect(saved.records[1].edit?.revision == 1)
        try library.merge(records)
        #expect(library.phrases.map(\.text) == ["one", "edited"])
        #expect(store(preferences).records == library.records)
    }

    @Test("Editing at the record limit does not grow history; byte failures leave the phrase intact")
    func capacity() throws {
        let preferences = PreferencesService.inMemory()
        let library = store(preferences)
        let id = UUID()
        try library.merge([.init(id: id, order: 0, text: "safe")]
            + (1..<4096).map { .init(id: UUID(), order: $0, text: nil) })
        try library.update(library.phrases[0], text: "new")
        #expect(library.phrases == [QuickPhrase(id: id, text: "new")])
        #expect(library.records.count == 4096)
        #expect(store(preferences).phrases == library.phrases)
        let small = store()
        try small.add("safe")
        let records = small.records
        #expect(throws: (any Error).self) {
            try small.update(small.phrases[0], text: String(repeating: "\\", count: 300_000))
        }
        #expect(small.records == records)
        #expect(small.ordering == nil)
    }

    @Test("Deletion wins against concurrent editing and stale snapshots in either merge order")
    func editAndDelete() throws {
        let edited = store(), deleted = store(), peer = store()
        try edited.add("original")
        let original = edited.records
        let phrase = edited.phrases[0]
        try deleted.merge(original)
        try edited.update(phrase, text: "offline edit")
        try deleted.remove(phrase.id)
        let edit = edited.records, tombstone = deleted.records
        try edited.merge(tombstone)
        try deleted.merge(edit)
        try peer.merge(edit)
        try peer.merge(tombstone)
        #expect(edited.records == deleted.records)
        #expect(peer.records == edited.records)
        try edited.merge(original)
        try edited.merge(edit)
        #expect(edited.phrases.isEmpty)
    }

    @Test("Invalid or conflicting edit revisions are rejected atomically")
    func invalidVersions() throws {
        let library = store()
        try library.add("safe")
        try library.update(library.phrases[0], text: "edited")
        let original = library.records
        let record = original[0]
        for invalid in [QuickPhraseEdit(revision: 0), .init(revision: -1), .init(revision: Int.max)] {
            #expect(throws: (any Error).self) {
                try library.merge([.init(id: record.id, order: record.order, text: "invalid", edit: invalid)])
            }
            #expect(library.records == original)
        }
        #expect(throws: (any Error).self) {
            try library.merge([.init(id: record.id, order: record.order, text: "conflict", edit: record.edit)])
        }
        #expect(library.records == original)
    }

    @Test("Revision wins before UUID; concurrent UUID ties use the same winner in either order")
    func deterministicWinner() throws {
        let low = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let high = try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
        let id = UUID()
        let older = QuickPhraseRecord(id: id, order: 0, text: "older", edit: .init(revision: 1, id: high))
        let newer = QuickPhraseRecord(id: id, order: 0, text: "newer", edit: .init(revision: 2, id: low))
        let concurrent = QuickPhraseRecord(id: id, order: 0, text: "concurrent", edit: .init(revision: 2, id: high))
        let a = store(), b = store()
        try a.merge([older]); try a.merge([newer])
        try b.merge([newer]); try b.merge([older])
        #expect(a.records == [newer] && b.records == [newer])
        try a.merge([concurrent])
        let c = store()
        try c.merge([concurrent]); try c.merge([newer])
        #expect(a.records == [concurrent] && c.records == [concurrent])
    }

    @Test("Deletion markers with different edit revisions converge regardless of delivery order")
    func concurrentDeletes() throws {
        let a = store(), b = store()
        try a.add("original")
        try b.merge(a.records)
        try a.update(a.phrases[0], text: "edited")
        try a.remove(a.phrases[0].id)
        try b.remove(b.phrases[0].id)
        let left = a.records, right = b.records
        try a.merge(right)
        try b.merge(left)
        #expect(a.records == b.records)
        #expect(a.phrases.isEmpty && b.phrases.isEmpty)
    }
}
