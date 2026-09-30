import CtrlxNetworking
import Dependencies
import Foundation
import Observation

package struct QuickPhrase: Codable, Identifiable, Equatable, Sendable {
    package let id: UUID
    package let text: String

    package init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }

    /// Reject embedded controls instead of executing pasted newlines.
    package static func validatedText(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }
        // C0/C1 can act as terminal keys. Unicode format characters (such as
        // the joiner in 👩‍💻) are legitimate phrase text and must remain intact.
        guard trimmed.unicodeScalars.allSatisfy({
            $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value)
                && !CharacterSet.newlines.contains($0)
        })
        else { throw ValidationError.multiline }
        return trimmed
    }

    package enum ValidationError: LocalizedError {
        case empty, multiline, duplicate

        package var errorDescription: String? {
            switch self {
            case .empty: "Enter a phrase first."
            case .multiline: "Use a single line without control characters."
            case .duplicate: "This phrase is already saved."
            }
        }
    }

    package var keys: [TmuxKey] { [.text(text), .delay(200), .enter] }
}

/// One store owned by platform settings, shared across all hosts/windows on this device.
@MainActor
@Observable
package final class QuickPhraseStore {
    package static let storageKey = "terminalQuickPhrases.v1"
    package static let syncStorageKey = "terminalQuickPhrases.v2"
    package private(set) var phrases: [QuickPhrase] = []
    package private(set) var loadError: String?
    package var syncErrors: [String: String] = [:]
    package private(set) var syncDevices: [QuickPhraseSyncDevice] = []
    private var syncDeviceByPair: [String: String]?
    private var syncConnections: [String: (epoch: UUID, status: QuickPhraseSyncStatus)] = [:]
    package private(set) var records: [QuickPhraseRecord] = []
    package private(set) var ordering: QuickPhraseOrdering?
    private var consentRevision = 0
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]

    private struct Library: Codable {
        let version: Int
        let records: [QuickPhraseRecord]
        let ordering: QuickPhraseOrdering?
    }

    package enum SyncError: LocalizedError {
        case invalidLibrary, capacity
        package var errorDescription: String? {
            switch self {
            case .invalidLibrary: "The quick phrase library is invalid or incompatible."
            case .capacity: "The quick phrase library exceeds its sync limit (4,096 records or 512 KB)."
            }
        }
    }

    @ObservationIgnored
    @Dependency(PreferencesService.self) private var preferences

    package init() {
        do {
            if let data = preferences.data(Self.syncStorageKey) {
                let library = try JSONDecoder().decode(Library.self, from: data)
                guard library.version == 2 else { throw SyncError.invalidLibrary }
                try validate(library.records, ordering: library.ordering)
                apply(library.records, ordering: library.ordering)
                return
            }
            guard let data = preferences.data(Self.storageKey) else { return }
            let saved = try JSONDecoder().decode([QuickPhrase].self, from: data)
            guard Set(saved.map(\.id)).count == saved.count else {
                throw CocoaError(.coderReadCorrupt)
            }
            for phrase in saved {
                guard try QuickPhrase.validatedText(phrase.text) == phrase.text else {
                    throw CocoaError(.coderReadCorrupt)
                }
            }
            // Leave v1 intact as a migration backup; v2 is authoritative thereafter.
            try save(saved.enumerated().map { QuickPhraseRecord(id: $0.element.id, order: $0.offset, text: $0.element.text) })
        } catch {
            // Do not overwrite an unreadable library with an empty list.
            loadError = "Saved phrases could not be read: \(error.localizedDescription)"
        }
    }

    package func add(_ text: String) throws {
        let text = try QuickPhrase.validatedText(text)
        guard !phrases.contains(where: { $0.text == text }) else { throw QuickPhrase.ValidationError.duplicate }
        let order = (records.map(\.order).max() ?? -1) + 1
        try save(records + [QuickPhraseRecord(id: UUID(), order: order, text: text)])
    }

    package func remove(_ id: QuickPhrase.ID) throws {
        guard let phrase = phrases.first(where: { $0.id == id }) else { return }
        // The UI deduplicates independently-created identical phrases. Delete all
        // known aliases, so a hidden duplicate cannot immediately reappear.
        try save(records.map {
            $0.text == phrase.text ? QuickPhraseRecord(id: $0.id, order: $0.order, text: nil) : $0
        })
    }

    /// Drop onto a phrase's current position; unknown/stale IDs are not moves.
    @discardableResult
    package func move(_ id: QuickPhrase.ID, to targetID: QuickPhrase.ID) throws -> Bool {
        guard id != targetID,
              let source = phrases.firstIndex(where: { $0.id == id }),
              let destination = phrases.firstIndex(where: { $0.id == targetID }) else { return false }
        var moved = phrases
        moved.insert(moved.remove(at: source), at: destination)
        var aliases: [String: [UUID]] = [:]
        for record in records {
            if let text = record.text { aliases[text, default: []].append(record.id) }
        }
        let next = QuickPhraseOrdering(
            revision: (ordering?.revision ?? 0) + 1,
            phraseIDs: moved.flatMap { aliases[$0.text] ?? [] }
        )
        try save(records, ordering: next)
        return true
    }

    package func merge(_ incoming: [QuickPhraseRecord], ordering incomingOrder: QuickPhraseOrdering? = nil) throws {
        try validate(incoming, ordering: incomingOrder)
        var merged = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for record in incoming {
            if let old = merged[record.id] {
                guard old.order == record.order,
                      old.text == nil || record.text == nil || old.text == record.text
                else { throw SyncError.invalidLibrary }
                if record.text == nil { merged[record.id] = record }
            } else {
                merged[record.id] = record
            }
        }
        var nextOrder = ordering
        if let incomingOrder {
            if let old = ordering {
                guard old.revision != incomingOrder.revision || old.id != incomingOrder.id || old == incomingOrder
                else { throw SyncError.invalidLibrary }
                if incomingOrder.isNewer(than: old) { nextOrder = incomingOrder }
            } else {
                nextOrder = incomingOrder
            }
        }
        try save(Array(merged.values), ordering: nextOrder)
    }

    package func isSyncEnabled(for pairID: String) -> Bool {
        _ = consentRevision
        if let syncDeviceByPair {
            guard let deviceID = syncDeviceByPair[pairID] else { return false }
            if let enabled = preferences.optionalBool(deviceConsentKey(deviceID)) { return enabled }
        }
        return preferences.optionalBool("terminalQuickPhrases.sync.\(pairID)") == true
    }

    /// Retained for callers that hold a pair ID; registered pairs always change
    /// the device-wide choice. Legacy, unregistered stores support migration.
    package func setSyncEnabled(_ enabled: Bool, for pairID: String) {
        if let syncDeviceByPair {
            guard let deviceID = syncDeviceByPair[pairID] else { return }
            setDeviceSyncEnabled(enabled, deviceID: deviceID)
            return
        }
        guard enabled != isSyncEnabled(for: pairID) else { return }
        preferences.setBool(enabled, "terminalQuickPhrases.sync.\(pairID)")
        consentRevision += 1
        syncErrors[pairID] = nil
        notify()
    }

    /// Called by platform settings after loading BOTH pairing lists, and whenever
    /// they change. Migration must not run on only one half of reciprocal pairs.
    package func updateSyncPairings(_ pairings: [QuickPhraseSyncPairing]) {
        let devices = QuickPhraseSyncDevice.grouped(pairings)
        let mapping = Dictionary(pairings.map { ($0.pairID, $0.deviceID) }, uniquingKeysWith: { first, _ in first })
        guard syncDeviceByPair != mapping || syncDevices != devices else { return }

        for (pairID, oldDevice) in syncDeviceByPair ?? [:] where mapping[pairID] != oldDevice {
            // Removed pairings and key changes cannot inherit legacy consent.
            preferences.setBool(false, "terminalQuickPhrases.sync.\(pairID)")
            syncConnections[pairID] = nil
            syncErrors[pairID] = nil
        }
        let remaining = Set(devices.map(\.id))
        for device in syncDevices where !remaining.contains(device.id) {
            preferences.setData(nil, deviceConsentKey(device.id))
        }
        for device in devices where preferences.optionalBool(deviceConsentKey(device.id)) == nil {
            let legacy = Set(device.pairIDs.map { preferences.optionalBool("terminalQuickPhrases.sync.\($0)") == true })
            if legacy.count == 1, let enabled = legacy.first {
                preferences.setBool(enabled, deviceConsentKey(device.id))
            }
            // Mixed legacy choices remain per-connection until explicitly
            // confirmed. OR-ing them could silently create a new sharing path.
        }
        syncDevices = devices
        syncDeviceByPair = mapping
        consentRevision += 1
        notify()
    }

    package func syncDeviceID(for pairID: String) -> String? { syncDeviceByPair?[pairID] }

    package func syncConsent(for deviceID: String) -> QuickPhraseSyncConsent {
        _ = consentRevision
        guard syncDevices.contains(where: { $0.id == deviceID }) else { return .disabled }
        guard let enabled = preferences.optionalBool(deviceConsentKey(deviceID)) else { return .needsConfirmation }
        return enabled ? .enabled : .disabled
    }

    package func setDeviceSyncEnabled(_ enabled: Bool, deviceID: String) {
        guard let device = syncDevices.first(where: { $0.id == deviceID }) else { return }
        guard syncConsent(for: deviceID) != (enabled ? .enabled : .disabled) else { return }
        preferences.setBool(enabled, deviceConsentKey(deviceID))
        for pairID in device.pairIDs {
            // Keep old preferences consistent for a possible app downgrade.
            preferences.setBool(enabled, "terminalQuickPhrases.sync.\(pairID)")
            syncErrors[pairID] = nil
        }
        consentRevision += 1
        notify()
    }

    package func syncStatus(for deviceID: String) -> QuickPhraseSyncStatus {
        guard loadError == nil else { return .unavailable }
        switch syncConsent(for: deviceID) {
        case .disabled: return .disabled
        case .needsConfirmation: return .needsConfirmation
        case .enabled: break
        }
        let states = syncDevices.first(where: { $0.id == deviceID })?.pairIDs.compactMap { syncConnections[$0]?.status } ?? []
        // One usable route suffices, even when the reverse pairing is offline
        // or a peer still has mixed settings on an older app version.
        if states.contains(.ready) { return .ready }
        if states.contains(.waitingForPeer) { return .waitingForPeer }
        if states.contains(.unsupported) { return .unsupported }
        return .offline
    }

    package func updateSyncConnection(pairID: String, epoch: UUID, status: QuickPhraseSyncStatus) {
        if let syncDeviceByPair, syncDeviceByPair[pairID] == nil { return }
        guard syncConnections[pairID]?.epoch != epoch || syncConnections[pairID]?.status != status else { return }
        syncConnections[pairID] = (epoch, status)
    }

    package func clearSyncConnection(pairID: String, epoch: UUID) {
        guard syncConnections[pairID]?.epoch == epoch else { return }
        syncConnections[pairID] = nil
        syncErrors[pairID] = nil
    }

    private func deviceConsentKey(_ deviceID: String) -> String { "terminalQuickPhrases.deviceSync.\(deviceID)" }

    package func observe(_ action: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = action
        return id
    }

    package func removeObserver(_ id: UUID) { observers[id] = nil }

    private func notify() {
        for action in Array(observers.values) { action() }
    }

    private func validate(_ values: [QuickPhraseRecord], ordering: QuickPhraseOrdering?) throws {
        // Bound the actual JSON (including escapes), leaving room for the E2EE
        // envelope/base64 inside the relay's 1 MB frame limit.
        guard values.count <= 4096,
              try JSONEncoder().encode(Library(version: 2, records: values, ordering: ordering)).count <= 512 * 1024
        else { throw SyncError.capacity }
        guard Set(values.map(\.id)).count == values.count else { throw SyncError.invalidLibrary }
        for record in values {
            guard (0..<Int.max - 1).contains(record.order) else { throw SyncError.invalidLibrary }
            if let text = record.text {
                guard try QuickPhrase.validatedText(text) == text else { throw SyncError.invalidLibrary }
            }
        }
        if let ordering {
            let ids = Set(ordering.phraseIDs)
            guard (1..<Int.max - 1).contains(ordering.revision),
                  ids.count == ordering.phraseIDs.count,
                  ids.isSubset(of: Set(values.map(\.id))) else { throw SyncError.invalidLibrary }
        }
    }

    private func apply(_ updated: [QuickPhraseRecord], ordering: QuickPhraseOrdering?) {
        self.ordering = ordering
        records = updated.sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
        let positions = Dictionary(uniqueKeysWithValues: (ordering?.phraseIDs ?? []).enumerated().map { ($0.element, $0.offset) })
        let displayed = positions.isEmpty ? records : records.sorted {
            let left = positions[$0.id] ?? Int.max, right = positions[$1.id] ?? Int.max
            if left != right { return left < right }
            return $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order
        }
        var texts = Set<String>()
        phrases = displayed.compactMap { record in
            guard let text = record.text, texts.insert(text).inserted else { return nil }
            return QuickPhrase(id: record.id, text: text)
        }
    }

    private func save(_ updated: [QuickPhraseRecord]) throws {
        try save(updated, ordering: ordering)
    }

    private func save(_ updated: [QuickPhraseRecord], ordering: QuickPhraseOrdering?) throws {
        guard loadError == nil else { throw CocoaError(.coderReadCorrupt) }
        try validate(updated, ordering: ordering)
        let sorted = updated.sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
        guard sorted != records || ordering != self.ordering else { return }
        let data = try JSONEncoder().encode(Library(version: 2, records: sorted, ordering: ordering))
        preferences.setData(data, Self.syncStorageKey)
        apply(sorted, ordering: ordering)
        notify()
    }
}
