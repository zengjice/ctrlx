import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Icon resources are inert; menu items, drop routing and native handling use production code.
public enum Symbols: String {
    case minus
    var image: Image {
        Image(systemName: rawValue)
    }
}

@MainActor @Observable
final class TabDropFixtureState {
    let workspaceID = UUID()
    var notice: UUID?
    var rejections = 0
    var transfers = 0
    var reorders = 0
    var isDetached = false
    var canReturn = true
    var returnTab = TabDragPayload.window("@1")
    var returned: [WorkbenchTabDrag] = []
}

struct TabDropNoticeAnchor: NSViewRepresentable {
    var identifier = "rendered-drop-notice"

    func makeNSView(context _: Context) -> NSView {
        let view = Passthrough()
        view.identifier = .init(identifier)
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}

    final class Passthrough: NSView {
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }
    }
}

struct TabDropFixture: View {
    let state: TabDropFixtureState

    var body: some View {
        @Bindable var state = state
        Text("Destination tab")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .workbenchDropDestination(action: { _, _ in
                state.reorders += 1
                return true
            }, isTargeted: { _ in })
            .environment(\.workbenchTabContext, WorkbenchTabContext(
                workspaceID: state.workspaceID, hostID: nil, sessionName: "work",
                onRejected: { state.rejections += 1; state.notice = UUID() },
                receive: { _, _, _ in state.transfers += 1; return true }
            ))
            .modifier(WorkbenchTabDropNotice(presentationID: $state.notice))
    }
}

struct TabReturnFixture: View {
    let state: TabDropFixtureState

    var body: some View {
        var context = WorkbenchTabContext(
            workspaceID: state.isDetached ? state.workspaceID : nil,
            hostID: "viewer-host", sessionName: "work", onRejected: {}, receive: { _, _, _ in false }
        )
        if state.canReturn {
            context.returnToMain = { state.returned.append($0) }
        }
        return TabReturnToMainButton(tab: state.returnTab, name: "Resource")
            .environment(\.workbenchTabContext, context)
            .frame(width: 200, height: 50)
    }
}

/// Drive the real SwiftUI/AppKit destination with a private pasteboard, without global input.
@MainActor
final class TabDropInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any? = NSObject()
    let draggingSequenceNumber: Int
    var draggingLocation = NSPoint(x: 180, y: 100)
    var draggingSourceOperationMask: NSDragOperation {
        .move
    }

    var draggedImageLocation: NSPoint {
        draggingLocation
    }

    nonisolated var draggedImage: NSImage? {
        nil
    }

    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight {
        .none
    }

    init(window: NSWindow, pasteboard: NSPasteboard, sequence: Int) {
        draggingDestinationWindow = window
        draggingPasteboard = pasteboard
        draggingSequenceNumber = sequence
    }

    func slideDraggedImage(to _: NSPoint) {}
    override nonisolated func namesOfPromisedFilesDropped(atDestination _: URL) -> [String]? {
        nil
    }

    func resetSpringLoading() {}

    func enumerateDraggingItems(options _: NSDraggingItemEnumerationOptions, for _: NSView?, classes _: [AnyClass],
                                searchOptions _: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void)
    {
        for (index, item) in (draggingPasteboard.pasteboardItems ?? []).enumerated() {
            var stop: ObjCBool = false
            block(NSDraggingItem(pasteboardWriter: item), index, &stop)
            if stop.boolValue {
                break
            }
        }
    }
}

