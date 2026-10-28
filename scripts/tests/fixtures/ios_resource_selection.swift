import AppKit
import SwiftUI

// Only transport and unrelated UI state are stubbed. The task, selection
// callbacks and Files routing method are extracted from WindowLayoutView.
struct ResourceTabRequest: Equatable { let id = UUID() }
enum ResourceTabKind { case files }
struct ViewerWorkspaceInputBinding { }
struct HostFileTab: Equatable { let id: UUID
    var resourceSessionID: UUID?
}

struct ResourceResult { var file: HostFileTab?
    var browser: HostFileTab?
    var simulator: HostFileTab?
}

enum FileBrowserError: Error { case message(String) }
struct Window { let id: String
    var stableId: String {
        id
    }
}

struct ConnectionManager { func connection(for _: String) { } }

@MainActor @Observable
final class Selection { var selectedID: UUID? }
@MainActor @Observable
final class FileTab {
    let hostTab: HostFileTab?
    var id: UUID {
        hostTab!.id
    }

    var lastSelectedAt = Date()
    init(_ tab: HostFileTab) {
        self.hostTab = tab
    }
}

@MainActor @Observable
final class Workspace {
    var selectedID: UUID?
    var tabs: [FileTab] = []
    func adopt(_ tab: HostFileTab) -> FileTab {
        let file = FileTab(tab)
        tabs.append(file)
        return file
    }
}

@MainActor @Observable
final class FixtureState {
    var pending: ResourceTabRequest?
    var window: Window? = .init(id: "@1")
    var pane: String? = "%1"
    var error: String?
    var fileLink: String?
    var filesRequest: String?
    var browserLink: String?
    var simulatorRequest: String?
    let files = Workspace()
    let browser = Selection()
    let simulator = Selection()
    let hostSupportsIndependentResources = false
    var continuations: [UUID: CheckedContinuation<ResourceResult, any Error>] = [:]
    var selection: String {
        "\(window?.id ?? "nil")|\(pane ?? "nil")|\(files.selectedID)|\(browser.selectedID)|\(simulator.selectedID)"
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

    var window: Window? {
        state.window
    }

    var activePaneId: String? {
        state.pane
    }

    var pendingResourceRequest: ResourceTabRequest? {
        get { state.pending } nonmutating set { state.pending = newValue }
    }

    var pendingFileLink: String? {
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
    func resourceRequest(_: ResourceTabKind) throws -> ResourceTabRequest {
        .init()
    }

    var body: some View {
        Text("Resource selection fixture")
        // PRODUCTION_MODIFIERS
    }
    // PRODUCTION_METHOD
}

@MainActor
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw FileBrowserError.message(message)
    }
}

@MainActor
func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<150 {
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
            contentRect: .init(x: -10_000, y: -10_000, width: 400, height: 200),
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
                for selection in 0..<5 {
                    let request = ResourceTabRequest()
                    state.pending = request
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
                }
                print("PASS: 5 selection changes ignore late resource results")
                let request = ResourceTabRequest()
                let newTab = HostFileTab(id: UUID())
                state.pending = request
                try await waitUntil("unchanged request started") { state.continuations[request.id] != nil }
                state.continuations.removeValue(forKey: request.id)?.resume(returning: .init(simulator: newTab))
                try await waitUntil("new tab selected") { state.simulator.selectedID == newTab.id }
                try require(
                    state.pending == nil && state.files.selectedID == nil && state.browser.selectedID == nil,
                    "Successful open left another resource selected"
                )
                print("PASS: unchanged selection opens the resource")
                let reused = try await view.fileTabForTerminalLink(paneID: "%1", inputBinding: .init())
                let created = try await view.fileTabForTerminalLink(paneID: "%1", new: true, inputBinding: .init())
                try require(reused == HostFileTabClient.existing && created.id != reused.id, "Legacy new Files reused existing tab")
                print("PASS: legacy Host receives explicit new Files intent")
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
        withExtendedLifetime(delegate) { }
    }
}
