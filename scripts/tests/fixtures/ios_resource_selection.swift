import AppKit
import SwiftUI

// The fixture substitutes transport and presentation around production routing.
struct ResourceTabRequest: Equatable { let id = UUID() }
enum ResourceTabKind: Equatable { case files, browser, simulator }
enum WindowTabAction { case newResource(ResourceTabKind) }
struct WorkspacePaneIdentity: Equatable {
    let id = UUID()
    func isSamePane(as other: Self?) -> Bool {
        self == other
    }
}

enum PaneLinkedTabID: Hashable { case file(UUID), browser(UUID), simulator(UUID) }
/// PRODUCTION_DECLARATIONS
struct ViewerWorkspaceInputBinding {
    func binding(paneID _: String) -> Self {
        self
    }
}

struct HostFileTab: Equatable { let id: UUID
    var resourceSessionID: UUID?
}

struct ResourceResult { var file: HostFileTab?
    var browser: HostFileTab?
    var simulator: HostFileTab?
}

enum FileBrowserError: Error { case message(String) }
struct Pane {
    let paneId: String
    let workspaceIdentity: WorkspacePaneIdentity? = .init()
}

struct TmuxWindow {
    let id: String
    var panes: [Pane] = []
    var activePane: Pane? {
        panes.first
    }

    var stableId: String {
        id
    }
}

struct ConnectionManager { func connection(for _: String) {} }

struct RepositoryFileContext: Equatable {
    init?(pane _: Pane) {}
}

enum FileBrowserSource { case remote(hostID: String, paneID: String, connection: Void) }

struct TerminalFileDestination {
    let file: String?
    static func resolve(path: String, context _: RepositoryFileContext?, source _: FileBrowserSource) async throws -> Self {
        .init(file: path)
    }
}

struct TerminalArtifactPreview {
    init(link _: TerminalFileLinkRequest, context _: RepositoryFileContext, source _: FileBrowserSource, path _: String) {}
    static func supports(path _: String?) -> Bool {
        false
    }
}

struct PreviewKeyboardRestore {
    func captureIfNeeded(paneID _: String, keyboardIsActive _: Bool) {}
    func discard() {}
}

struct QuickActionPresentation { func dismiss() {} }

struct LinkedTabs {
    let windows: [TmuxWindow]
    func sourcePaneID(_: PaneLinkedTabID) -> String? {
        nil
    }

    func sourceWindow(for _: PaneLinkedTabID) -> TmuxWindow? {
        nil
    }
    // PRODUCTION_RETURN_TARGET
}

@MainActor @Observable
final class Selection { var selectedID: UUID? }
@MainActor @Observable
final class FileBrowserTab {
    private(set) var hostTab: HostFileTab?
    var id: UUID {
        hostTab!.id
    }

    var lastSelectedAt = Date()
    var openedFile: String?
    init(hostTab tab: HostFileTab) {
        hostTab = tab
    }

    func updateHostTab(_ tab: HostFileTab) {
        hostTab = tab
    }

    func releaseResources() {}
    func openTerminalFile(_ destination: TerminalFileDestination, paneID _: String) {
        openedFile = destination.file
    }
}

@MainActor @Observable
final class Workspace {
    var selectedID: UUID?
    var tabs: [FileBrowserTab] = []
    func save() {}
    // PRODUCTION_WORKSPACE
}

@MainActor @Observable
final class FixtureState {
    var pending: ResourceOpenRequest?
    var window: TmuxWindow? = .init(id: "@1")
    var pane: String? = "%1"
    var error: String?
    var fileLink: TerminalFileLinkRequest?
    var filesRequest: String?
    var browserLink: String?
    var simulatorRequest: String?
    let files: Workspace
    let browser = Selection()
    let simulator = Selection()
    var hostSupportsIndependentResources = false
    let workspaceInputState = ViewerWorkspaceInputBinding()
    var artifactPreview: TerminalArtifactPreview?
    var artifactPreviewIsPresented = false
    var isKeyboardActive = false
    var continuations: [UUID: CheckedContinuation<ResourceResult, any Error>] = [:]
    init(files: Workspace = Workspace()) {
        self.files = files
    }

    var selection: (String?, String?, UUID?, UUID?, UUID?) {
        (window?.id, pane, files.selectedID, browser.selectedID, simulator.selectedID)
    }
}

enum ResourceTabClient {
    @MainActor
    static func request(_ request: ResourceTabRequest, client: FixtureState) async throws -> ResourceResult {
        // Deliberately ignore cancellation: a Host may finish after the Viewer switches tabs.
        try await withCheckedThrowingContinuation { client.continuations[request.id] = $0 }
    }
}

