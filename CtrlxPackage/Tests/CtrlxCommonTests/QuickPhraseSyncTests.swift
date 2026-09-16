@testable import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing

@MainActor
@Suite("Quick phrase synchronization")
struct QuickPhraseSyncTests {
    private func store(_ preferences: PreferencesService = .inMemory()) -> QuickPhraseStore {
        withDependencies { $0[PreferencesService.self] = preferences } operation: { QuickPhraseStore() }
    }

    @Test("v1 migrates without changing IDs/order or overwriting the backup")
    func migration() throws {
        let preferences = PreferencesService.inMemory()
        let old = [QuickPhrase(text: "second alphabetically"), QuickPhrase(text: "a")]
        let data = try JSONEncoder().encode(old)
        preferences.setData(data, QuickPhraseStore.storageKey)
        let library = store(preferences)
        #expect(library.phrases == old)
        #expect(preferences.data(QuickPhraseStore.storageKey) == data)
        try library.remove(old[0].id)
        #expect(store(preferences).phrases == [old[1]])
        #expect(store(preferences).records.first?.text == nil)
    }

    @Test("Merge is commutative and idempotent; offline deletion cannot resurrect")
    func merging() throws {
        let a = store(), b = store()
        try a.add("shared")
        try b.merge(a.records)
        let stale = b.records
        try a.remove(a.phrases[0].id)
        try a.add("Mac")
        try b.add("iOS")
        let left = a.records, right = b.records
        try a.merge(right)
        try b.merge(left)
        #expect(a.records == b.records)
        let converged = a.records
        try a.merge(stale)
        try a.merge(right)
        #expect(a.records == converged)
        #expect(Set(a.phrases.map(\.text)) == ["Mac", "iOS"])
        try a.add("shared") // Explicitly saving again creates a new ID.
        #expect(a.phrases.contains { $0.text == "shared" })
    }

    @Test("Identical independent additions show once and all known aliases delete")
    func aliases() throws {
        let a = store(), b = store()
        try a.add("hello")
        try b.add("hello")
        try a.merge(b.records)
        #expect(a.phrases.count == 1)
        #expect(a.records.count == 2)
        try a.remove(a.phrases[0].id)
        try b.merge(a.records)
        #expect(b.phrases.isEmpty)
    }

    @Test("Malformed, conflicting and oversized snapshots fail atomically")
    func invalidSnapshots() throws {
        let a = store()
        try a.add("safe")
        let original = a.records
        let id = original[0].id
        let invalid: [[QuickPhraseRecord]] = [
            [.init(id: UUID(), order: 0, text: "bad\u{1b}")],
            [original[0], original[0]],
            [.init(id: id, order: 0, text: "replace")],
            [.init(id: id, order: 1, text: nil)],
            [.init(id: UUID(), order: -1, text: "bad")],
            [.init(id: UUID(), order: Int.max, text: "bad")],
            [.init(id: UUID(), order: 0, text: String(repeating: "\\", count: 300_000))],
            (0..<4097).map { .init(id: UUID(), order: $0, text: nil) },
        ]
        for records in invalid {
            #expect(throws: (any Error).self) { try a.merge(records) }
            #expect(a.records == original)
        }
    }

    @Test("Corrupt v2 never falls back to stale v1 or overwrites storage")
    func corruptV2() throws {
        let prefs = PreferencesService.inMemory()
        prefs.setData(try JSONEncoder().encode([QuickPhrase(text: "old")]), QuickPhraseStore.storageKey)
        let bad = Data("broken".utf8)
        prefs.setData(bad, QuickPhraseStore.syncStorageKey)
        let a = store(prefs)
        #expect(a.loadError != nil)
        #expect(a.phrases.isEmpty)
        #expect(throws: (any Error).self) { try a.merge([]) }
        #expect(prefs.data(QuickPhraseStore.syncStorageKey) == bad)
    }

