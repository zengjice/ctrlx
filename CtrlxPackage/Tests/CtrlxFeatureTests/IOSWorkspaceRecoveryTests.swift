import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxFeature

@MainActor
struct IOSWorkspaceRecoveryTests {
    private let host = UUID()
    private let session = UUID()
    private let window = UUID()
    private let pane = UUID()
    private let file = UUID()

    private func state(server: String = "100:1", name: String = "project", runtime: String = "%1", windowRuntime: String = "@1", includeFiles: Bool = true, root: UUID? = nil, sessionID: UUID? = nil, pair: String = "pair", paneID: UUID? = nil) -> SessionStateMessage {
        .init(pairId: pair, paneStates: [runtime: .init(
            paneId: runtime, sessionName: name, tmuxWindowId: windowRuntime, currentPath: "/Host/project",
            workspaceIdentity: .init(serverID: server, sessionID: sessionID ?? session, windowID: window, paneID: paneID ?? pane)
        )], supportsPaneFiles: true, fileTabs: includeFiles ? [.init(id: file, sessionName: name, windowID: windowRuntime, sourcePaneID: runtime, initialDirectory: "/Host/project")] : [], workspaceIdentity: .init(hostID: root ?? host, serverID: server))
    }

    @Test("Cold restore follows UUIDs through renamed sessions and new runtime IDs, preserving Files and drafts")
    func restore() async throws {
        let disk = IOSWorkspaceRecoveryStore.inMemory()
        try await withDependencies {
            $0[IOSWorkspaceRecoveryStore.self] = disk
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let client = ViewerRelayClient()
            let first = IOSFileBrowserWorkspaceStore()
            await first.prepareRecovery()
            first.update(state(), client: client)
            let workspace = try #require(first.workspace(hostID: "pair", sessionName: "project"))
            let hostFile = try #require(workspace.tabs.first)
            hostFile.navigate("/Host/private-navigation")
            hostFile.selectedFile = "/Host/private-navigation/readme.md"
            let privateFile = FileBrowserTab(path: "/Host/other", sourcePaneID: "%1")
            privateFile.expanded = ["/Host/other/child"]
            workspace.tabs.append(privateFile)
            workspace.selectedID = hostFile.id
            first.recordSelection(workspace: workspace, window: TmuxWindow.groupPanes(Array(state().paneStates.values)).first, paneID: "%1")
            first.selectSession(workspace.recoveryReference)
            let reference = try #require(first.catalogs["pair"]?.reference(paneID: "%1"))
            let draftID = UUID()
            first.recordDraft(id: draftID, pane: reference, text: "unsent text")
            await first.flushRecovery()

            let second = IOSFileBrowserWorkspaceStore()
            await second.prepareRecovery()
            #expect(second.recovery.selectedSession == reference.sessionReference)
            let restoredState = state(server: "200:2", name: "renamed", runtime: "%20", windowRuntime: "@30", includeFiles: false)
            second.update(restoredState, client: client)
            let restored = try #require(second.workspace(hostID: "pair", sessionName: "renamed"))
            #expect(restored.recoveryID != workspace.recoveryID)
            #expect(restored.restoredWindowID == "renamed:0" && restored.restoredPaneID == "%20")
            #expect(restored.tabs.map(\.id) == [privateFile.id])
            #expect(restored.tabs.first?.sourcePaneID == "%20")
            #expect(restored.tabs.first?.expanded == privateFile.expanded)
            #expect(second.drafts(paneID: "%20", hostID: "pair").map(\.text) == ["unsent text"])
            #expect(second.drafts(paneID: "%1", hostID: "pair").isEmpty)
            let complete = state(server: "200:2", name: "renamed", runtime: "%20", windowRuntime: "@30")
            second.update(complete, client: client)
            #expect(restored.selectedID == hostFile.id)
            #expect(restored.selected?.path == "/Host/private-navigation")
            #expect(restored.selected?.selectedFile == "/Host/private-navigation/readme.md")
            restored.selected?.navigate("/Host/user-change")
            second.update(complete, client: client)
            #expect(restored.selected?.path == "/Host/user-change")
            restored.close(privateFile.id)
            second.update(complete, client: client)
            #expect(!restored.tabs.contains { $0.id == privateFile.id })
            second.suspendHost("pair")
            #expect(restored.selectedID == hostFile.id)
            await second.flushRecovery()
            let saved = try #require(try await disk.load())
            #expect(saved.sessions.first?.files.first?.snapshot.path == "/Host/user-change")
            #expect(saved.drafts.first?.id == draftID)
        }
    }

