import AppKit
import Observation
import SwiftUI

enum State: Equatable {
    case working, idle, awaitingPermission, awaitingReplies, awaitingPlanApproval
    case doneWorking(summary: String?)
}

struct Session { var state: State }

@MainActor @Observable final class Store {
    var value = Session(state: .working)
    var acknowledgements = 0
    func markSessionHandled(paneId _: String, hostId _: String) {
        if case .doneWorking = value.state {
            value.state = .idle
            acknowledgements += 1
        }
    }
}

struct InputBinding {
    var generation = 0
    func expectedPane(current: Self) throws {
        guard generation == current.generation else { throw failure("Retired pane") }
    }
}

struct MarkHandled {}

@MainActor final class Client {
    var workspaceInputState = InputState()
    var commands = 0
    struct InputState {
        var current = InputBinding()
        func binding(paneID _: String) -> InputBinding {
            current
        }
    }

    func sendCommand(_: MarkHandled, paneId _: String, inputBinding _: InputBinding) async {
        commands += 1
    }
}

/// Only store/transport dependencies are inert. The acknowledgement method is production code.
@MainActor final class Service {
    let sessionStore = Store()
    let relayClient = Client()
    let inputBinding = InputBinding()
    let paneId = "%fixture"
    let hostId = "fixture-host"
    var session: Session? {
        sessionStore.value
    }
    // PRODUCTION_SERVICE_METHOD
}

@MainActor @Observable final class Presentation {
    var pageVisible = true
    var terminalVisible = true
    var phase = ScenePhase.active
    var request: (() -> Void)?
}

struct ProbeView: View {
    let presentation: Presentation
    let activeService: Service?
    @State private var isKeyboardActive = false
    private var isViewVisible: Bool {
        presentation.pageVisible
    }

    private var terminalIsVisible: Bool {
        presentation.terminalVisible
    }

    private var scenePhase: ScenePhase {
        presentation.phase
    }

    private var activeSessionHasBlockingForm: Bool {
        false
    }

    // PRODUCTION_VISIBILITY

    var body: some View {
        Text(terminalIsVisible ? "Terminal" : "Resource")
            // PRODUCTION_STATE_CALLBACK
            // PRODUCTION_VISIBILITY_CALLBACK
            .task {
                presentation.request = { markVisibleTerminalHandled() }
                markVisibleTerminalHandled()
            }
    }

    // PRODUCTION_ACKNOWLEDGEMENT
}

@main struct CompletionAttentionFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                for page in [false, true] {
                    for terminal in [false, true] {
                        for active in [false, true] {
                            try await check(page: page, terminal: terminal, active: active)
                        }
                    }
                }
                print("PASS: visibility, delayed callbacks, read-on-return and completion-only acknowledgement")
                exit(0)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        app.run()
    }

    @MainActor private static func check(page: Bool, terminal: Bool, active: Bool) async throws {
        let presentation = Presentation()
        presentation.pageVisible = page
        presentation.terminalVisible = terminal
        presentation.phase = active ? .active : .background
        let service = Service()
        let host = NSHostingView(rootView: ProbeView(presentation: presentation, activeService: service))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await settle(host)
        service.sessionStore.value.state = .doneWorking(summary: "Finished")
        try await settle(host)
        let visible = page && terminal && active
        try require(service.sessionStore.acknowledgements == (visible ? 1 : 0), "Hidden/inactive completion was acknowledged")
        try require(service.relayClient.commands == (visible ? 1 : 0), "Hidden/inactive acknowledgement reached transport")
        presentation.pageVisible = true
        presentation.terminalVisible = true
        presentation.phase = .active
        try await settle(host)
        try require(service.sessionStore.value.state == .idle && service.relayClient.commands == 1, "Read-on-return failed or duplicated")
        for state in [State.working, .idle, .awaitingPermission, .awaitingReplies, .awaitingPlanApproval] {
            service.sessionStore.value.state = state
            presentation.request?()
            try await settle(host)
            try require(service.sessionStore.value.state == state && service.relayClient.commands == 1, "Non-completion was acknowledged")
        }
        service.sessionStore.value.state = .doneWorking(summary: "Viewed now")
        presentation.request?()
        try require(service.sessionStore.value.state == .idle, "Local acknowledgement was deferred")
        presentation.pageVisible = false
        try await settle(host)
        try require(service.relayClient.commands == 2, "Accepted acknowledgement did not finish after leaving")
        presentation.pageVisible = true
        // A delayed view callback must recheck eligibility before acknowledging.
        service.sessionStore.value.state = .doneWorking(summary: "Delayed")
        Task { @MainActor in presentation.request?() }
        presentation.pageVisible = false
        try await settle(host)
        try require(service.relayClient.commands == 2, "Late callback acknowledged a departed page")
        presentation.pageVisible = true
        service.relayClient.workspaceInputState.current.generation += 1
        presentation.request?()
        try await settle(host)
        try require(service.relayClient.commands == 2, "A retired binding acknowledged its replacement")
    }

    @MainActor private static func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
    }
}

private func failure(_ message: String) -> NSError {
    .init(domain: "CompletionAttentionUI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw failure(message)
    }
}