enum HostFileTabClient {
    @MainActor static let existing = HostFileTab(id: UUID())
    @MainActor
    static func open(
        connection _: Void,
        sessionName _: String,
        paneID _: String,
        new: Bool = false,
        inputBinding _: ViewerWorkspaceInputBinding
    ) async throws -> HostFileTab {
        new ? HostFileTab(id: UUID()) : existing
    }
}

struct FixtureView: View {
    let state: FixtureState
    var relayClient: FixtureState {
        state
    }

    var fileWorkspace: Workspace {
        state.files
    }

    var browserSelection: Selection {
        state.browser
    }

    var simulatorSelection: Selection {
        state.simulator
    }

    var window: TmuxWindow? {
        state.window
    }

    var activePaneId: String? {
        state.pane
    }

    var pendingResourceRequest: ResourceOpenRequest? {
        get { state.pending } nonmutating set { state.pending = newValue }
    }

    var pendingFileLink: TerminalFileLinkRequest? {
        get { state.fileLink } nonmutating set { state.fileLink = newValue }
    }

    var pendingFilesRequest: String? {
        get { state.filesRequest } nonmutating set { state.filesRequest = newValue }
    }

    var pendingBrowserLink: String? {
        get { state.browserLink } nonmutating set { state.browserLink = newValue }
    }

    var pendingSimulatorRequest: String? {
        get { state.simulatorRequest } nonmutating set { state.simulatorRequest = newValue }
    }

    var commandError: String? {
        get { state.error } nonmutating set { state.error = newValue }
    }

    let connectionManager = ConnectionManager()
    let hostId = "host"
    let sessionName = "work"
    let newWindowDirectory = "/work"
    let quickActionPresentation = QuickActionPresentation()
    let previewKeyboardRestore = PreviewKeyboardRestore()

    var artifactPreview: TerminalArtifactPreview? {
        get { state.artifactPreview } nonmutating set { state.artifactPreview = newValue }
    }

    var artifactPreviewIsPresented: Bool {
        get { state.artifactPreviewIsPresented } nonmutating set { state.artifactPreviewIsPresented = newValue }
    }

    var isKeyboardActive: Bool {
        get { state.isKeyboardActive } nonmutating set { state.isKeyboardActive = newValue }
    }

    var terminalIsVisible: Bool {
        fileWorkspace.selectedID == nil && browserSelection.selectedID == nil && simulatorSelection.selectedID == nil
    }

    var selectedLinkedTab: PaneLinkedTabID? {
        fileWorkspace.selectedID.map(PaneLinkedTabID.file)
    }

    var linkedTabs: LinkedTabs {
        .init(windows: window.map { [$0] } ?? [])
    }

    func actionPaneID(in window: TmuxWindow, preferredPaneID: String?) -> String? {
        preferredPaneID ?? activePaneId ?? window.activePane?.paneId
    }

    func selectTerminalWindow(_ target: TmuxWindow, preferredPaneID: String?) {
        state.window = target
        state.pane = preferredPaneID
        fileWorkspace.selectedID = nil
        browserSelection.selectedID = nil
        simulatorSelection.selectedID = nil
    }

    func restorePreviewKeyboard() {}
    func cancelCreationFollowUp() {}
    func resourceRequest(_: ResourceTabKind, location _: String? = nil) throws -> ResourceTabRequest {
        .init()
    }

    // swiftformat:disable:next unusedArguments
    func performWindowTabAction(_ action: WindowTabAction, preferredPaneID _: String? = nil, returnPane: WorkspacePaneIdentity? = nil) {
        switch action {
            // PRODUCTION_NEW_RESOURCE
        }
    }

    var body: some View {
        Text("Resource selection fixture")
        // PRODUCTION_MODIFIERS
    }
    // PRODUCTION_METHODS
    // PRODUCTION_SHORTCUT
}

@MainActor
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw FileBrowserError.message(message)
    }
}

