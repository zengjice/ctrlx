import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxFeature

@MainActor
struct IOSSessionEntryTests {
    private let hostID = UUID()
    private let sessionID = UUID()
    private let fileID = UUID()
    private let windowID = UUID()
    private let paneID = UUID()

    private func state(terminals: Bool = true, files: Bool = true) -> SessionStateMessage {
        let pane = PaneState(
            paneId: "%1", sessionName: "work", tmuxWindowId: "@1", currentPath: "/host",
            workspaceIdentity: .init(serverID: "server", sessionID: sessionID, windowID: windowID, paneID: paneID)
        )
        return .init(
            pairId: "host", paneStates: terminals ? ["%1": pane] : [:],
            fileTabs: files ? [.init(id: fileID, sessionName: "work", initialDirectory: "/host", resourceSessionID: sessionID)] : [],
            workspaceIdentity: .init(hostID: hostID, serverID: "server"),
            independentResources: .init(sessions: [.init(id: sessionID, name: "work", directory: "/host")])
        )
    }

    @Test("Normal entry clears cached Files selection without resetting its navigation")
    func normalEntry() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[IOSWorkspaceRecoveryStore.self] = .inMemory()
        } operation: {
            let store = IOSFileBrowserWorkspaceStore(), client = ViewerRelayClient()
            await store.prepareRecovery()
            let snapshot = state()
            store.update(snapshot, client: client)
            let workspace = try #require(store.workspace(hostID: "host", sessionName: "work"))
            let file = try #require(workspace.tabs.first)
            file.navigate("/host/nested")
            workspace.selectedID = fileID
            workspace.hasPendingTerminalSelection = true
            workspace.save()

            store.prepareForEntry(workspace, restoresSelection: false)
            #expect(workspace.selectedID == nil && workspace.hasPendingTerminalSelection)
            #expect(file.path == "/host/nested")
            #expect(store.recovery.sessions.first?.selectedFileID == nil)
            store.update(snapshot, client: client)
            #expect(workspace.selectedID == nil)

            workspace.selectedID = fileID
            store.update(snapshot, client: client)
            #expect(workspace.selectedID == fileID)
        }
    }

    @Test("Late Files descriptors restore selection only for explicit recovery", arguments: [false, true])
    func lateFiles(restoresSelection: Bool) async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[IOSWorkspaceRecoveryStore.self] = .inMemory()
        } operation: {
            let first = IOSFileBrowserWorkspaceStore(), client = ViewerRelayClient()
            await first.prepareRecovery()
            first.update(state(), client: client)
            let original = try #require(first.workspace(hostID: "host", sessionName: "work"))
            original.selectedID = fileID
            original.save()
            await first.flushRecovery()

            let next = IOSFileBrowserWorkspaceStore()
            await next.prepareRecovery()
            next.update(state(files: false), client: client)
            let workspace = try #require(next.workspace(hostID: "host", sessionName: "work"))
            #expect(workspace.selectedID == nil)
            next.prepareForEntry(workspace, restoresSelection: restoresSelection)
            next.update(state(), client: client)
            #expect(workspace.selectedID == (restoresSelection ? fileID : nil))
        }
    }

    @Test("Closing the last terminal may leave a pending restore while independent Files survives")
    func lastTerminalClosed() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[IOSWorkspaceRecoveryStore.self] = .inMemory()
        } operation: {
            let store = IOSFileBrowserWorkspaceStore(), client = ViewerRelayClient()
            await store.prepareRecovery()
            let snapshot = state()
            store.update(snapshot, client: client)
            let workspace = try #require(store.workspace(hostID: "host", sessionName: "work"))
            let window = try #require(TmuxWindow.groupPanes(Array(snapshot.paneStates.values)).first)
            workspace.selectedID = fileID
            store.recordSelection(workspace: workspace, window: window, paneID: "%1")
            #expect(store.recovery.sessions.first?.selectedWindowID == windowID)

            store.update(state(terminals: false), client: client)
            #expect(workspace.isResourceOnlySession && workspace.hasPendingTerminalSelection)
            #expect(workspace.selectedID == fileID)
            store.prepareForEntry(workspace, restoresSelection: false)
            #expect(workspace.selectedID == nil && workspace.hasPendingTerminalSelection)
            #expect(workspace.tabs.map(\.id) == [fileID])
        }
    }

    @Test("Only the complete Host snapshot establishes a resource-only session")
    func resourceOnlySession() throws {
        let store = IOSFileBrowserWorkspaceStore(), client = ViewerRelayClient()
        store.update(state(), client: client)
        let workspace = try #require(store.workspace(hostID: "host", sessionName: "work"))
        #expect(!workspace.isResourceOnlySession)
        store.update(state(terminals: false), client: client)
        #expect(workspace.isResourceOnlySession)
        store.suspendHost("host")
        #expect(!workspace.isResourceOnlySession)
        store.update(state(terminals: false), client: client)
        #expect(workspace.isResourceOnlySession)
        store.update(state(), client: client)
        #expect(!workspace.isResourceOnlySession)
    }
}
