import AppKit
import SwiftUI

private struct SessionNavigation: Hashable {
    let sessionName: String
    let hostId: String
}

private enum PushNotificationService {
    struct DeepLinkInfo {
        let paneId: String
        let hostId: String
    }
}

/// Only the synchronized pane lookup is stubbed; navigation callbacks come from MainView.
private struct SessionStore {
    func paneState(for paneID: String, hostId: String) -> SessionNavigation? {
        SessionNavigation(sessionName: paneID, hostId: hostId)
    }
}

@MainActor
private struct NavigationProbe: View {
    @State private var sessionsNavigationPath = NavigationPath()
    @State private var currentlyDisplayedPaneId: String?
    @State private var dashboardDestination: SessionNavigation?
    @State private var showingSettings = false
    private let sessionStore = SessionStore()

    var body: some View {
        NavigationStack(path: $sessionsNavigationPath) {
            Text("Sessions")
                .navigationDestination(for: SessionNavigation.self) { destination in
                    Text(destination.sessionName)
                }
        }
        // swiftformat:disable:next unusedArguments
        .onChange(of: sessionsNavigationPath.count) { _, count in
            /* PATH_OBSERVER */
        }
        .task { await runRegression() }
    }

    private func dismissDashboard() {
        /* DASHBOARD_DISMISS */
    }

    /* DEEP_LINK */

    private func runRegression() async {
        let a = SessionNavigation(sessionName: "A", hostId: "host")
        let b = SessionNavigation(sessionName: "B", hostId: "host")
        handleDeepLink(.init(paneId: "A", hostId: "host"))
        await settle()
        require(sessionsNavigationPath == NavigationPath([a]), "notification did not open A")
        require(currentlyDisplayedPaneId == "A", "notification A did not establish its marker")

        // Closing Dashboard without choosing a session preserves valid deduplication.
        dismissDashboard()
        await settle()
        require(currentlyDisplayedPaneId == "A", "dismissal cleared the active A marker")
        require(sessionsNavigationPath == NavigationPath([a]), "dismissal changed the route")

        dashboardDestination = b
        dismissDashboard()
        await settle()
        require(sessionsNavigationPath == NavigationPath([b]), "Dashboard did not replace A with B")
        require(dashboardDestination == nil, "Dashboard destination was not consumed")
        require(currentlyDisplayedPaneId == nil, "A's notification marker survived the same-depth switch to B")

        handleDeepLink(.init(paneId: "A", hostId: "host"))
        await settle()
        require(sessionsNavigationPath == NavigationPath([a]), "A notification was suppressed while displaying B")
        require(currentlyDisplayedPaneId == "A", "A notification did not restore its marker")
        handleDeepLink(.init(paneId: "A", hostId: "host"))
        await settle()
        require(sessionsNavigationPath == NavigationPath([a]), "repeated A notification stacked destinations")

        sessionsNavigationPath = NavigationPath()
        await settle()
        require(currentlyDisplayedPaneId == nil, "returning to the list retained the marker")
        print("PASS: notification A, Dashboard B, notification A")
        NSApp.terminate(nil)
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func require(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAIL: \(message)")
            exit(1)
        }
    }
}

@MainActor
private final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_: Notification) {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: NavigationProbe())
        self.window = window
        // Offscreen: no activation, global input or access to a running CtrlX instance.
        window.contentView?.layoutSubtreeIfNeeded()
    }
}

@main
private struct DashboardNavigationProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = ProbeDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