    @Test("Consent defaults off, is persistent and isolated by pair")
    func consent() {
        let prefs = PreferencesService.inMemory()
        let a = store(prefs)
        #expect(!a.isSyncEnabled(for: "a"))
        a.setSyncEnabled(true, for: "a")
        #expect(store(prefs).isSyncEnabled(for: "a"))
        #expect(!store(prefs).isSyncEnabled(for: "b"))
        a.setSyncEnabled(false, for: "a")
        #expect(!store(prefs).isSyncEnabled(for: "a"))
    }

    @MainActor
    private final class Link {
        let aStore: QuickPhraseStore
        let bStore: QuickPhraseStore
        var a: QuickPhraseSyncSession!
        var b: QuickPhraseSyncSession!
        var sentA: [QuickPhraseSyncMessage] = []
        var sentB: [QuickPhraseSyncMessage] = []

        init(_ aStore: QuickPhraseStore, _ bStore: QuickPhraseStore, pairID: String = "pair") {
            self.aStore = aStore
            self.bStore = bStore
            a = QuickPhraseSyncSession(store: aStore, pairID: pairID) { [weak self] message in
                self?.sentA.append(message)
                self?.b.receive(message)
            }
            b = QuickPhraseSyncSession(store: bStore, pairID: pairID) { [weak self] message in
                self?.sentB.append(message)
                self?.a.receive(message)
            }
        }

        func connect() async {
            a.receiveHello(b.offer)
            b.receiveHello(a.offer)
            a.didSendHello()
            b.didSendHello()
            await settle()
        }

        func settle() async {
            for _ in 0..<8 { await a.flush(); await b.flush() }
        }

        func disconnect() { a.reset(); b.reset() }
    }

    @Test("No contents leave either device until both sides opt in; online enable works")
    func bilateralConsent() async throws {
        let a = store(), b = store()
        try a.add("private Mac")
        try b.add("private iPhone")
        let link = Link(a, b)
        defer { link.disconnect() }
        await link.connect()
        a.setSyncEnabled(true, for: "pair")
        await link.settle()
        #expect((link.sentA + link.sentB).allSatisfy { $0.records == nil })
        b.setSyncEnabled(true, for: "pair")
        await link.settle()
        #expect(a.phrases == b.phrases)
        #expect(a.phrases.count == 2)
        let sentCount = link.sentA.count + link.sentB.count
        await link.settle()
        #expect(link.sentA.count + link.sentB.count == sentCount) // No echo loop.
    }

    @Test("Live edits and offline reconnect converge; disabling keeps data but stops sharing")
    func lifecycle() async throws {
        let a = store(), b = store()
        a.setSyncEnabled(true, for: "pair")
        b.setSyncEnabled(true, for: "pair")
        let link = Link(a, b)
        defer { link.disconnect() }
        await link.connect()
        try a.add("one")
        await link.settle()
        #expect(b.phrases == a.phrases)
        link.disconnect()
        try a.remove(a.phrases[0].id)
        try b.add("two")
        await link.connect()
        #expect(a.phrases == b.phrases)
        #expect(a.phrases.map(\.text) == ["two"])
        a.setSyncEnabled(false, for: "pair")
        await link.settle()
        try b.add("private")
        await link.settle()
        #expect(a.phrases.map(\.text) == ["two"])
        #expect(link.sentB.last?.records == nil)
    }

    @Test("An offline third peer receives deletion markers via an opted-in intermediary")
    func fanout() async throws {
        let a = store(), b = store(), c = store()
        for (library, pair) in [(a, "ab"), (b, "ab"), (b, "bc"), (c, "bc")] {
            library.setSyncEnabled(true, for: pair)
        }
        let ab = Link(a, b, pairID: "ab"), bc = Link(b, c, pairID: "bc")
        defer { ab.disconnect(); bc.disconnect() }
        await ab.connect(); await bc.connect()
        try a.add("propagate")
        await ab.settle(); await bc.settle()
        #expect(c.phrases == a.phrases)
        bc.disconnect()
        try a.remove(a.phrases[0].id)
        await ab.settle()
        await bc.connect()
        #expect(c.phrases.isEmpty)
        #expect(c.records == a.records)
    }

