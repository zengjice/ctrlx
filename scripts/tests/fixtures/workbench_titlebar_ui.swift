import AppKit
import SwiftUI

/// The data transport and asset bundle are inert. Account grouping, quota rules,
/// views, native toolbar layout and event handling are the production implementations.
extension Bundle {
    static var module: Bundle {
        ProcessInfo.processInfo.environment["CTRLX_TITLEBAR_ASSETS"].flatMap(Bundle.init(path:)) ?? .main
    }
}

enum Symbols {
    case gaugeWithDotsNeedle50percent
    var image: Image {
        Image(systemName: "gauge.with.dots.needle.50percent")
    }
}

@MainActor @Observable
final class DashboardStore {
    var isRefreshing = false
    var hosts: [DashboardHost] = {
        let now = Date()
        let accounts = (0 ..< 6).map { index -> DashboardAccount in
            let plugin = index % 2 == 0 ? "codex" : "claude-code"
            let name = index % 2 == 0 ? "Codex" : "Claude Code"
            let identity = DashboardAccountIdentity(providerID: "fixture", accountID: String(index), workspaceID: "personal", poolID: "quota")
            let quota = DashboardQuotaWindow(id: "weekly", title: "7 days", usedPercent: Double(index * 20), resetsAt: now.addingTimeInterval(3600))
            return DashboardAccount(id: "account-\(index)", pluginID: plugin, providerName: name, label: "Account \(index)", configurationLabel: "Default",
                                    identity: identity, authentication: .signedIn, availability: .available, quotaObservedAt: now, windows: [quota])
        }
        return [.init(id: "local", name: "This Mac", isConnected: true, isSupported: true,
                      snapshot: .init(hostID: UUID(), generatedAt: now, timeZoneIdentifier: "UTC", accounts: accounts),
                      requestedAt: now, receivedAt: now)]
    }()
}

@MainActor @Observable
final class TitlebarFixtureState {
    var title = "cm"
    var buttonClicks = 0
    let dashboard = DashboardStore()
}

struct TitlebarAnchor: NSViewRepresentable {
    let id: String
    func makeNSView(context _: Context) -> NSView {
        let view = Passthrough()
        view.identifier = .init(id)
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        view.identifier = .init(id)
    }

    final class Passthrough: NSView {
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }
    }
}

struct TitlebarFixture: View {
    @State private var state = TitlebarFixtureState()
    private let detached = ProcessInfo.processInfo.environment["CTRLX_TITLEBAR_FIXTURE_DETACHED"] == "1"

    var body: some View {
        workspace
            .background(Color(nsColor: .windowBackgroundColor))
            .containerBackground(Color(nsColor: .windowBackgroundColor), for: .window)
            .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
            .preferredColorScheme(detached ? .dark : .light)
            .navigationTitle(state.title)
            .toolbar(removing: .title)
            .toolbar {
                if !detached {
                    ToolbarItem(placement: .navigation) {
                        Button("Search") { state.buttonClicks += 1 }
                    }
                }
                ToolbarItem(id: "quotas", placement: .automatic) {
                    DashboardQuotaToolbar(store: state.dashboard) { state.buttonClicks += 1 }
                }
                WorkbenchWindowTitle(title: state.title)
                ToolbarItem(placement: .automatic) {
                    Button("Disconnect") { state.buttonClicks += 1 }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Refresh") { state.buttonClicks += 1 }
                        .background(TitlebarAnchor(id: "refresh"))
                }
            }
            .frame(minWidth: 400, minHeight: 250)
            .task {
                do {
                    try await runChecks()
                    print("PASS: native titlebar double-click, controls, content, narrow window and live title")
                    NSApp.terminate(nil)
                } catch {
                    print("FAIL: \(error)")
                    exit(1)
                }
            }
    }

