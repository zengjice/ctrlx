import ConcurrencyExtras
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct WorkspaceEditorRecoveryTests {
    @Test("A pending editor read cannot publish after pane replacement or shutdown", arguments: [false, true])
    func pendingReadIdentity(replacePane: Bool) async throws {
        let original = WorkspacePaneIdentity(serverID: "100:1", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let current = LockIsolated(original)
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (content, contentContinuation) = AsyncStream<String>.makeStream()
        let manager = EditorSessionManager(readFile: { _ in
            startedContinuation.yield(())
            for await value in content {
                return value
            }
            throw EditorSessionError.requestChanged
        })
        manager.currentPaneIdentity = { _ in current.value }
        let request = Task {
            try await manager.handleAPIEditRequest(paneId: "%1", filePath: "/unused", expectedWorkspacePane: original)
        }
        defer {
            startedContinuation.finish()
            contentContinuation.finish()
            manager.cancelAll()
            request.cancel()
        }
        for await _ in started {
            break
        }
        if replacePane {
            current.withValue { $0.serverID = "200:2" }
        } else {
            manager.cancelAll()
        }
        contentContinuation.yield("old file contents")
        await #expect(throws: EditorSessionError.self) { try await request.value }
        #expect(manager.activeSessions.isEmpty && manager.editedContents.isEmpty)
    }

    @Test("Replacing a pane retires its editor and preserves text under the original identity", arguments: [false, true])
    func activeEditorIdentity(restart: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-editor-identity-\(UUID())")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let original = WorkspacePaneIdentity(serverID: "100:1", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let current = LockIsolated(original)
        let manager = EditorSessionManager(), drafts = WorkspaceRecoveryDrafts()
        manager.currentPaneIdentity = { _ in current.value }
        manager.onSessionInvalidated = { editor, text in drafts.retainInvalidatedEditor(editor, text: text) }
        let request = Task { try await manager.handleAPIEditRequest(paneId: "%1", filePath: file.path, expectedWorkspacePane: original) }
        defer { manager.cancelAll()
            request.cancel()
        }
        let editor = try await waitForEditor(manager)
        manager.editedContents["%1"] = "keep this draft"
        current.withValue { $0.sessionID = UUID()
            $0.windowID = UUID()
        }
        manager.reconcilePaneIdentities()
        #expect(manager.session(for: "%1")?.id == editor.id, "Moving a live pane retains its editor")
        current.withValue {
            if restart {
                $0.serverID = "200:2"
            } else {
                $0.paneID = UUID()
            }
        }
        #expect(manager.editorSessionInfo(for: "%1") == nil)
        #expect(!manager.submitSession(paneId: "%1", content: "stale submit"))
        var sessions = WorkspaceRecoveryStoreTests.snapshot().sessions
        sessions[0].windows[0].panes[0].runtimeID = "%1"
        sessions[0].windows[0].panes[0].id = original.paneID
        drafts.updateLocalRoutes(sessions)
        let beforeReconciliation = drafts.capture(editors: manager, sessions: sessions)
        #expect(beforeReconciliation.first?.paneID == original.paneID)
        manager.reconcilePaneIdentities()
        await #expect(throws: EditorSessionError.self) { try await request.value }
        #expect(manager.activeSessions.isEmpty)
        #expect(drafts.drafts.first?.paneID == original.paneID)
        #expect(drafts.drafts.map(\.text) == ["keep this draft"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
        #expect(drafts.localDrafts(paneID: "%1").isEmpty, "An old route must not expose the draft while discovery settles")
        sessions[0].windows[0].panes[0].id = UUID()
        drafts.updateLocalRoutes(sessions)
        #expect(drafts.localDrafts(paneID: "%1").isEmpty)
    }

    private func waitForEditor(_ manager: EditorSessionManager, replacing id: UUID? = nil) async throws -> EditorSession {
        for _ in 0..<200 {
            if let current = manager.session(for: "%1"), current.id != id {
                return current
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw EditorSessionError.requestChanged
    }

    @Test("Delayed submit and cancel cannot affect a replacement editor on the same pane")
    func replacementRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-editor-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstFile = directory.appendingPathComponent("first"), secondFile = directory.appendingPathComponent("second")
        try "first original".write(to: firstFile, atomically: true, encoding: .utf8)
        try "second original".write(to: secondFile, atomically: true, encoding: .utf8)
        let manager = EditorSessionManager()
        let first = Task { try await manager.handleAPIEditRequest(paneId: "%1", filePath: firstFile.path) }
        defer { manager.cancelAll()
            first.cancel()
        }
        let old = try await waitForEditor(manager)
        let second = Task { try await manager.handleAPIEditRequest(paneId: "%1", filePath: secondFile.path) }
        defer { second.cancel() }
        let current = try await waitForEditor(manager, replacing: old.id)
        try await first.value
        #expect(throws: EditorSessionError.self) {
            try manager.handleRemoteSubmit(paneId: "%1", content: "stale text", expectedSessionID: old.id)
        }
        #expect(throws: EditorSessionError.self) {
            try manager.handleRemoteCancel(paneId: "%1", expectedSessionID: old.id)
        }
        #expect(manager.session(for: "%1")?.id == current.id)
        #expect(try String(contentsOf: firstFile, encoding: .utf8) == "first original")
        #expect(try String(contentsOf: secondFile, encoding: .utf8) == "second original")
        try manager.handleRemoteSubmit(paneId: "%1", content: "current text", expectedSessionID: current.id)
        try await second.value
        #expect(manager.session(for: "%1") == nil)
        #expect(try String(contentsOf: secondFile, encoding: .utf8) == "current text")
        #expect(throws: EditorSessionError.self) {
            try manager.handleRemoteSubmit(paneId: "%1", content: "duplicate", expectedSessionID: current.id)
        }
    }

    @Test("A failed editor write leaves the request and text available for a successful retry")
    func writeFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-editor-write-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("draft")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        let manager = EditorSessionManager()
        let request = Task { try await manager.handleAPIEditRequest(paneId: "%1", filePath: file.path) }
        defer { manager.cancelAll()
            request.cancel()
        }
        let editor = try await waitForEditor(manager)
        manager.editedContents["%1"] = "unsent local edit"
        try FileManager.default.removeItem(at: directory)
        #expect(throws: (any Error).self) {
            try manager.handleRemoteSubmit(paneId: "%1", content: "remote edit", expectedSessionID: editor.id)
        }
        #expect(!manager.submitSession(paneId: "%1", content: "local attempt"))
        #expect(manager.session(for: "%1")?.id == editor.id)
        #expect(manager.editedContents["%1"] == "unsent local edit")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.handleRemoteSubmit(paneId: "%1", content: "retried remote edit", expectedSessionID: editor.id)
        try await request.value
        #expect(try String(contentsOf: file, encoding: .utf8) == "retried remote edit")
    }

    @Test("Matching and legacy cancellation leave the file untouched; an ended request reports failure", arguments: [false, true])
    func cancelRequest(legacy: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-editor-cancel-\(UUID())")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let manager = EditorSessionManager()
        let request = Task { try await manager.handleAPIEditRequest(paneId: "%1", filePath: file.path) }
        defer { manager.cancelAll()
            request.cancel()
        }
        let editor = try await waitForEditor(manager)
        try manager.handleRemoteCancel(paneId: "%1", expectedSessionID: legacy ? nil : editor.id)
        try await request.value
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
        #expect(throws: EditorSessionError.self) { try manager.handleRemoteCancel(paneId: "%1") }
    }

    @Test("A fast Viewer response completes even while the editor state broadcast is suspended")
    func responseDuringPublication() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-editor-publication-\(UUID())")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let manager = EditorSessionManager()
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish()
            manager.cancelAll()
        }
        manager.onSessionChanged = { for await _ in gate {
            break
        } }
        var completed = false
        let request = Task {
            try await manager.handleAPIEditRequest(paneId: "%1", filePath: file.path)
            completed = true
        }
        defer { request.cancel() }
        let editor = try await waitForEditor(manager)
        try manager.handleRemoteSubmit(paneId: "%1", content: "fast response", expectedSessionID: editor.id)
        for _ in 0..<200 where !completed {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(completed)
        release.finish()
        try await request.value
    }
}
