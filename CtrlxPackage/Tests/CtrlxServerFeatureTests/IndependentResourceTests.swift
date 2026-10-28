import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor @Suite("Independent resource sessions")
struct IndependentResourceTests {
    func pane(session: UUID, name: String = "work") -> PaneInfo {
        .init(
            paneId: "%1",
            target: "\(name):0.0",
            sessionName: name,
            windowIndex: 0,
            tmuxWindowId: "@1",
            paneIndex: 0,
            command: "zsh",
            currentPath: "/tmp",
            width: 80,
            height: 24,
            isActive: true,
            workspaceIdentity: .init(serverID: "1:1", sessionID: session, windowID: UUID(), paneID: UUID())
        )
    }

    @Test
    func resourceKeepsSessionAfterLastTerminal() throws {
        let store = HostResourceSessionStore()
        let id = UUID()
        store.update([pane(session: id)])
        store.retainResources(in: [id])
        store.update([])
        #expect(try store.resolve(id).name == "work")
        #expect(LocalTmuxSession.groupWindows([], resources: store.sessions).first?.windows.isEmpty == true)
        store.retainResources(in: [])
        #expect(store.sessions.isEmpty)
    }

    @Test
    func reusedNameDoesNotAdoptOldResources() throws {
        let store = HostResourceSessionStore()
        let old = UUID(), current = UUID()
        store.update([pane(session: old)])
        store.retainResources(in: [old])
        store.update([pane(session: current)])
        #expect(try store.resolve(current).name == "work")
        #expect(try store.resolve(old).name != "work")
        #expect(store.sessions.count == 2)
    }

    @Test
    func restoredResourceSessionWithReusedNameRetainsItsOwnIdentity() throws {
        let store = HostResourceSessionStore(), old = UUID(), current = UUID()
        store.update([pane(session: current)])
        store.restore([.init(id: old, name: "work", directory: "/old")])
        let restored = try store.resolve(old)
        #expect(restored.id == old && restored.name != "work")
        let files = HostFileTabService()
        let saved = HostFileTab(sessionName: "work", initialDirectory: "/old", resourceSessionID: old)
        files.restoreIndependent([saved], sessions: store.sessions)
        #expect(files.tabs.first?.id == saved.id)
        #expect(files.tabs.first?.sessionName == restored.name)
        #expect(try store.resolve(current).name == "work")
    }

    @Test
    func asynchronousOpenReservesIdentityButCloseInvalidatesIt() throws {
        let store = HostResourceSessionStore()
        let id = UUID()
        store.update([pane(session: id)])
        _ = try store.reserve(id)
        store.update([])
        #expect(try store.resolve(id).id == id)
        store.remove(id)
        #expect(throws: FileBrowserError.self) { try store.resolve(id) }
        store.release(id)
        #expect(store.sessions.isEmpty)
    }

    @Test
    func everyManualOpenIsNewAndSurvivesSourceRemoval() throws {
        let service = HostFileTabService()
        let session = ResourceSession(id: UUID(), name: "work", directory: "/tmp")
        let first = try service.open(session: session)
        let second = try service.open(session: session)
        #expect(first.id != second.id)
        #expect(first.sourcePaneID == nil && first.windowID == nil)
        service.updateRoutes([])
        #expect(service.tabs.count == 2)
        let restored = HostFileTabService()
        restored.restoreIndependent(service.tabs, sessions: [session])
        #expect(restored.tabs == service.tabs)
        service.closeSession(session.id)
        #expect(service.tabs.isEmpty)
    }

    @Test
    func followingFileLinkDoesNotRebindIndependentFiles() {
        let descriptor = HostFileTab(sessionName: "work", isPrimary: false, initialDirectory: "/tmp", resourceSessionID: UUID())
        let tab = FileBrowserTab(hostTab: descriptor)
        tab.restoreSourcePane("%7")
        let tabs = SessionFileTabsState()
        tabs.directoryTabs[tab.id] = tab
        let order: [TabDragPayload] = [.window("@1"), .file(tab.id), .window("@2")]
        for paneID in ["%7", "%8"] {
            tab.openTerminalFile(.init(directory: "/host/output", file: "/host/output/report.md"), paneID: paneID)
            #expect(tab.sourcePaneID == nil)
            #expect(tab.hostTab == descriptor)
            #expect(tab.path == "/host/output")
            #expect(tab.selectedFile == "/host/output/report.md")
            #expect(tabs.groupedTabOrder(order, paneOrder: ["%7", "%8"]) == order)
        }
    }

