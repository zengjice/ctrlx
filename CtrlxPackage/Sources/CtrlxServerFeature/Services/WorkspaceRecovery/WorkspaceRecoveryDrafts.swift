import CtrlxCommon
import CtrlxNetworking
import Foundation
import Observation

/// Text recovery is deliberately independent of a live editor request. Old temp
/// file paths, continuations and submit actions never survive an App restart.
@MainActor @Observable
final class WorkspaceRecoveryDrafts {
    private(set) var drafts: [WorkspaceRecoveryDraft] = []
    private var localPaneIDs: [String: UUID] = [:]
    private var restoredIDs: Set<UUID> = []
    private struct RemoteEditor {
        var draftID = UUID()
        var pane: ViewerWorkspaceReference
        var original: String
    }

    private var remoteEditors: [RemoteEditorContentStore.Key: RemoteEditor] = [:]
    private var remoteDraftIDs: [RemoteEditorContentStore.Key: UUID] = [:]
    private var remoteCatalogs: [String: ViewerWorkspaceCatalog] = [:]
    private var suspendedHosts: Set<String> = []
    private var clearedEditors: Set<RemoteEditorContentStore.Key> = []

    func restore(_ saved: [WorkspaceRecoveryDraft], sessions: [WorkspaceRecoverySession]) {
        drafts += saved.filter { !restoredIDs.contains($0.id) }
        restoredIDs.formUnion(saved.map(\.id))
        updateLocalRoutes(sessions)
    }

    func updateLocalRoutes(_ sessions: [WorkspaceRecoverySession]) {
        localPaneIDs = Dictionary(sessions.flatMap(\.windows).flatMap(\.panes).map { ($0.runtimeID, $0.id) }, uniquingKeysWith: { first, _ in first })
    }

    func localDrafts(paneID: String) -> [WorkspaceRecoveryDraft] {
        guard let identity = localPaneIDs[paneID] else { return [] }
        return drafts.filter { $0.hostID == nil && $0.paneID == identity }
    }

    func remoteDrafts(paneID: String, hostID: String) -> [WorkspaceRecoveryDraft] {
        guard !suspendedHosts.contains(hostID), let reference = remoteCatalogs[hostID]?.reference(paneID: paneID) else { return [] }
        let active = Set(remoteEditors.values.map(\.draftID))
        return drafts.filter { $0.remoteReference == reference && !active.contains($0.id) }
    }

    func updateRemote(_ state: SessionStateMessage, editors: RemoteEditorContentStore) {
        captureRemote(editors: editors)
        let catalog = ViewerWorkspaceCatalog(state: state)
        if remoteCatalogs[state.pairId]?.scope != catalog?.scope {
            remoteEditors = remoteEditors.filter { $0.key.hostID != state.pairId }
            remoteDraftIDs = remoteDraftIDs.filter { $0.key.hostID != state.pairId }
            clearedEditors = clearedEditors.filter { $0.hostID != state.pairId }
            editors.invalidate(hostID: state.pairId)
        }
        remoteCatalogs[state.pairId] = catalog
        suspendedHosts.remove(state.pairId)
        let active = Set(state.paneStates.values.compactMap { $0.editorSession?.sessionId })
        remoteEditors = remoteEditors.filter { $0.key.hostID != state.pairId || active.contains($0.key.sessionID) }
        clearedEditors = clearedEditors.filter { $0.hostID != state.pairId || active.contains($0.sessionID) }
        guard let catalog else { return }
        for pane in state.paneStates.values {
            guard let editor = pane.editorSession, let reference = catalog.reference(paneID: pane.paneId) else { continue }
            let key = RemoteEditorContentStore.Key(hostID: state.pairId, sessionID: editor.sessionId)
            guard !clearedEditors.contains(key) else { continue }
            if remoteEditors[key]?.pane != reference {
                remoteEditors[key] = RemoteEditor(pane: reference, original: editor.content)
            }
        }
    }

    func captureRemote(editors: RemoteEditorContentStore) {
        for (key, editor) in remoteEditors {
            let text = editors.editedContents[key] ?? editor.original
            drafts.removeAll { $0.id == editor.draftID }
            remoteDraftIDs.removeValue(forKey: key)
            guard !text.isEmpty, let paneID = editor.pane.paneID else { continue }
            drafts.append(.init(id: editor.draftID, hostID: editor.pane.pairID, paneID: paneID, text: text, remoteReference: editor.pane))
            remoteDraftIDs[key] = editor.draftID
        }
    }

    func clearRemote(_ key: RemoteEditorContentStore.Key, submittedText: String? = nil) {
        clearedEditors.insert(key)
        let editor = remoteEditors.removeValue(forKey: key)
        guard let id = remoteDraftIDs.removeValue(forKey: key) ?? editor?.draftID else { return }
        if let submittedText, let draft = drafts.first(where: { $0.id == id }), draft.text != submittedText {
            return
        }
        drafts.removeAll { $0.id == id }
    }

    func suspendRemote(_ hostID: String, editors: RemoteEditorContentStore) {
        captureRemote(editors: editors)
        suspendedHosts.insert(hostID)
    }

    func retainHosts(_ hostIDs: Set<String>) {
        drafts.removeAll { $0.hostID.map { !hostIDs.contains($0) } ?? false }
        remoteEditors = remoteEditors.filter { hostIDs.contains($0.key.hostID) }
        remoteDraftIDs = remoteDraftIDs.filter { hostIDs.contains($0.key.hostID) }
        remoteCatalogs = remoteCatalogs.filter { hostIDs.contains($0.key) }
        suspendedHosts.formIntersection(hostIDs)
        clearedEditors = clearedEditors.filter { hostIDs.contains($0.hostID) }
    }

    func text(id: UUID) -> String {
        drafts.first { $0.id == id }?.text ?? ""
    }

    func edit(id: UUID, text: String) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].text = text
    }

    func discard(id: UUID) {
        drafts.removeAll { $0.id == id }
        remoteDraftIDs = remoteDraftIDs.filter { $0.value != id }
    }

    func retainInvalidatedEditor(_ editor: EditorSession, text: String) {
        guard let identity = editor.workspaceIdentity, !text.isEmpty else { return }
        if localPaneIDs[editor.paneId] == identity.paneID {
            localPaneIDs.removeValue(forKey: editor.paneId)
        }
        drafts.removeAll { $0.id == editor.id }
        drafts.append(.init(id: editor.id, paneID: identity.paneID, text: text))
    }

    func capture(editors: EditorSessionManager, sessions: [WorkspaceRecoverySession]) -> [WorkspaceRecoveryDraft] {
        let identities = Dictionary(sessions.flatMap(\.windows).flatMap(\.panes).map { ($0.runtimeID, $0.id) }, uniquingKeysWith: { first, _ in first })
        var result = drafts
        for editor in editors.activeSessions.values {
            guard let paneID = editor.workspaceIdentity?.paneID ?? identities[editor.paneId] else { continue }
            let draft = WorkspaceRecoveryDraft(
                id: editor.id,
                hostID: nil,
                paneID: paneID,
                text: editors.editedContents[editor.paneId] ?? editor.originalContent
            )
            result.removeAll { $0.id == draft.id }
            result.append(draft)
        }
        return result.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