@MainActor
final class TabDropFixtureDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        let state = TabDropFixtureState()
        let host = NSHostingView(rootView: TabDropFixture(state: state))
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 400, height: 250),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        Task { @MainActor in
            do {
                try await checkReturnButton(state)
                try await settle(host)
                try require(!hasNotice(host), "notice initially visible")
                try await drop(.init(workspaceID: UUID(), hostID: nil, sessionName: "other", tab: .window("@1")),
                               sequence: 1, host: host, window: window)
                try require(state.rejections == 1 && state.transfers == 0 && state.reorders == 0,
                            "foreign session moved or reordered a tab")
                try require(hasNotice(host), "rejection explanation not visible")
                guard let noticeView = descendants(host).first(where: { $0.identifier?.rawValue == "rendered-drop-notice" }) else {
                    throw failure("rendered notice missing")
                }
                let noticeRect = noticeView.convert(noticeView.bounds, to: host)
                try require(noticeRect.minX >= 0 && noticeRect.maxX <= 400 && noticeRect.height > 0,
                            "notice overflows a narrow workspace")
                let firstNotice = state.notice
                try await Task.sleep(for: .milliseconds(1800))
                try await drop(.init(workspaceID: UUID(), hostID: "other-host", sessionName: "work", tab: .window("@1")),
                               sequence: 2, host: host, window: window)
                try require(state.rejections == 2 && state.transfers == 0 && state.reorders == 0,
                            "foreign host moved or reordered a tab")
                try require(state.notice != firstNotice, "repeated rejection did not restart notice lifetime")
                try await Task.sleep(for: .milliseconds(1400))
                try require(hasNotice(host), "old timer dismissed the newer rejection")
                try await Task.sleep(for: .milliseconds(1800))
                try await settle(host)
                try require(state.notice == nil && !hasNotice(host), "notice did not dismiss automatically")
                try await drop(.init(workspaceID: UUID(), hostID: nil, sessionName: "work", tab: .window("@1")),
                               sequence: 3, host: host, window: window)
                try require(state.transfers == 1 && state.rejections == 2, "valid merge failed")
                try await drop(.init(workspaceID: state.workspaceID, hostID: nil, sessionName: "work", tab: .window("@1")),
                               sequence: 4, host: host, window: window)
                try require(state.reorders == 1 && state.transfers == 1, "local reorder failed")
                print("PASS: native drop consumed, no tear-off, visible rejection, notice expiry, valid merge and reorder")
                window.close()
                NSApp.terminate(nil)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
    }

    private func checkReturnButton(_ state: TabDropFixtureState) async throws {
        let host = NSHostingView(rootView: TabReturnFixture(state: state))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 200, height: 50),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        func buttons() -> [NSView] {
            descendants(host).filter { $0.identifier?.rawValue == "rendered-return-button" }
        }
        try await settle(host)
        try require(buttons().isEmpty, "return button appeared in the main window")
        state.isDetached = true
        for payload in [TabDragPayload.window("@1"), .file(UUID()), .browser(UUID())] {
            state.returnTab = payload
            try await settle(host)
            let visible = buttons()
            try require(visible.count == 1, "separate window is missing its return button")
            let control = visible[0]
            let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1)
                else {
                    throw failure("could not create a private window click")
                }
                NSApp.postEvent(event, atStart: false)
            }
            try await settle(host)
            try require(state.returned.last?.tab == payload,
                        "return button targeted another tab")
            try require(state.returned.last?.hostID == "viewer-host" && state.returned.last?.workspaceID == state.workspaceID,
                        "return button lost its source workspace")
        }
        state.canReturn = false
        try await settle(host)
        try require(buttons().isEmpty, "return button appeared without a return action")
        state.canReturn = true
        state.returnTab = .git
        try await settle(host)
        try require(buttons().isEmpty, "non-movable tool exposed a return button")
        print("PASS: return button visibility and native action")
    }

    private func drop(_ drag: WorkbenchTabDrag, sequence: Int, host: NSView, window: NSWindow) async throws {
        guard let target = descendants(host).first(where: { !$0.registeredDraggedTypes.isEmpty }) else {
            throw failure("SwiftUI drop destination missing")
        }
        let pasteboard = NSPasteboard(name: .init("ctrlx-tab-drop-test-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        try pasteboard.setData(JSONEncoder().encode(drag), forType: .init(UTType.ctrlxWorkbenchTab.identifier))
        let info = TabDropInfo(window: window, pasteboard: pasteboard, sequence: sequence)
        let operation = target.draggingEntered(info)
        try require(!operation.isEmpty, "native drop target did not recognize the tab")
        try require(target.prepareForDragOperation(info), "native drop preparation failed")
        try require(target.performDragOperation(info), "drop was left unhandled")
        try await settle(host)
        target.concludeDragOperation(info)
        try require(!WindowTabDragSource.shouldDetach(operation: operation, cancelled: false, mouseReleased: true,
                                                      point: .init(x: 900, y: 100),
                                                      tabStripFrame: .init(x: 0, y: 500, width: 400, height: 30)),
                    "handled drop reached native tear-off fallback")
    }

    private func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func hasNotice(_ host: NSView) -> Bool {
        descendants(host).contains { $0.identifier?.rawValue == "rendered-drop-notice" }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw failure(message)
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "TabDropFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@main
struct TabDropUIProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = TabDropFixtureDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