    @Test("Replacement Hosts, sessions and pairings cannot inherit private state", arguments: ["host", "session", "pair"])
    func replacements(kind: String) async throws {
        try await withDependencies {
            $0[IOSWorkspaceRecoveryStore.self] = .inMemory()
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let store = IOSFileBrowserWorkspaceStore(), client = ViewerRelayClient()
            await store.prepareRecovery()
            store.update(state(), client: client)
            let original = try #require(store.workspace(hostID: "pair", sessionName: "project"))
            original.tabs.first?.navigate("/Host/must-not-leak")
            store.recordSelection(workspace: original, window: TmuxWindow.groupPanes(Array(state().paneStates.values)).first, paneID: "%1")
            let pair = kind == "pair" ? "other" : "pair"
            store.update(state(root: kind == "host" ? UUID() : nil, sessionID: kind == "session" ? UUID() : nil, pair: pair), client: client)
            let replacement = try #require(store.workspace(hostID: pair, sessionName: "project"))
            #expect(replacement !== original)
            #expect(replacement.tabs.first?.path == "/Host/project")
            #expect(replacement.restoredWindowID == nil)
            store.recordSelection(workspace: original, window: TmuxWindow.groupPanes(Array(state().paneStates.values)).first, paneID: "%1")
            #expect(replacement.restoredWindowID == nil)
            await store.flushRecovery()
            #expect(store.recoveryError == nil)
        }
    }

    @Test("Offline records survive empty snapshots; unpairing removes only that Host's records")
    func offline() async throws {
        try await withDependencies {
            $0[IOSWorkspaceRecoveryStore.self] = .inMemory()
        } operation: {
            let store = IOSFileBrowserWorkspaceStore(), client = ViewerRelayClient()
            await store.prepareRecovery()
            store.update(state(), client: client)
            let workspace = try #require(store.workspace(hostID: "pair", sessionName: "project"))
            store.recordSelection(workspace: workspace, window: TmuxWindow.groupPanes(Array(state().paneStates.values)).first, paneID: "%1")
            store.selectSession(workspace.recoveryReference)
            let saved = store.recovery
            store.suspendHost("pair")
            store.update(.init(pairId: "pair", paneStates: [:]), client: client)
            #expect(store.recovery == saved)
            store.retainHosts(["pair"])
            #expect(store.recovery == saved)
            store.retainHosts([])
            #expect(store.recovery.sessions.isEmpty && store.recovery.selectedSession == nil)
            await store.flushRecovery()
        }
    }

    @Test("Partial discovery and recycled pane numbers cannot replace pending selection or Files sources")
    func partialDiscovery() async throws {
        try await withDependencies {
            $0[IOSWorkspaceRecoveryStore.self] = .inMemory()
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let store = IOSFileBrowserWorkspaceStore(), client = ViewerRelayClient()
            await store.prepareRecovery()
            store.update(state(), client: client)
            let workspace = try #require(store.workspace(hostID: "pair", sessionName: "project"))
            let file = FileBrowserTab(path: "/Host/private", sourcePaneID: "%1")
            workspace.tabs.append(file)
            store.recordSelection(workspace: workspace, window: TmuxWindow.groupPanes(Array(state().paneStates.values)).first, paneID: "%1")
            let partial = state(includeFiles: false, paneID: UUID())
            store.update(partial, client: client)
            #expect(workspace.hasPendingTerminalSelection)
            #expect(file.sourcePaneID == nil)
            #expect(workspace.unavailableFileSources.contains(file.id))
            store.recordSelection(workspace: workspace, window: TmuxWindow.groupPanes(Array(state().paneStates.values)).first, paneID: "%1")
            store.update(partial, client: client)
            #expect(store.recovery.sessions.first?.selectedPaneID == pane)
            #expect(store.recovery.sessions.first?.files.first(where: { $0.snapshot.id == file.id })?.source?.paneID == pane)
            store.update(state(runtime: "%20"), client: client)
            #expect(!workspace.hasPendingTerminalSelection)
            #expect(workspace.restoredPaneID == "%20")
            #expect(file.sourcePaneID == "%20")
            #expect(!workspace.unavailableFileSources.contains(file.id))
            workspace.selectedID = file.id
            workspace.save()
            workspace.close(file.id)
            #expect(store.recovery.sessions.first?.selectedFileID == nil)
            await store.flushRecovery()
            #expect(store.recoveryError == nil)
        }
    }