@MainActor
func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0 ..< 150 {
        if condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw FileBrowserError.message("Timed out: \(message)")
}

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        let state = FixtureState()
        let view = FixtureView(state: state)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: .init(x: -10000, y: -10000, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(200))
                for selection in 0 ..< 5 {
                    let request = ResourceTabRequest()
                    state.pending = .init(request: request, returnPane: .init())
                    try await waitUntil("request started") { state.continuations[request.id] != nil }
                    switch selection {
                    case 0: state.window = .init(id: "@2")
                    case 1: state.pane = "%2"
                    case 2: state.files.selectedID = UUID()
                    case 3: state.browser.selectedID = UUID()
                    default: state.simulator.selectedID = UUID()
                    }
                    let expected = state.selection
                    try await waitUntil("selection cancels pending open") { state.pending == nil }
                    state.continuations.removeValue(forKey: request.id)?.resume(returning: .init(simulator: .init(id: UUID())))
                    try await Task.sleep(for: .milliseconds(120))
                    try require(state.selection == expected, "Late result stole selection \(selection)")
                    try require(state.error == nil, "Cancelled open reported an error")
                    try require(state.files.resourceReturnPanes.isEmpty, "Late result recorded a return pane")
                }
                print("PASS: 5 selection changes ignore late resource results")
                let first = Pane(paneId: "%1"), second = Pane(paneId: "%2")
                let split = TmuxWindow(id: "@1", panes: [first, second])
                view.selectTerminalWindow(split, preferredPaneID: first.paneId)
                try await Task.sleep(for: .milliseconds(100))

                let newTab = HostFileTab(id: UUID())
                view.chooseShortcut(.newResource(.simulator), scope: .terminal)
                guard let request = state.pending?.request else { throw FileBrowserError.message("Terminal shortcut did not start an open") }
                try await waitUntil("unchanged request started") { state.continuations[request.id] != nil }
                state.continuations.removeValue(forKey: request.id)?.resume(returning: .init(simulator: newTab))
                try await waitUntil("new tab selected") { state.simulator.selectedID == newTab.id }
                try require(
                    state.pending == nil && state.files.selectedID == nil && state.browser.selectedID == nil,
                    "Successful open left another resource selected"
                )
                print("PASS: unchanged selection opens the resource")
                try require(state.files.resourceReturnPanes[.simulator(newTab.id)] == first.workspaceIdentity, "Terminal shortcut lost its return pane")
                view.selectTerminalWindow(split, preferredPaneID: first.paneId)
                try await Task.sleep(for: .milliseconds(100))
                let browser = HostFileTab(id: UUID())
                view.performWindowTabAction(.newResource(.browser))
                guard let fromTabs = state.pending?.request else { throw FileBrowserError.message("Tabs did not start an open") }
                try await waitUntil("Tabs request started") { state.continuations[fromTabs.id] != nil }
                state.continuations.removeValue(forKey: fromTabs.id)?.resume(returning: .init(browser: browser))
                try await waitUntil("Tabs resource selected") { state.browser.selectedID == browser.id }
                try require(state.files.resourceReturnPanes[.browser(browser.id)] == nil, "Tabs creation inherited a return pane")
                print("PASS: terminal shortcut retains its return pane; Tabs creation has no return pane")
                let reused = try await view.fileTabForTerminalLink(paneID: "%1", inputBinding: .init())
                let created = try await view.fileTabForTerminalLink(paneID: "%1", new: true, inputBinding: .init())
                try require(reused == HostFileTabClient.existing && created.id != reused.id, "Legacy new Files reused existing tab")
                print("PASS: legacy Host receives explicit new Files intent")

                state.hostSupportsIndependentResources = true
                let sharedFile = HostFileTab(id: UUID(), resourceSessionID: UUID())
                let fileTab = state.files.adopt(sharedFile)
                for pane in [first, second] {
                    view.selectTerminalWindow(split, preferredPaneID: pane.paneId)
                    try await Task.sleep(for: .milliseconds(100))
                    let link = TerminalFileLinkRequest(path: "/work/\(pane.paneId).txt", paneID: pane.paneId, hostID: view.hostId)
                    state.fileLink = link
                    await view.openTerminalFile(link)
                    try require(state.files.selectedID == fileTab.id && fileTab.openedFile == link.path, "Terminal link did not reuse Files")
                    try require(view.resourceReturnTarget(.file(fileTab.id))?.paneID == pane.paneId, "Files did not record the opening pane")
                }

                // A catalog can omit a tab and then publish the same UUID again.
                state.files.syncHostTabs([])
                try await Task.sleep(for: .milliseconds(100))
                state.files.syncHostTabs([sharedFile])
                state.files.selectedID = fileTab.id
                try require(view.resourceReturnTarget(.file(fileTab.id))?.paneID == second.paneId, "Catalog gap cleared the second pane")

                // Re-entering resets view selection while keeping the session workspace.
                let reentered = FixtureState(files: state.files)
                let reopened = FixtureView(state: reentered)
                window.contentView = NSHostingView(rootView: reopened)
                reopened.selectTerminalWindow(split, preferredPaneID: first.paneId)
                reentered.files.selectedID = fileTab.id
                reopened.returnToLinkedTabSource(.file(fileTab.id))
                try require(reentered.pane == second.paneId && reentered.files.selectedID == nil, "Return did not select the second pane")
                try require(reentered.files.tabs.contains { $0.id == fileTab.id }, "Return closed Files")
                print("PASS: reused Files returns to the second pane after a catalog gap and session re-entry")
                reentered.files.close(fileTab.id)
                try require(reentered.files.resourceReturnPanes[.file(fileTab.id)] == nil, "Confirmed close kept a return pane")

                window.close()
                NSApplication.shared.terminate(nil)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
    }
}

@main
struct ResourceSelectionProbe {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = FixtureDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
