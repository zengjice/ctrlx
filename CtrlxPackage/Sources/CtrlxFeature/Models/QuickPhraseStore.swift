import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Observation

struct QuickPhrase: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }

    /// Reject embedded controls instead of executing pasted newlines.
    static func validatedText(_ text: String) throws -> String {
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

    enum ValidationError: LocalizedError {
        case empty, multiline, duplicate

        var errorDescription: String? {
            switch self {
            case .empty: "Enter a phrase first."
            case .multiline: "Use a single line without control characters."
            case .duplicate: "This phrase is already saved."
            }
        }
    }

    var keys: [TmuxKey] { [.text(text), .delay(200), .enter] }
}

/// One store owned by IOSSettings, shared across all hosts/windows on this device.
@MainActor
@Observable
final class QuickPhraseStore {
    static let storageKey = "terminalQuickPhrases.v1"
    private(set) var phrases: [QuickPhrase] = []
    private(set) var loadError: String?

    @ObservationIgnored
    @Dependency(PreferencesService.self) private var preferences

    init() {
        guard let data = preferences.data(Self.storageKey) else { return }
        do {
            let saved = try JSONDecoder().decode([QuickPhrase].self, from: data)
            guard Set(saved.map(\.id)).count == saved.count else {
                throw CocoaError(.coderReadCorrupt)
            }
            for phrase in saved {
                guard try QuickPhrase.validatedText(phrase.text) == phrase.text else {
                    throw CocoaError(.coderReadCorrupt)
                }
            }
            phrases = saved
        } catch {
            // Do not overwrite an unreadable library with an empty list.
            loadError = "Saved phrases could not be read: \(error.localizedDescription)"
        }
    }

    func add(_ text: String) throws {
        let text = try QuickPhrase.validatedText(text)
        guard !phrases.contains(where: { $0.text == text }) else { throw QuickPhrase.ValidationError.duplicate }
        try save(phrases + [QuickPhrase(text: text)])
    }

    func remove(_ id: QuickPhrase.ID) throws {
        try save(phrases.filter { $0.id != id })
    }

    private func save(_ updated: [QuickPhrase]) throws {
        guard loadError == nil else { throw CocoaError(.coderReadCorrupt) }
        let data = try JSONEncoder().encode(updated)
        preferences.setData(data, Self.storageKey)
        phrases = updated
    }
}