    @Test("Draft confirmation cannot erase newer text and never stores a live request")
    func drafts() async throws {
        try await withDependencies { $0[IOSWorkspaceRecoveryStore.self] = .inMemory() } operation: {
            let store = IOSFileBrowserWorkspaceStore()
            await store.prepareRecovery()
            store.update(state(), client: ViewerRelayClient())
            let reference = try #require(store.catalogs["pair"]?.reference(paneID: "%1"))
            let id = UUID()
            store.recordDraft(id: id, pane: reference, text: "old")
            store.editDraft(id, text: "new")
            store.discardDraft(id, submittedText: "old")
            #expect(store.recovery.drafts.first?.text == "new")
            store.discardDraft(id, submittedText: "new")
            #expect(store.recovery.drafts.isEmpty)
            await store.flushRecovery()
        }
    }

    @Test("Atomic storage deduplicates and preserves a complete backup; invalid files block writes", arguments: [false, true])
    func storage(unknownVersion: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-ios-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSWorkspaceRecoveryStore.diskBacked(directory: directory)
        let reference = ViewerWorkspaceReference(pairID: "pair", hostID: host, sessionID: session)
        let first = IOSWorkspaceRecoverySnapshot(sessions: [.init(reference: reference, name: "project")])
        try await store.save(first)
        try await store.save(first)
        let file = directory.appendingPathComponent("ios-workspace.json")
        let backup = directory.appendingPathComponent("ios-workspace.previous.json")
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        var second = first
        second.selectedSession = reference
        try await store.save(second)
        #expect(try JSONDecoder().decode(IOSWorkspaceRecoverySnapshot.self, from: Data(contentsOf: backup)) == first)
        var invalid = second
        invalid.version = 999
        let bytes = try unknownVersion ? JSONEncoder().encode(invalid) : Data("broken".utf8)
        try bytes.write(to: file)
        let reopened = IOSWorkspaceRecoveryStore.diskBacked(directory: directory)
        await #expect(throws: (any Error).self) { try await reopened.load() }
        await #expect(throws: (any Error).self) { try await reopened.save(first) }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try JSONDecoder().decode(IOSWorkspaceRecoverySnapshot.self, from: Data(contentsOf: backup)) == first)
    }

    @Test("A failed checkpoint preserves the last complete snapshot and permits retry")
    func failedWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-ios-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSWorkspaceRecoveryStore.diskBacked(directory: directory)
        let reference = ViewerWorkspaceReference(pairID: "pair", hostID: host, sessionID: session)
        let original = IOSWorkspaceRecoverySnapshot(sessions: [.init(reference: reference, name: "project")])
        try await store.save(original)
        let backup = directory.appendingPathComponent("ios-workspace.previous.json")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        var changed = original
        changed.selectedSession = reference
        await #expect(throws: (any Error).self) { try await store.save(changed) }
        #expect(try await IOSWorkspaceRecoveryStore.diskBacked(directory: directory).load() == original)
        try FileManager.default.removeItem(at: backup)
        try await store.save(changed)
        #expect(try await IOSWorkspaceRecoveryStore.diskBacked(directory: directory).load() == changed)
    }
}
