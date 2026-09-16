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
    package private(set) var records: [QuickPhraseRecord] = []
    private var consentRevision = 0
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]

    private struct Library: Codable {
        let version: Int
        let records: [QuickPhraseRecord]
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
                try validate(library.records)
                apply(library.records)
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

    package func merge(_ incoming: [QuickPhraseRecord]) throws {
        try validate(incoming)
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
        try save(Array(merged.values))
    }

    package func isSyncEnabled(for pairID: String) -> Bool {
        _ = consentRevision
        return preferences.optionalBool("terminalQuickPhrases.sync.\(pairID)") == true
    }

    package func setSyncEnabled(_ enabled: Bool, for pairID: String) {
        guard enabled != isSyncEnabled(for: pairID) else { return }
        preferences.setBool(enabled, "terminalQuickPhrases.sync.\(pairID)")
        consentRevision += 1
        syncErrors[pairID] = nil
        notify()
    }

    package func observe(_ action: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = action
        return id
    }

    package func removeObserver(_ id: UUID) { observers[id] = nil }

    private func notify() {
        for action in Array(observers.values) { action() }
    }

    private func validate(_ values: [QuickPhraseRecord]) throws {
        // Bound the actual JSON (including escapes), leaving room for the E2EE
        // envelope/base64 inside the relay's 1 MB frame limit.
        guard values.count <= 4096, try JSONEncoder().encode(values).count <= 512 * 1024
        else { throw SyncError.capacity }
        guard Set(values.map(\.id)).count == values.count else { throw SyncError.invalidLibrary }
        for record in values {
            guard (0..<Int.max - 1).contains(record.order) else { throw SyncError.invalidLibrary }
            if let text = record.text {
                guard try QuickPhrase.validatedText(text) == text else { throw SyncError.invalidLibrary }
            }
        }
    }

    private func apply(_ updated: [QuickPhraseRecord]) {
        records = updated.sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
        var texts = Set<String>()
        phrases = records.compactMap { record in
            guard let text = record.text, texts.insert(text).inserted else { return nil }
            return QuickPhrase(id: record.id, text: text)
        }
    }

    private func save(_ updated: [QuickPhraseRecord]) throws {
        guard loadError == nil else { throw CocoaError(.coderReadCorrupt) }
        try validate(updated)
        let sorted = updated.sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
        guard sorted != records else { return }
        let data = try JSONEncoder().encode(Library(version: 2, records: sorted))
        preferences.setData(data, Self.syncStorageKey)
        apply(sorted)
        notify()
    }
}