    @Test
    func legacyWireCatalogExcludesIndependentResources() throws {
        struct Legacy: Decodable {
            struct File: Decodable { let windowID: String
                let sourcePaneID: String
            }

            let fileTabs: [File]
        }
        let session = ResourceSession(id: UUID(), name: "work", directory: "/tmp")
        let linked = HostFileTab(sessionName: "work", windowID: "@1", sourcePaneID: "%1", isPrimary: true, initialDirectory: "/tmp")
        let independent = HostFileTab(sessionName: "work", isPrimary: false, initialDirectory: "/tmp", resourceSessionID: session.id)
        let state = SessionStateMessage(pairId: "host", paneStates: [:], fileTabs: [linked], independentResources: .init(sessions: [session], files: [independent]))
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(Legacy.self, from: data).fileTabs.count == 1)
        let decoded = try JSONDecoder().decode(SessionStateMessage.self, from: data)
        #expect(decoded.fileTabs?.count == 2)
        #expect(decoded.withPairId("other").fileTabs?.count == 2)
        #expect(decoded.independentResources?.sessions == [session])
    }

    @Test
    func topLevelResourcesRetainMixedOrder() {
        let tabs = SessionFileTabsState()
        let file = HostFileTab(sessionName: "work", isPrimary: false, initialDirectory: "/tmp", resourceSessionID: UUID())
        tabs.directoryTabs[file.id] = .init(hostTab: file)
        let order: [TabDragPayload] = [.window("@1"), .file(file.id), .window("@2")]
        #expect(tabs.groupedTabOrder(order, paneOrder: ["%1"]) == order)
        #expect(tabs.canReorder(.file(file.id), before: .window("@1")))
    }

    @Test
    func restoringLinkedOrderKeepsTopLevelWindowsInPlace() {
        let tabs = SessionFileTabsState()
        let first = UUID(), delayed = UUID(), second = UUID()
        tabs.tabOrder = [.window("@1"), .file(first), .window("@2"), .browser(delayed), .file(second)]
        tabs.restoreLinkedTabOrder([.file(second), .browser(delayed), .file(first)])
        #expect(tabs.tabOrder == [.window("@1"), .file(second), .window("@2"), .browser(delayed), .file(first)])
        tabs.recordVisibleTabOrder([.window("@1"), .file(first), .window("@2"), .file(second)])
        #expect(tabs.tabOrder == [.window("@1"), .file(first), .window("@2"), .browser(delayed), .file(second)])
    }

    @Test
    func closedSessionCannotBeResurrectedByLateSnapshot() throws {
        let store = HostResourceSessionStore(), id = UUID()
        let live = pane(session: id)
        store.update([live])
        store.beginClosing(id)
        #expect(throws: FileBrowserError.self) { try store.reserve(id) }
        store.remove(id)
        store.update([live])
        #expect(store.sessions.isEmpty)
    }

    @Test
    func independentFileCanDetachWithoutAnyTerminalAndReturn() throws {
        let windows = DetachedTerminalWindows()
        let descriptor = HostFileTab(sessionName: "work", isPrimary: false, initialDirectory: "/tmp", resourceSessionID: UUID())
        let tabs = windows.mainTabs.tabs(hostID: "host", session: "work")
        tabs.openFileTabs = [.init(id: descriptor.id, path: "/tmp", directoryPath: "/", isDirectory: true)]
        tabs.directoryTabs[descriptor.id] = .init(hostTab: descriptor)
        tabs.tabOrder = [.file(descriptor.id)]
        let drag = WorkbenchTabDrag(workspaceID: nil, hostID: "host", sessionName: "work", tab: .file(descriptor.id))
        let workspace = try #require(windows.detach(drag, anchor: nil, position: nil, session: { _ in nil }))
        #expect(workspace.hostID == "host" && workspace.members.isEmpty && workspace.anchor == nil)
        #expect(workspace.tabs.remote.values.first?.directoryTabs[descriptor.id] != nil)
        #expect(windows.returnToMain(.init(workspaceID: workspace.id, hostID: "host", sessionName: "work", tab: .file(descriptor.id)), anchor: nil, session: { _ in nil }))
        #expect(tabs.directoryTabs[descriptor.id]?.hostTab == descriptor)
        #expect(windows.mainTabs.restoredSelection?.sessionName == "work")
    }

    @Test
    func resourceCatalogResolvesSessionWithoutInventingPane() throws {
        let resource = ResourceSession(id: UUID(), name: "work", directory: "/tmp")
        let state = SessionStateMessage(pairId: "host", paneStates: [:], workspaceIdentity: .init(hostID: UUID(), serverID: nil), independentResources: .init(sessions: [resource]))
        let catalog = try #require(ViewerWorkspaceCatalog(state: state))
        let reference = try #require(catalog.reference(sessionName: "work"))
        #expect(catalog.sessionName(for: reference) == "work")
        #expect(catalog.resolve(reference) == nil)
    }
}
