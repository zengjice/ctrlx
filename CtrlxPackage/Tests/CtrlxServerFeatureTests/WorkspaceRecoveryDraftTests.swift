import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct WorkspaceRecoveryDraftTests {
    private let hostID = UUID()
    private let paneIdentity = WorkspacePaneIdentity(serverID: "100:1", sessionID: UUID(), windowID: UUID(), paneID: UUID())
    private let editorID = UUID()

    private func remoteState(pair: String = "pair", root: UUID? = nil, editor: Bool = true) -> SessionStateMessage {
        .init(pairId: pair, paneStates: ["%0": .init(
            paneId: "%0", sessionName: "project", windowIndex: 0, tmuxWindowId: "@0", currentPath: "/project",
            editorSession: editor ? .init(sessionId: editorID, content: "original") : nil,
            workspaceIdentity: paneIdentity
        )], workspaceIdentity: .init(hostID: root ?? hostID, serverID: paneIdentity.serverID))
    }

    @Test("Remote drafts retain edits across a transport interruption and become text only after the editor ends")
    func remoteReconnect() throws {
        let drafts = WorkspaceRecoveryDrafts(), editors = RemoteEditorContentStore()
        let key = RemoteEditorContentStore.Key(hostID: "pair", sessionID: editorID)
        drafts.updateRemote(remoteState(), editors: editors)
        editors.editedContents[key] = "unsent remote edit"
        drafts.suspendRemote("pair", editors: editors)
        #expect(drafts.drafts.map(\.text) == ["unsent remote edit"])
        #expect(drafts.remoteDrafts(paneID: "%0", hostID: "pair").isEmpty)
        drafts.updateRemote(remoteState(), editors: editors)
        #expect(editors.editedContents[key] == "unsent remote edit")
        #expect(drafts.drafts.count == 1)
        #expect(drafts.remoteDrafts(paneID: "%0", hostID: "pair").isEmpty)
        drafts.updateRemote(remoteState(editor: false), editors: editors)
        #expect(drafts.remoteDrafts(paneID: "%0", hostID: "pair").map(\.text) == ["unsent remote edit"])

        let saved = try JSONEncoder().encode(drafts.drafts)
        #expect(!String(decoding: saved, as: UTF8.self).contains(editorID.uuidString))
        let restored = WorkspaceRecoveryDrafts()
        try restored.restore(JSONDecoder().decode([WorkspaceRecoveryDraft].self, from: saved), sessions: [])
        restored.updateRemote(remoteState(editor: false), editors: RemoteEditorContentStore())
        #expect(restored.remoteDrafts(paneID: "%0", hostID: "pair").map(\.text) == ["unsent remote edit"])
    }

    @Test("Clearing remote text removes its saved draft; stale editor snapshots cannot recreate a submitted draft")
    func remoteClear() {
        let drafts = WorkspaceRecoveryDrafts(), editors = RemoteEditorContentStore()
        let key = RemoteEditorContentStore.Key(hostID: "pair", sessionID: editorID)
        drafts.updateRemote(remoteState(), editors: editors)
        drafts.captureRemote(editors: editors)
        #expect(drafts.drafts.count == 1)
        editors.editedContents[key] = ""
        drafts.captureRemote(editors: editors)
        #expect(drafts.drafts.isEmpty)
        editors.editedContents[key] = "submitted"
        drafts.captureRemote(editors: editors)
        drafts.clearRemote(key, submittedText: "submitted")
        drafts.updateRemote(remoteState(), editors: editors)
        drafts.captureRemote(editors: editors)
        #expect(drafts.drafts.isEmpty)
    }

    @Test("A late submit acknowledgement retains edits made after that submission, including after Host editor closure")
    func remoteSubmissionRace() {
        let drafts = WorkspaceRecoveryDrafts(), editors = RemoteEditorContentStore()
        let key = RemoteEditorContentStore.Key(hostID: "pair", sessionID: editorID)
        editors.onClear = { key, submittedText in
            drafts.captureRemote(editors: editors)
            drafts.clearRemote(key, submittedText: submittedText)
        }
        drafts.updateRemote(remoteState(), editors: editors)
        editors.editedContents[key] = "newer edit"
        editors.clear(key, submittedText: "sent earlier")
        #expect(editors.editedContents[key] == "newer edit")
        drafts.updateRemote(remoteState(editor: false), editors: editors)
        editors.retainOnly(activeSessionIds: [], hostID: "pair")
        editors.clear(key, submittedText: "sent earlier")
        #expect(drafts.remoteDrafts(paneID: "%0", hostID: "pair").map(\.text) == ["newer edit"])
    }

    @Test("A submit acknowledgement after Host editor closure removes only the submitted text")
    func remoteSubmissionAfterClosure() {
        let drafts = WorkspaceRecoveryDrafts(), editors = RemoteEditorContentStore()
        let key = RemoteEditorContentStore.Key(hostID: "pair", sessionID: editorID)
        drafts.updateRemote(remoteState(), editors: editors)
        editors.editedContents[key] = "submitted"
        drafts.updateRemote(remoteState(editor: false), editors: editors)
        drafts.clearRemote(key, submittedText: "submitted")
        #expect(drafts.drafts.isEmpty)
    }

    @Test("Remote editor identity includes pairing and Host root, and unpair removes only that Host's drafts")
    func remoteIsolation() {
        let drafts = WorkspaceRecoveryDrafts(), editors = RemoteEditorContentStore()
        let first = RemoteEditorContentStore.Key(hostID: "pair", sessionID: editorID)
        let second = RemoteEditorContentStore.Key(hostID: "other", sessionID: editorID)
        drafts.updateRemote(remoteState(), editors: editors)
        drafts.updateRemote(remoteState(pair: "other"), editors: editors)
        editors.editedContents[first] = "first"
        editors.editedContents[second] = "second"
        drafts.suspendRemote("pair", editors: editors)
        editors.retainOnly(activeSessionIds: [second], hostID: "other")
        #expect(editors.editedContents[first] == "first")
        drafts.updateRemote(remoteState(root: UUID(), editor: false), editors: editors)
        #expect(editors.editedContents[first] == nil)
        #expect(drafts.remoteDrafts(paneID: "%0", hostID: "pair").isEmpty)
        #expect(Set(drafts.drafts.map(\.text)) == ["first", "second"])
        drafts.retainHosts(["other"])
        #expect(drafts.drafts.map(\.text) == ["second"])
    }

    @Test("Recovered drafts follow persistent pane identity, never a recycled runtime ID")
    func routeIdentity() {
        let saved = WorkspaceRecoveryStoreTests.snapshot()
        let pane = saved.sessions[0].windows[0].panes[0]
        let draft = WorkspaceRecoveryDraft(id: UUID(), paneID: pane.id, text: "unsent text")
        var sessions = saved.sessions
        sessions[0].windows[0].panes[0].runtimeID = "%90"
        let store = WorkspaceRecoveryDrafts()
        store.restore([draft], sessions: sessions)
        #expect(store.localDrafts(paneID: "%1").isEmpty)
        #expect(store.localDrafts(paneID: "%90") == [draft])
        sessions[0].windows[0].panes[0].id = UUID()
        store.updateLocalRoutes(sessions)
        #expect(store.localDrafts(paneID: "%90").isEmpty)
        #expect(store.drafts == [draft], "Unavailable targets retain the draft for later recovery")
    }

    @Test("Recovery retries keep edited text and respect an explicitly discarded draft")
    func retryDoesNotOverwrite() {
        let saved = WorkspaceRecoveryStoreTests.snapshot()
        let draft = WorkspaceRecoveryDraft(id: UUID(), paneID: saved.sessions[0].windows[0].panes[0].id, text: "before restart")
        let store = WorkspaceRecoveryDrafts()
        store.restore([draft], sessions: saved.sessions)
        store.edit(id: draft.id, text: "edited after restart")
        store.restore([draft], sessions: saved.sessions)
        #expect(store.text(id: draft.id) == "edited after restart")
        let editor = EditorSessionManager()
        #expect(store.capture(editors: editor, sessions: saved.sessions)[0].text == "edited after restart")
        #expect(editor.activeSessions.isEmpty, "Restoring text never recreates an old editor request")
        store.discard(id: draft.id)
        store.restore([draft], sessions: saved.sessions)
        #expect(store.capture(editors: editor, sessions: saved.sessions).isEmpty)
        let later = WorkspaceRecoveryDraft(id: UUID(), paneID: draft.paneID, text: "a later interrupted editor")
        store.restore([draft, later], sessions: saved.sessions)
        #expect(store.drafts == [later])
    }

    @Test("An active prompt is captured without its temp path, and closing it removes it from subsequent snapshots")
    func activeEditorCapture() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-recovery-draft-\(UUID())")
        try "initial".write(to: file, atomically: true, encoding: .utf8)
        let editor = EditorSessionManager()
        let request = Task { try await editor.handleAPIEditRequest(paneId: "%1", filePath: file.path) }
        defer {
            editor.cancelAll()
            request.cancel()
            try? FileManager.default.removeItem(at: file)
        }
        for _ in 0..<200 where editor.activeSessions.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = try #require(editor.activeSessions["%1"])
        editor.editedContents["%1"] = "unsent edits"
        let store = WorkspaceRecoveryDrafts()
        let sessions = WorkspaceRecoveryStoreTests.snapshot().sessions
        let saved = store.capture(editors: editor, sessions: sessions)
        #expect(saved.count == 1 && saved.first?.text == "unsent edits")
        #expect(saved.first?.paneID == sessions[0].windows[0].panes[0].id)
        let encoded = try String(decoding: JSONEncoder().encode(saved), as: UTF8.self)
        #expect(!encoded.contains(file.path))
        #expect(try String(contentsOf: file, encoding: .utf8) == "initial")
        editor.cancelSession(paneId: "%1")
        try await request.value
        #expect(store.capture(editors: editor, sessions: sessions).isEmpty)
    }
}
