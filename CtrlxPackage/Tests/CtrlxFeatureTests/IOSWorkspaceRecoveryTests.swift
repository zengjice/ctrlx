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

    @Test("Mixed child order survives cold restore and delayed browser/simulator catalogs")
    func linkedTabOrder() async throws {
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
            let web = UUID(), simulator = UUID()
            let order: [PaneLinkedTabID] = [.simulator(simulator), .file(file), .browser(web)]
            workspace.recordLinkedTabOrder(order)
            await first.flushRecovery()
            let second = IOSFileBrowserWorkspaceStore()
            await second.prepareRecovery()
            second.update(state(includeFiles: false), client: client)
            second.update(state(), client: client)
            let restored = try #require(second.workspace(hostID: "pair", sessionName: "project"))
            #expect(restored.linkedTabOrder == order)
            restored.recordLinkedTabOrder([.browser(web), .file(file), .simulator(simulator)])
            second.update(state(), client: client)
            #expect(restored.linkedTabOrder == [.browser(web), .file(file), .simulator(simulator)])
            await second.flushRecovery()
            let third = IOSFileBrowserWorkspaceStore()
            await third.prepareRecovery()
            third.update(state(), client: client)
            #expect(third.workspace(hostID: "pair", sessionName: "project")?.linkedTabOrder == restored.linkedTabOrder)
        }
    }

    @Test("A reorder during partial discovery survives saving, restart and the delayed browser arrival")
    func reorderBeforeBrowserArrives() async throws {
        let disk = IOSWorkspaceRecoveryStore.inMemory()
        try await withDependencies {
            $0[IOSWorkspaceRecoveryStore.self] = disk
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let client = ViewerRelayClient()
            let initial = state()
            let a = try #require(initial.fileTabs?.first)
            let b = HostFileTab(sessionName: "project", windowID: "@1", sourcePaneID: "%1", initialDirectory: "/Host/B")
            let web = RemoteBrowserTab(id: UUID(), sessionName: "project", title: "Web", url: "about:blank", isLoading: false, isAgentOwned: false, sourcePaneID: "%1")
            func catalog(includeWeb: Bool) -> SessionStateMessage {
                .init(
                    pairId: initial.pairId, paneStates: initial.paneStates,
                    browserTabs: includeWeb ? [web] : [],
                    supportsPaneFiles: true, fileTabs: [a, b], workspaceIdentity: initial.workspaceIdentity
                )
            }
            let first = IOSFileBrowserWorkspaceStore()
            await first.prepareRecovery()
            first.update(catalog(includeWeb: true), client: client)
            let workspace = try #require(first.workspace(hostID: "pair", sessionName: "project"))
            workspace.recordLinkedTabOrder([.file(a.id), .browser(web.id), .file(b.id)])
            await first.flushRecovery()

            let second = IOSFileBrowserWorkspaceStore()
            await second.prepareRecovery()
            second.update(catalog(includeWeb: false), client: client)
            let restored = try #require(second.workspace(hostID: "pair", sessionName: "project"))
            let windows = TmuxWindow.groupPanes(Array(initial.paneStates.values))
            let partial = IOSPaneLinkedTabs(files: restored.tabs, browsers: [], simulators: [], windows: windows, storedOrder: restored.linkedTabOrder)
            let group = try #require(partial.groups.first)
            restored.recordLinkedTabOrder(partial.moving(IndexSet(integer: 0), to: 2, in: group))
            let expected: [PaneLinkedTabID] = [.file(b.id), .browser(web.id), .file(a.id)]
            #expect(restored.linkedTabOrder == expected)
            second.update(catalog(includeWeb: false), client: client)
            await second.flushRecovery()
            #expect(try await disk.load()?.sessions.first?.linkedTabOrder == expected)

            let third = IOSFileBrowserWorkspaceStore()
            await third.prepareRecovery()
            third.update(catalog(includeWeb: false), client: client)
            third.update(catalog(includeWeb: true), client: client)
            let completed = try #require(third.workspace(hostID: "pair", sessionName: "project"))
            #expect(completed.linkedTabOrder == expected)
            let visible = IOSPaneLinkedTabs(files: completed.tabs, browsers: [web], simulators: [], windows: windows, storedOrder: completed.linkedTabOrder)
            #expect(visible.groups.first?.items == expected)
            await third.flushRecovery()
        }
    }

    @Test("Host Files restore their saved order through partial catalogs and subsequent live reorders", arguments: [false, true])
    func fileOrder(partialCatalog: Bool) async throws {
        let disk = IOSWorkspaceRecoveryStore.inMemory()
        try await withDependencies {
            $0[IOSWorkspaceRecoveryStore.self] = disk
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let client = ViewerRelayClient()
            let initial = state()
            func catalog(_ files: [HostFileTab]) -> SessionStateMessage {
                .init(
                    pairId: initial.pairId,
                    paneStates: initial.paneStates,
                    supportsPaneFiles: true,
                    fileTabs: files,
                    workspaceIdentity: initial.workspaceIdentity
                )
            }
            let a = try #require(initial.fileTabs?.first)
            let b = HostFileTab(sessionName: "project", windowID: "@1", sourcePaneID: "%1", initialDirectory: "/Host/B")
            let c = HostFileTab(sessionName: "project", windowID: "@1", sourcePaneID: "%1", initialDirectory: "/Host/C")
            let first = IOSFileBrowserWorkspaceStore()
            await first.prepareRecovery()
            first.update(catalog([a, b]), client: client)
            let workspace = try #require(first.workspace(hostID: "pair", sessionName: "project"))
            let privateFile = FileBrowserTab(path: "/Host/private")
            workspace.tabs.append(privateFile)
            workspace.selectedID = b.id
            workspace.reorder([b.id, privateFile.id, a.id])
            await first.flushRecovery()
            #expect(try await disk.load()?.sessions.first?.files.map(\.snapshot.id) == [b.id, privateFile.id, a.id])

            let second = IOSFileBrowserWorkspaceStore()
            await second.prepareRecovery()
            if partialCatalog {
                let partial = catalog([a])
                second.update(partial, client: client)
                second.update(partial, client: client)
                await second.flushRecovery()
                #expect(try await disk.load()?.sessions.first?.files.map(\.snapshot.id) == [b.id, privateFile.id, a.id])
            }
            let complete = catalog([a, b, c])
            second.update(complete, client: client)
            let restored = try #require(second.workspace(hostID: "pair", sessionName: "project"))
            #expect(restored.tabs.map(\.id) == [b.id, privateFile.id, a.id, c.id])
            #expect(restored.selectedID == b.id)
            let selected = restored.selected
            restored.reorder([c.id, a.id, b.id, privateFile.id])
            second.update(complete, client: client)
            #expect(restored.tabs.map(\.id) == [c.id, a.id, b.id, privateFile.id])
            #expect(restored.selected === selected)
            await second.flushRecovery()

            let third = IOSFileBrowserWorkspaceStore()
            await third.prepareRecovery()
            third.update(complete, client: client)
            #expect(third.workspace(hostID: "pair", sessionName: "project")?.tabs.map(\.id) == [c.id, a.id, b.id, privateFile.id])
        }
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

    @Test("A live tab close selects and saves the first survivor; a Host restart still waits for recovery", arguments: [false, true])
    func selectedWindowClosed(restarted: Bool) async throws {
        try await withDependencies {
            $0[IOSWorkspaceRecoveryStore.self] = .inMemory()
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let store = IOSFileBrowserWorkspaceStore(), client = ViewerRelayClient()
            await store.prepareRecovery()
            let initial = state(includeFiles: false)
            store.update(initial, client: client)
            let workspace = try #require(store.workspace(hostID: "pair", sessionName: "project"))
            store.recordSelection(workspace: workspace, window: TmuxWindow.groupPanes(Array(initial.paneStates.values)).first, paneID: "%1")
            let server = restarted ? "200:2" : "100:1"
            let firstWindow = UUID()
            let remaining = SessionStateMessage(pairId: "pair", paneStates: [
                "%2": .init(
                    paneId: "%2",
                    sessionName: "project",
                    windowIndex: 1,
                    tmuxWindowId: "@2",
                    workspaceIdentity: .init(serverID: server, sessionID: session, windowID: firstWindow, paneID: UUID())
                ),
                "%3": .init(
                    paneId: "%3",
                    sessionName: "project",
                    windowIndex: 2,
                    tmuxWindowId: "@3",
                    isWindowActive: true,
                    workspaceIdentity: .init(serverID: server, sessionID: session, windowID: UUID(), paneID: UUID())
                ),
            ], workspaceIdentity: .init(hostID: host, serverID: server))
            store.update(remaining, client: client)
            let updated = try #require(store.workspace(hostID: "pair", sessionName: "project"))
            #expect(updated.hasPendingTerminalSelection == restarted)
            if !restarted {
                #expect(updated === workspace)
                #expect(updated.restoredWindowID == "project:1")
                #expect(updated.restoredPaneID == "%2")
            }
            store.update(remaining, client: client)
            #expect(store.recovery.sessions.first?.selectedWindowID == (restarted ? window : firstWindow))
            await store.flushRecovery()
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
