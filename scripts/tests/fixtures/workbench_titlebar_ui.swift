import AppKit
import SwiftUI

@MainActor @Observable
final class TitlebarFixtureState {
    var title = "cm"
    var buttonClicks = 0
}

struct TitlebarAnchor: NSViewRepresentable {
    let id: String
    func makeNSView(context _: Context) -> NSView {
        let view = Passthrough()
        view.identifier = .init(id)
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}

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
            .background(Color.black)
            .containerBackground(Color.black, for: .window)
            .toolbarBackground(Color.black, for: .windowToolbar)
            .navigationTitle(state.title)
            .toolbar(removing: .title)
            .toolbar {
                if !detached {
                    ToolbarItem(placement: .navigation) {
                        Button("Search") { state.buttonClicks += 1 }
                    }
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
