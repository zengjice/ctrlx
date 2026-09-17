@testable import CtrlxCommon
import Dependencies
import Foundation
import Testing

@MainActor
@Suite("Device-level quick phrase settings")
struct QuickPhraseDeviceSyncTests {
    private func store(_ preferences: PreferencesService = .inMemory()) -> QuickPhraseStore {
        withDependencies { $0[PreferencesService.self] = preferences } operation: { QuickPhraseStore() }
    }

    private func pair(_ id: String, key: UInt8 = 1, name: String = "Home") -> QuickPhraseSyncPairing {
        .init(pairID: id, name: name, publicKey: Data(repeating: key, count: 32).base64EncodedString())
    }

    @Test("Reciprocal pairings group by key, never by name")
    func identity() {
        let a = pair("incoming"), b = pair("outgoing", name: "My Home")
        let other = pair("other", key: 2)
        let devices = QuickPhraseSyncDevice.grouped([a, b, other])
        #expect(devices.count == 2)
        #expect(devices.first { $0.id == a.deviceID }?.pairIDs == ["incoming", "outgoing"])
        #expect(QuickPhraseSyncDevice.grouped([a, b]) == QuickPhraseSyncDevice.grouped([b, a]))
        #expect(QuickPhraseSyncPairing(pairID: "bad1", name: "Home", publicKey: "").deviceID
            != QuickPhraseSyncPairing(pairID: "bad2", name: "Home", publicKey: "").deviceID)
    }

    @Test("All legacy choices migrate without expanding any pairing permission", arguments: 0..<4)
    func migration(mask: Int) {
        let prefs = PreferencesService.inMemory()
        let a = pair("in"), b = pair("out")
        prefs.setBool(mask & 1 != 0, "terminalQuickPhrases.sync.in")
        prefs.setBool(mask & 2 != 0, "terminalQuickPhrases.sync.out")
        let library = store(prefs)
        library.updateSyncPairings([a, b])
        let expected: QuickPhraseSyncConsent = mask == 0 ? .disabled : mask == 3 ? .enabled : .needsConfirmation
        #expect(library.syncConsent(for: a.deviceID) == expected)
        #expect(library.isSyncEnabled(for: "in") == (mask & 1 != 0))
        #expect(library.isSyncEnabled(for: "out") == (mask & 2 != 0))
        let reloaded = store(prefs)
        reloaded.updateSyncPairings([b, a])
        #expect(reloaded.syncConsent(for: a.deviceID) == expected)
        #expect(reloaded.isSyncEnabled(for: "in") == library.isSyncEnabled(for: "in"))
        #expect(reloaded.isSyncEnabled(for: "out") == library.isSyncEnabled(for: "out"))
    }

    @Test("Resolving mixed settings persists once for all routes", arguments: [false, true])
    func confirmation(enabled: Bool) {
        let prefs = PreferencesService.inMemory()
        prefs.setBool(true, "terminalQuickPhrases.sync.in")
        let pairs = [pair("in"), pair("out")]
        let library = store(prefs)
        library.updateSyncPairings(pairs)
        #expect(library.syncStatus(for: pairs[0].deviceID) == .needsConfirmation)
        library.setDeviceSyncEnabled(enabled, deviceID: pairs[0].deviceID)
        let reloaded = store(prefs)
        reloaded.updateSyncPairings(pairs)
        for pairing in pairs {
            #expect(reloaded.isSyncEnabled(for: pairing.pairID) == enabled)
            #expect(prefs.optionalBool("terminalQuickPhrases.sync.\(pairing.pairID)") == enabled)
        }
        #expect(reloaded.syncConsent(for: pairs[0].deviceID) == (enabled ? .enabled : .disabled))
    }

    @Test("New reverse route inherits device consent, unrelated device stays off")
    func newRoutes() {
        let library = store()
        library.updateSyncPairings([pair("in")])
        library.setDeviceSyncEnabled(true, deviceID: pair("in").deviceID)
        library.updateSyncPairings([pair("in"), pair("out"), pair("other", key: 2)])
        #expect(library.isSyncEnabled(for: "out"))
        #expect(!library.isSyncEnabled(for: "other"))
        library.setSyncEnabled(false, for: "out")
        #expect(!library.isSyncEnabled(for: "in"))
        #expect(!library.isSyncEnabled(for: "out"))
    }

    @Test("Removing one route keeps consent; removing all requires fresh opt-in")
    func unpair() {
        let library = store()
        library.updateSyncPairings([pair("in"), pair("out")])
        library.setSyncEnabled(true, for: "in")
        library.updateSyncPairings([pair("out")])
        #expect(library.isSyncEnabled(for: "out"))
        #expect(!library.isSyncEnabled(for: "in"))
        library.updateSyncPairings([])
        library.updateSyncPairings([pair("in"), pair("out")])
        #expect(library.syncConsent(for: pair("in").deviceID) == .disabled)
    }

    @Test("Rename preserves identity; replacing a public key never inherits permission")
    func keyChange() {
        let library = store()
        library.updateSyncPairings([pair("in"), pair("out")])
        library.setSyncEnabled(true, for: "in")
        library.updateSyncPairings([pair("in", name: "New Name"), pair("out")])
        #expect(library.isSyncEnabled(for: "in"))
        library.updateSyncPairings([pair("in", key: 2), pair("out")])
        #expect(!library.isSyncEnabled(for: "in"))
        #expect(library.isSyncEnabled(for: "out"))
    }

    @Test("Device state aggregates routes without claiming delivery; stale reset cannot erase a new connection")
    func statuses() {
        let library = store()
        let id = pair("in").deviceID
        library.updateSyncPairings([pair("in"), pair("out")])
        #expect(library.syncStatus(for: id) == .disabled)
        library.setSyncEnabled(true, for: "in")
        #expect(library.syncStatus(for: id) == .offline)
        let old = UUID(), current = UUID()
        library.updateSyncConnection(pairID: "in", epoch: old, status: .unsupported)
        #expect(library.syncStatus(for: id) == .unsupported)
        library.updateSyncConnection(pairID: "out", epoch: current, status: .waitingForPeer)
        #expect(library.syncStatus(for: id) == .waitingForPeer)
        library.updateSyncConnection(pairID: "in", epoch: current, status: .ready)
        #expect(library.syncStatus(for: id) == .ready)
        library.clearSyncConnection(pairID: "in", epoch: old)
        #expect(library.syncStatus(for: id) == .ready)
        library.clearSyncConnection(pairID: "in", epoch: current)
        #expect(library.syncStatus(for: id) == .waitingForPeer)
        library.setSyncEnabled(false, for: "in")
        #expect(library.syncStatus(for: id) == .disabled)
    }

    @Test("Unreadable library never advertises a working sync status")
    func unreadableStatus() {
        let prefs = PreferencesService.inMemory()
        prefs.setData(Data("broken".utf8), QuickPhraseStore.syncStorageKey)
        let library = store(prefs)
        library.updateSyncPairings([pair("in")])
        library.setSyncEnabled(true, for: "in")
        library.updateSyncConnection(pairID: "in", epoch: UUID(), status: .ready)
        #expect(library.syncStatus(for: pair("in").deviceID) == .unavailable)
    }
}
