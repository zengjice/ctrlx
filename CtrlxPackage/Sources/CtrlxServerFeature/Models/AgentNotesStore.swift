import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Observation

/// Local notes follow a persistent pane, including moves between workbench windows.
struct AgentNoteScope: Codable, Hashable, Sendable {
    let hostID: String?
    let paneID: UUID
}

struct AgentNote: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var text: String
    let createdAt: Date
    var updatedAt: Date

    var preview: String {
        String(text.prefix(600))
    }
}

@MainActor @Observable
final class AgentNotesStore {
    private struct PaneCatalog {
        let revision = UUID()
        let panes: Set<UUID>
    }

    private struct Collection: Codable {
        let scope: AgentNoteScope
        var notes: [AgentNote]
    }

    private struct Archive: Codable {
        let version: Int
        var collections: [Collection]
    }

    static let storageKey = "agentNotes.v1"
    private(set) var issue: String?
    private var collections: [AgentNoteScope: [AgentNote]] = [:]
    @ObservationIgnored private var paneCatalogs: [String?: PaneCatalog] = [:]
    @ObservationIgnored @Dependency(PreferencesService.self) private var preferences
    @ObservationIgnored @Dependency(\.date.now) private var now

    init() {
        guard let data = preferences.data(Self.storageKey) else { return }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1 else { throw NoteError("These notes were saved by a newer version of CtrlX.") }
            for collection in archive.collections {
                guard
                    collections[collection.scope] == nil,
                    Set(collection.notes.map(\.id)).count == collection.notes.count else {
                    throw NoteError("The saved notes contain duplicate entries.")
                }
                collections[collection.scope] = collection.notes
            }
        } catch {
            self.collections = [:]
            self.issue = "Saved notes could not be read. The original data has been kept. \(error.localizedDescription)"
        }
    }

    func notes(for scope: AgentNoteScope) -> [AgentNote] {
        collections[scope] ?? []
    }

    /// A captured editor remains valid until a later confirmed catalog closes its pane.
    func availability(for scope: AgentNoteScope) -> @MainActor () -> Bool {
        let openedAt = paneCatalogs[scope.hostID]?.revision
        return { [weak self] in
            guard let catalog = self?.paneCatalogs[scope.hostID] else { return true }
            return catalog.revision == openedAt || catalog.panes.contains(scope.paneID)
        }
    }

    func reconcile(_ state: SessionStateMessage) {
        guard
            state.hasAuthoritativePaneSnapshot == true, state.workspaceIdentity != nil,
            state.paneStates.values.allSatisfy({ $0.workspaceIdentity != nil }) else { return }
        reconcile(hostID: state.pairId, livePanes: Set(state.paneStates.values.compactMap { $0.workspaceIdentity?.paneID }))
    }

    @discardableResult
    func save(_ text: String, id: UUID? = nil, for scope: AgentNoteScope) throws -> UUID? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var notes = notes(for: scope)
        let note: AgentNote
        if let id {
            guard let index = notes.firstIndex(where: { $0.id == id }) else { throw NoteError("This note was deleted. Open the notes list again.") }
            var existing = notes.remove(at: index)
            existing.text = text
            existing.updatedAt = now
            note = existing
        } else {
            note = .init(id: UUID(), text: text, createdAt: now, updatedAt: now)
        }
        notes.insert(note, at: 0)
        var updated = collections
        updated[scope] = notes
        try commit(updated)
        return note.id
    }

    func delete(_ id: UUID, for scope: AgentNoteScope) throws {
        var updated = collections
        updated[scope]?.removeAll { $0.id == id }
        if updated[scope]?.isEmpty == true {
            updated.removeValue(forKey: scope)
        }
        try commit(updated)
    }

    /// Only call with a complete, current pane catalog; disconnects are not closes.
    func reconcile(hostID: String?, livePanes: Set<UUID>) {
        paneCatalogs[hostID] = PaneCatalog(panes: livePanes)
        let updated = collections.filter { $0.key.hostID != hostID || livePanes.contains($0.key.paneID) }
        guard updated.count != collections.count else { return }
        do { try commit(updated) }
        catch { issue = error.localizedDescription }
    }

    private func commit(_ updated: [AgentNoteScope: [AgentNote]]) throws {
        if let issue {
            throw NoteError(issue)
        }
        let entries = updated.map { Collection(scope: $0.key, notes: $0.value) }
        let data = try JSONEncoder().encode(Archive(version: 1, collections: entries))
        preferences.setData(entries.isEmpty ? nil : data, Self.storageKey)
        collections = updated
    }

    struct NoteError: Error, LocalizedError {
        let message: String
        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? {
            message
        }
    }
}

/// A shallow fan leaves the leading edge of every card clickable.
struct AgentNoteFanPosition: Equatable {
    let x: Double
    let y: Double
    let angle: Double

    init(index: Int, count: Int, width: Double) {
        let center = Double(max(count - 1, 0)) / 2
        let normalized = center == 0 ? 0 : (Double(index) - center) / center
        let spacing = count <= 1 ? 0 : min(136, max(0, width - 256) / Double(count - 1))
        self.x = (Double(index) - center) * spacing
        self.y = normalized * normalized * 32
        self.angle = normalized * 12
    }
}
