import CtrlxCommon
import CtrlxNetworking
import Foundation

/// Only inputs that change menu items or their targets. Terminal output, usage,
/// timestamps and browser loading updates must not rebuild an open menu.
struct WindowTabMenuState: Equatable, Sendable {
    struct Pane: Equatable, Sendable {
        let id: String
        let index: Int
        let isActive: Bool
        let pluginID: String?
        let agentName: String?
        let conversationID: String?
        let runtimeID: String?
        let source: AgentForkSource?
        let workspaceIdentity: WorkspacePaneIdentity?

        init(_ pane: PaneState) {
            self.id = pane.paneId
            self.index = pane.paneIndex
            self.isActive = pane.isActive
            self.pluginID = pane.agentSession?.pluginID
            self.agentName = pane.agentSession?.displayName
            self.conversationID = pane.claudeSessionID
            self.runtimeID = pane.agentSession?.processRuntimeID
            self.source = AgentForkSource(pane: pane)
            self.workspaceIdentity = pane.workspaceIdentity
        }
    }

    struct Resource: Equatable, Sendable {
        let id: UUID
        let title: String
        let sourcePaneID: String?
        var isPrimary = false
    }

    let hostID: String
    let windowID: String?
    let focusedPaneID: String?
    let panes: [Pane]
    let files: [Resource]
    let browsers: [Resource]
    let simulators: [Resource]
    var isConnected = false
    var canOpenFiles = false
    var canOpenBrowser = false
    var canOpenSimulator = false
    var canCreateSimulator = false
    var canCreateNewSimulator = false
    var canCreateIndependentResources = false
    var isCreatingWindow = false
    var forkUnavailableReason: String?
    var canForkOtherDirectory = false
    var includesWindowManagement = false
    var includesFork = true
    var restartUnavailableReason: String?
    var logoutUnavailableReason: String?
    var restartingAgentPaneIDs: Set<String> = []
    var showsHookTrust = false
    var canTrustHooks = false
    var showsWorkflow = false
    var canCopy = false
    var sendsMouseEvents = false
    var hasActiveSession = false
    var isYoloModeEnabled = false

    @MainActor
    init(hostID: String, window: TmuxWindow?, focusedPaneID: String?, files: [FileBrowserTab], browsers: [RemoteBrowserTab], simulators: [RemoteSimulatorTab]) {
        self.hostID = hostID
        self.windowID = window?.stableId
        self.focusedPaneID = focusedPaneID
        self.panes = (window?.panes ?? []).map(Pane.init)
        let paneIDs = Set(panes.map(\.id))
        func includes(_ source: String?) -> Bool {
            window == nil ? source == nil : source.map(paneIDs.contains) == true
        }
        self.files = files.filter { includes($0.sourcePaneID) }.map { .init(id: $0.id, title: $0.title, sourcePaneID: $0.sourcePaneID) }
        self.browsers = browsers.filter { includes($0.sourcePaneID) }.map { .init(id: $0.id, title: $0.title, sourcePaneID: $0.sourcePaneID) }
        self.simulators = simulators.filter { includes($0.sourcePaneID) }.map { .init(id: $0.id, title: $0.title, sourcePaneID: $0.sourcePaneID, isPrimary: $0.isPrimary) }
    }
}
