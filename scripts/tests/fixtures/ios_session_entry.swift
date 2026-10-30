import Foundation

enum TerminalWindowSwipePolicy { enum Direction { case next, previous } }
struct InputState { func sessionBinding(name _: String) -> Int {
    0
} }
struct Relay { let workspaceInputState = InputState(); let isHostConnected = true }
struct Store { let paneStates: [String: Int] = [:] }
struct Fit { mutating func cancel(hostID _: String, sessionName _: String) {} }
struct Destination { let initialFit: Fit? }
struct Creation {
    let paneID: String? = nil
    func validateSessionBinding(_: Int) -> Bool {
        true
    }

    func takeWindowDestination(selectedPaneID _: String?, paneStates _: [String: Int], isConnected _: Bool) -> Destination? {
        nil
    }
}

@MainActor final class Workspace {
    var hasPendingTerminalSelection = false
    var isResourceOnlySession = false
    var topLevelTabOrder: [String] = []
    var restoredWindowID: String?
    var restoredPaneID: String?
    var selectedID: String?
}

@MainActor final class EntryStore {
    var preparations = 0
    func prepareForEntry(_ workspace: Workspace, restoresSelection: Bool) {
        preparations += 1
        if !restoresSelection {
            workspace.selectedID = nil
        }
    }
}

struct LinkedTabs {
    var items = ["files", "browser"]
    func topLevel(stored _: [String]) -> [String] {
        items
    }
}

@MainActor final class Probe {
    let hostId = "host", sessionName = "work"
    let relayClient = Relay(), sessionStore = Store(), windowCreation = Creation()
    let fileWorkspace = Workspace(), fileWorkspaces = EntryStore()
    var linkedTabs = LinkedTabs()
    var selectedWindowId: String?, activePaneId: String?
    var initialSessionFit: Fit?
    var didPrepareEntrySelection = false
    var restoresSelection = false
    var selectedLinkedTab: String? {
        fileWorkspace.selectedID
    }

    func selectTopLevel(_ tab: String) {
        fileWorkspace.selectedID = tab
    }

    func fitCreatedTerminalIfReady() {}
    // PRODUCTION_METHOD
}

@main struct Run {
    @MainActor static func main() {
        let terminal = WindowSelectionCandidate(windowId: "work:0", paneId: "%1", isActive: true)
        let normal = Probe()
        normal.fileWorkspace.selectedID = "files"
        normal.reconcileWindowSelection(candidates: [terminal])
        precondition(normal.selectedWindowId == "work:0" && normal.selectedLinkedTab == nil)

        let late = Probe()
        late.reconcileWindowSelection(candidates: [])
        precondition(late.selectedLinkedTab == nil)
        late.reconcileWindowSelection(candidates: [terminal])
        precondition(late.selectedWindowId == "work:0" && late.selectedLinkedTab == nil)

        let restored = Probe()
        restored.restoresSelection = true
        restored.fileWorkspace.selectedID = "files"
        restored.reconcileWindowSelection(candidates: [terminal])
        precondition(restored.selectedLinkedTab == "files")

        normal.fileWorkspace.selectedID = "browser"
        normal.reconcileWindowSelection(candidates: [terminal])
        precondition(normal.selectedLinkedTab == "browser" && normal.fileWorkspaces.preparations == 1)

        let resources = Probe()
        resources.reconcileWindowSelection(candidates: [])
        resources.fileWorkspace.isResourceOnlySession = true
        resources.reconcileWindowSelection(candidates: [])
        precondition(resources.selectedLinkedTab == "files")

        let lateResources = Probe()
        lateResources.fileWorkspace.isResourceOnlySession = true
        lateResources.linkedTabs.items = []
        lateResources.reconcileWindowSelection(candidates: [])
        precondition(lateResources.selectedLinkedTab == nil)
        lateResources.linkedTabs.items = ["files", "browser"]
        lateResources.reconcileWindowSelection(candidates: [])
        precondition(lateResources.selectedLinkedTab == "files")

        let closedTerminal = Probe()
        closedTerminal.fileWorkspace.isResourceOnlySession = true
        closedTerminal.fileWorkspace.hasPendingTerminalSelection = true
        closedTerminal.fileWorkspace.selectedID = "files"
        closedTerminal.reconcileWindowSelection(candidates: [])
        precondition(closedTerminal.selectedLinkedTab == "files")

        let pendingTerminal = Probe()
        pendingTerminal.fileWorkspace.hasPendingTerminalSelection = true
        pendingTerminal.reconcileWindowSelection(candidates: [])
        precondition(pendingTerminal.selectedLinkedTab == nil)
        print("PASS: eight entry selection scenarios")
    }
}
