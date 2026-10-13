import AppKit
import SwiftUI

@MainActor @Observable
final class Recording {
    var presented = false
    var phase = VoiceInputPhase.idle
    var stops = 0
    var insertions = 0
    var cancellations = 0

    func toggle() {
        switch phase.tapAction {
        case .start:
            phase = .recording
            presented = true
        case .finish:
            phase = .finalizing
            stops += 1
        case .cancelPreparation: cancel()
        case .none: break
        }
    }

    func complete() {
        precondition(phase == .finalizing)
        phase = .idle
        presented = false
        insertions += 1
    }

    func cancel() {
        phase = .idle
        presented = false
        cancellations += 1
    }
}

struct StopAnchor: NSViewRepresentable {
    final class Target: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    func makeNSView(context: Context) -> Target {
        Target()
    }

    func updateNSView(_ view: Target, context: Context) { }
}

struct Microphone: View {
    let recording: Recording
    var body: some View {
        Button("Microphone", action: recording.toggle)
            .background {
                MacVoiceInputPopover(isPresented: recording.presented, onCancel: recording.cancel) {
                    Button("Stop and Insert", action: recording.toggle)
                        .background { StopAnchor() }
                        .padding(20)
                }
            }
            .padding(30)
    }
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    let recording = Recording()
    var work: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 320, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: Microphone(recording: recording))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        work = Task {
            do {
                try await wait("microphone layout") {
                    (find(MacVoiceInputPopoverAnchor.self, in: hosting)?.bounds.width ?? 0) > 0
                }
                let anchor = find(MacVoiceInputPopoverAnchor.self, in: hosting)!
                try await click(anchor)
                try await wait("first preview") { anchor.popover.isShown }
                try await click(anchor)
                try await wait("microphone stop") { recording.stops == 1 }
                precondition(recording.cancellations == 0 && anchor.popover.isShown)
                try await click(anchor)
                precondition(recording.stops == 1 && recording.cancellations == 0)
                recording.complete()
                try await wait("first completion") { !anchor.popover.isShown }
                precondition(recording.insertions == 1 && recording.cancellations == 0)

                try await click(anchor)
                try await wait("second preview") { anchor.popover.isShown }
                let stop = find(StopAnchor.Target.self, in: anchor.popover.contentViewController!.view)!
                try await click(stop)
                try await wait("preview stop") { recording.stops == 2 }
                recording.complete()
                try await wait("second completion") { !anchor.popover.isShown }
                precondition(recording.insertions == 2 && recording.cancellations == 0)

                try await click(anchor)
                try await wait("Escape preview") { anchor.popover.isShown }
                let escape = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: anchor.popover.contentViewController!.view.window!.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53
                )!
                NSApp.sendEvent(escape)
                try await wait("Escape cancellation") { !recording.presented }
                precondition(recording.cancellations == 1 && recording.insertions == 2)

                try await click(anchor)
                try await wait("outside click preview") { anchor.popover.isShown }
                try await click(hosting, at: NSPoint(x: 5, y: 5))
                try await wait("outside cancellation") { !recording.presented }
                precondition(recording.cancellations == 2 && recording.insertions == 2)
                anchor.close()
                window.close()
                print("PASS: microphone stop, finalization, preview stop, Escape, outside click")
                NSApp.terminate(nil)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
    }

    func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    func wait(_ label: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "VoicePopoverProbeTimeout", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
    }

    func click(_ view: NSView, at point: NSPoint? = nil) async throws {
        let location = view.convert(point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: location, modifierFlags: [], timestamp: down.timestamp + 0.01,
            windowNumber: view.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0
        )!
        var released = false
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            released = true
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        try await wait("mouse release") { released }
    }
}

@main
struct VoicePopoverProbe {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Delegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) { }
    }
}