    @ViewBuilder private var workspace: some View {
        if detached {
            terminal
        } else {
            NavigationSplitView {
                Text("Sidebar").frame(maxWidth: .infinity, maxHeight: .infinity)
            } detail: {
                terminal
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private var terminal: some View {
        Text("Terminal content").frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor private func runChecks() async throws {
        try await settle()
        guard let window = NSApp.windows.first(where: { $0.title == state.title }),
              let root = window.contentView?.superview
        else {
            throw failure("fixture window not found")
        }
        let frame = NSRect(x: 100, y: 100, width: 1000, height: 600)
        try await reset(window, to: frame)
        try require(find("quota-account-0", in: root) != nil, "quota icons missing")
        try require(find("quota-overflow", in: root) != nil, "quota overflow missing")
        try capture(root, label: "toolbar")
        try await checkQuotaPopover(window, root: root)
        try await checkUnsupportedAccounts(window, root: root)
        // AppKit's left titlebar area is the oracle for the user's native double-click action.
        try await doubleClick(window, at: NSPoint(x: 90, y: 575))
        let expectedFrame = window.frame
        let expectedMinimized = window.isMiniaturized
        try await reset(window, to: frame)
        try await doubleClick(window, at: NSPoint(x: 600, y: 575))
        try require(window.frame == expectedFrame && window.isMiniaturized == expectedMinimized,
                    "center titlebar differs from native left area")
        let behavior = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        if behavior == "Minimize" {
            try require(expectedMinimized, "process preference did not select Minimize")
        } else if behavior == "None" {
            try require(expectedFrame == frame && !expectedMinimized, "process preference did not select None")
        } else {
            try require(expectedFrame != frame || expectedMinimized, "native control did not react to double-click")
        }
        try await reset(window, to: frame)
        guard let button = find("refresh", in: root) else { throw failure("toolbar button missing") }
        let buttonRect = button.convert(button.bounds, to: nil)
        try require(buttonRect.midX > 800, "trailing toolbar actions moved to the left")
        try await doubleClick(window, at: NSPoint(x: buttonRect.midX, y: buttonRect.midY))
        try require(state.buttonClicks > 0 && window.frame == frame && !window.isMiniaturized,
                    "toolbar button lost clicks or triggered window zoom")
        try await doubleClick(window, at: NSPoint(x: 600, y: 300))
        try require(window.frame == frame && !window.isMiniaturized, "content double-click triggered window zoom")

        state.title = String(repeating: "Long session name ", count: 10)
        try await settle()
        try require(window.title == state.title, "native window title did not follow session changes")
        for width: CGFloat in [600, 400] {
            let narrow = NSRect(x: 100, y: 100, width: width, height: 400)
            try await reset(window, to: narrow)
            try require(window.frame.width == width, "long title expanded the window")
            print("quota width=\(width), item=\(find("quota-account-0", in: root) != nil), overflow=\(find("quota-overflow", in: root) != nil)")
            if width == 600 {
                try require(find("quota-account-0", in: root) == nil, "narrow window did not collapse quota icons")
                try require(find("quota-overflow", in: root) != nil, "narrow quota entry missing")
            }
            // A 400-point split-view toolbar already overflows with the native title.
            // Check its bounds, and verify direct actions at 600 points (400 when detached).
            if !detached, width == 400 {
                continue
            }
            guard let narrowButton = find("refresh", in: root) else { throw failure("narrow toolbar button missing") }
            let narrowRect = narrowButton.convert(narrowButton.bounds, to: nil)
            try require(narrowRect.minX >= 0 && narrowRect.maxX <= width && narrowRect.width > 0,
                        "narrow toolbar button is outside the window")
            let oldClicks = state.buttonClicks
            try await doubleClick(window, at: NSPoint(x: narrowRect.midX, y: narrowRect.midY))
            try require(state.buttonClicks > oldClicks, "long title made trailing action inaccessible")
        }
        window.close()
    }

    @MainActor private func checkQuotaPopover(_ window: NSWindow, root: NSView) async throws {
        guard let icon = find("quota-account-0", in: root) else { throw failure("quota button missing") }
        try await click(icon, in: window)
        try require(popup("detail-Account 0") != nil, "click did not open account details")
        if let card = popup("detail-Account 0")?.window?.contentView {
            try capture(card, label: "account")
        }
        state.dashboard.hosts[0].snapshot?.accounts[0].label = "Updated account"
        try await settle()
        try require(popup("detail-Updated account") != nil, "account popover retained a stale snapshot")
        guard let next = find("quota-account-1", in: root) else { throw failure("second quota button missing") }
        try await click(next, in: window)
        try require(popup("detail-Account 1") != nil, "clicking another account did not switch details")
        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
        {
            NSApp.postEvent(escape, atStart: false)
        }
        try await settle()
        try require(popup("detail-Account 1") == nil, "Escape did not dismiss details")
        try await click(next, in: window)
        try require(popup("detail-Account 1") != nil, "account did not reopen after Escape")
        try await postClick(window, at: .init(x: 600, y: 300))
        try require(popup("detail-Account 1") == nil, "outside click did not dismiss details")
        guard let overflow = find("quota-overflow", in: root) else { throw failure("quota overflow missing") }
        try await click(overflow, in: window)
        guard let other = popup("list-account-4"), let popupWindow = other.window else { throw failure("overflow account list missing") }
        try await click(other, in: popupWindow)
        try require(popup("detail-Account 4") != nil, "overflow account did not open details")
        try await postClick(window, at: .init(x: 600, y: 300))
    }

    @MainActor private func checkUnsupportedAccounts(_ window: NSWindow, root: NSView) async throws {
        let saved = state.dashboard.hosts
        for index in 0 ..< 3 {
            state.dashboard.hosts[0].snapshot?.accounts[index].availability = .unsupported
            state.dashboard.hosts[0].snapshot?.accounts[index].windows = []
        }
        try await settle()
        for index in 0 ..< 3 {
            try require(find("quota-account-\(index)", in: root) == nil, "unsupported account retained its titlebar icon")
        }
        try require(find("quota-overflow", in: root) == nil, "unsupported accounts still count toward overflow")
        guard let supported = find("quota-account-3", in: root) else { throw failure("supported account disappeared") }
        try capture(root, label: "supported-quotas")
        try await click(supported, in: window)
        try require(popup("detail-Account 3") != nil, "supported account details missing")

        for index in 3 ..< 6 {
            state.dashboard.hosts[0].snapshot?.accounts[index].availability = .unsupported
            state.dashboard.hosts[0].snapshot?.accounts[index].windows = []
        }
        try await settle()
        try require(find("quota-account-3", in: root) == nil && find("quota-overflow", in: root) == nil,
                    "all-unsupported accounts retained an empty quota control")
        try require(popup("detail-Account 3") == nil, "hidden quota toolbar retained its popover")
        try capture(root, label: "no-supported-quotas")

        state.dashboard.hosts = saved
        try await settle()
        try require(find("quota-account-0", in: root) != nil && find("quota-overflow", in: root) != nil,
                    "supported quotas did not return after an account update")
        try require(popup("detail-Account 3") == nil, "account update reopened an old popover")
    }

    @MainActor private func popup(_ id: String) -> NSView? {
        NSApp.windows.filter(\.isVisible).compactMap { $0.contentView }.compactMap { find(id, in: $0) }.first
    }

    @MainActor private func capture(_ view: NSView, label: String) throws {
        guard let path = ProcessInfo.processInfo.environment["CTRLX_TITLEBAR_SCREENSHOTS"],
              let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        if let png = image.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("\(label)-\(detached ? "dark" : "light").png"))
        }
    }

    @MainActor private func click(_ view: NSView, in window: NSWindow) async throws {
        let rect = view.convert(view.bounds, to: nil)
        try await postClick(window, at: .init(x: rect.midX, y: rect.midY))
    }

    @MainActor private func postClick(_ window: NSWindow, at point: NSPoint) async throws {
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            NSApp.postEvent(event, atStart: false)
        }
        try await settle()
    }

    @MainActor private func reset(_ window: NSWindow, to frame: NSRect) async throws {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.setFrame(frame, display: true)
        try await settle()
    }

    @MainActor private func doubleClick(_ window: NSWindow, at point: NSPoint) async throws {
        // Post only to this private window; never inject global events or target the installed app.
        for count in [1, 2] {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: count, clickCount: count, pressure: 0)
                else {
                    throw failure("could not create mouse event")
                }
                NSApp.postEvent(event, atStart: false)
            }
            try await Task.sleep(for: .milliseconds(60))
        }
        try await settle()
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(600))
    }

    @MainActor private func find(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id {
            return view
        }
        return view.subviews.lazy.compactMap { find(id, in: $0) }.first
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw failure(message)
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "TitlebarFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@main
struct TitlebarUIProbe: App {
    var body: some Scene {
        Window("Titlebar regression", id: "titlebar-probe") { TitlebarFixture() }
            .defaultSize(width: 1000, height: 600)
            .defaultLaunchBehavior(.presented)
            .restorationBehavior(.disabled)
    }
}