    @Test("Old/future peers get no new frames; stale connection epochs cannot merge")
    func compatibilityAndStaleEpoch() async throws {
        let a = store()
        a.setSyncEnabled(true, for: "pair")
        var sent: [QuickPhraseSyncMessage] = []
        let sync = QuickPhraseSyncSession(store: a, pairID: "pair") { sent.append($0) }
        defer { sync.reset() }
        sync.didSendHello()
        sync.receiveHello(nil)
        try a.add("new")
        await sync.flush()
        #expect(sent.isEmpty)
        sync.receiveHello(.init(version: 2, epoch: UUID(), enabled: true))
        await sync.flush()
        #expect(sent.isEmpty)
        let old = sync.offer, peer = QuickPhraseSyncOffer(epoch: UUID(), enabled: true)
        sync.receiveHello(peer)
        sync.reset()
        sync.didSendHello()
        sync.receiveHello(peer)
        sync.receive(.init(senderEpoch: peer.epoch, recipientEpoch: old.epoch, enabled: true,
                           records: [.init(id: UUID(), order: 0, text: "stale")]))
        #expect(a.phrases.map(\.text) == ["new"])
    }

    @Test("Hello may arrive before our send completes; sync waits for both")
    func helloOrdering() async {
        let a = store()
        a.setSyncEnabled(true, for: "pair")
        var sent: [QuickPhraseSyncMessage] = []
        let sync = QuickPhraseSyncSession(store: a, pairID: "pair") { sent.append($0) }
        defer { sync.reset() }
        sync.receiveHello(.init(epoch: UUID(), enabled: true))
        await sync.flush()
        #expect(sent.isEmpty)
        sync.didSendHello()
        await sync.flush()
        #expect(sent.count == 1)
    }

    @Test("Queued snapshots recheck consent; disconnect cancels unsent work")
    func pendingWork() async throws {
        let a = store()
        a.setSyncEnabled(true, for: "pair")
        try a.add("private")
        var sent: [QuickPhraseSyncMessage] = []
        let sync = QuickPhraseSyncSession(store: a, pairID: "pair") { sent.append($0) }
        defer { sync.reset() }
        sync.receiveHello(.init(epoch: UUID(), enabled: true))
        sync.didSendHello()
        a.setSyncEnabled(false, for: "pair") // Before the worker starts.
        await sync.flush()
        #expect(sent.count == 1)
        #expect(sent[0].records == nil)
        #expect(!sent[0].enabled)
        a.setSyncEnabled(true, for: "pair")
        sync.reset()
        await Task.yield()
        #expect(sent.count == 1)
    }

    @Test("Legacy hello decodes; new sync messages round-trip and require encryption")
    func wireFormat() throws {
        let old = Data(#"{"appVersion":"3.0.24","minRequiredPartnerVersion":"3.0.0"}"#.utf8)
        #expect(try JSONDecoder().decode(PeerHelloMessage.self, from: old).quickPhraseSync == nil)
        let payload = QuickPhraseSyncMessage(senderEpoch: UUID(), recipientEpoch: UUID(), enabled: true,
                                             records: [.init(id: UUID(), order: 0, text: "hello")])
        let message = WebSocketMessage.quickPhraseSync(payload)
        #expect(message.shouldEncrypt)
        let data = try JSONEncoder().encode(message)
        guard case let .quickPhraseSync(decoded) = try JSONDecoder().decode(WebSocketMessage.self, from: data)
        else { Issue.record("Wrong decoded message"); return }
        #expect(decoded == payload)
        #expect(message.messageType == "quickPhraseSync")
    }
}
