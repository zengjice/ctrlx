import AppKit
import SwiftUI

/// The app's real views use these inert dependencies. No audio, credentials,
/// tmux, installed app or external event injection is involved.
@MainActor @Observable
package final class VoiceInputController {
    var phase = VoiceInputPhase.idle
    var stage = VoiceInputStage.recording
    var transcript = ""
    var completedTranscript: String?
    var errorMessage: String?
    var correctionNotice: String?
    var isFeedbackVisible: Bool {
        phase != .idle || correctionNotice != nil
    }

    func dismissCorrectionNotice() {
        correctionNotice = nil
    }

    var isRecording: Bool {
        phase == .recording
    }
}

struct VoiceInputContextSnapshot {}
struct VoiceCorrectionSettings { var selection: Self? {
    nil
} }
struct TerminalPhraseContext: Equatable { var canSend = true }

@MainActor @Observable
final class TerminalQuickActionRouter {
    var token = 0
    var voiceInputRequest = 0
    var inserted: [String] = []

    struct VoiceInputHold: Equatable {
        enum State { case pressed, released, cancelled }
        let id = UUID()
        let token: Int
        var state = State.pressed
    }

    var voiceInputHold: VoiceInputHold?
    func matches(_ token: Int) -> Bool {
        token == self.token
    }

    func beginVoiceInputHold() -> UUID? {
        guard voiceInputHold?.state != .pressed else { return nil }
        let hold = VoiceInputHold(token: token)
        voiceInputHold = hold
        return hold.id
    }

    func endVoiceInputHold(_ id: UUID, cancelled: Bool = false) {
        guard voiceInputHold?.id == id, voiceInputHold?.state == .pressed else { return }
        voiceInputHold?.state = cancelled ? .cancelled : .released
    }
}

@MainActor
struct TerminalVoiceInputRequest {
    let token: Int
    init?(router: TerminalQuickActionRouter, context _: TerminalPhraseContext) {
        token = router.token
    }

    func isValid(router: TerminalQuickActionRouter, context _: TerminalPhraseContext) -> Bool {
        token == router.token
    }

    func insert(_ text: String, router: TerminalQuickActionRouter, context: TerminalPhraseContext) -> Bool {
        guard isValid(router: router, context: context) else { return false }
        router.inserted.append(text)
        return true
    }
}

@MainActor @Observable
final class TerminalVoiceInputSession {
    let voice = VoiceInputController()
    var stops = 0
    var cancellations = 0
    var needsPermission = false
    var correctionUnavailable = false
    var isPresented: Bool {
        voice.phase != .idle
    }

    func toggle(in _: TerminalPhraseContext, snapshot _: VoiceInputContextSnapshot?, selection _: VoiceCorrectionSettings?) {
        switch voice.phase.tapAction {
        case .start:
            voice.correctionNotice = nil
            voice.completedTranscript = nil
            voice.phase = needsPermission ? .requestingPermission : .recording
            voice.stage = .recording
            voice.transcript = "正在测试语音输入 CtrlX，保留当前终端焦点。"
        case .finish:
            voice.phase = .finalizing
            voice.stage = .onDeviceCorrection
            stops += 1
        case .cancelPreparation: cancel()
        case .none: break
        }
    }

    func complete() {
        precondition(voice.phase == .finalizing)
        voice.phase = .idle
        voice.completedTranscript = voice.transcript
    }

    func deliver(in _: TerminalPhraseContext, insert: (String) -> Bool) {
        guard let text = voice.completedTranscript else { return }
        voice.completedTranscript = nil
        if insert(text), correctionUnavailable {
            voice.correctionNotice = "Inserted without context-aware correction. Check Voice Input settings."
        }
    }

    func cancel() {
        voice.correctionNotice = nil
        if isPresented {
            cancellations += 1
        }
        voice.phase = .idle
        voice.completedTranscript = nil
    }
}

enum Symbols: String {
    case micFill = "mic.fill"
    case xmark
    var image: Image {
        Image(systemName: rawValue)
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: String, symbol: Symbols) {
        self.init { Text(title) } icon: { symbol.image }
    }
}

struct MicrophoneAnchor: NSViewRepresentable {
    final class Target: NSView {
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }
    }

    func makeNSView(context _: Context) -> Target {
        Target()
    }

    func updateNSView(_: Target, context _: Context) {}
}

struct ProbeAnchor: NSViewRepresentable {
    let id: String
    final class Target: NSView {
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }
    }

    func makeNSView(context _: Context) -> Target {
        let view = Target()
        view.identifier = NSUserInterfaceItemIdentifier(id)
        return view
    }

    func updateNSView(_: Target, context _: Context) {}
}

struct Terminal: NSViewRepresentable {
    final class Target: NSView {
        var escapes = 0
        override var acceptsFirstResponder: Bool {
            true
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                escapes += 1
            }
        }
    }

    func makeNSView(context _: Context) -> Target {
        Target()
    }

    func updateNSView(_: Target, context _: Context) {}
}

struct Workbench: View {
    let session: TerminalVoiceInputSession
    let router: TerminalQuickActionRouter
    var body: some View {
        VStack(spacing: 0) {
            Terminal().frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                MacVoiceInputButton(
                    router: router, settings: VoiceCorrectionSettings(), context: TerminalPhraseContext(),
                    session: session, isSuspended: false, contextProvider: { nil }, willStart: {}
                )
                .background { MicrophoneAnchor() }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .modifier(MacVoiceInputOverlay(session: session))
        }
    }
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    let session = TerminalVoiceInputSession()
    let router = TerminalQuickActionRouter()
    var work: Task<Void, Never>?

    func applicationDidFinishLaunching(_: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 720, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: Workbench(session: session, router: router))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        work = Task {
            do {
                try await wait("microphone layout") {
                    (find(MicrophoneAnchor.Target.self, in: hosting)?.bounds.width ?? 0) > 0
                }
                let anchor = find(MicrophoneAnchor.Target.self, in: hosting)!
                let terminal = find(Terminal.Target.self, in: hosting)!
                window.makeFirstResponder(terminal)
                let viewport = terminal.frame
                let windows = NSApp.windows.count
                try await click(anchor)
                try await wait("recording") { session.isPresented }
                try await wait("inline preview") { marker("voice-input-preview", in: hosting) != nil }
                precondition(window.firstResponder === terminal, "Preview stole first responder")
                precondition(terminal.frame == viewport, "Preview resized the terminal")
                precondition(NSApp.windows.count == windows, "Preview created a separate window")
                try snapshot(hosting, name: "wide")

                try await click(anchor)
                try await wait("microphone stop") { session.stops == 1 }
                precondition(session.cancellations == 0 && router.inserted.isEmpty)
                try await click(anchor)
                precondition(session.stops == 1 && session.cancellations == 0)
                session.complete()
                try await wait("insertion") { router.inserted.count == 1 }
                try await wait("preview removed") { marker("voice-input-preview", in: hosting) == nil }
                precondition(window.firstResponder === terminal && terminal.frame == viewport)

                // Narrow terminal: the preview must stay inside the same window;
                // its close button above the status bar must actually be clickable.
                window.setContentSize(NSSize(width: 230, height: 360))
                try await click(anchor)
                try await wait("narrow preview") { marker("voice-preview-cancel", in: hosting) != nil }
                let cancel = marker("voice-preview-cancel", in: hosting)!
                let rect = cancel.convert(cancel.bounds, to: nil)
                precondition(rect.minX >= 0 && rect.maxX <= window.contentView!.bounds.width)
                precondition(rect.midY > 44, "Preview must be above the status bar")
                try snapshot(hosting, name: "narrow")
                try await click(cancel)
                try await wait("cancel click") { session.cancellations == 1 }
                precondition(!session.isPresented && router.inserted.count == 1)
                precondition(window.firstResponder === terminal)

                try await click(anchor)
                try await wait("Escape preview") { session.isPresented }
                sendEscape(to: window)
                try await wait("Escape cancellation") { session.cancellations == 2 }
                precondition(terminal.escapes == 0 && router.inserted.count == 1)
                sendEscape(to: window)
                precondition(terminal.escapes == 1, "Idle Escape must reach the terminal")

                // Native held press starts before release and finishes exactly
                // once on release, without stealing terminal focus.
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try await wait("fixture key window") { window.isKeyWindow }
                window.makeFirstResponder(terminal)
                precondition(window.isKeyWindow, "Hold test requires the fixture window to be key")
                try await hold(anchor) {
                    precondition(session.voice.phase == .recording, "Hold phase: \(session.voice.phase), request: \(String(describing: router.voiceInputHold))")
                    precondition(window.firstResponder === terminal)
                }
                try await wait("hold release finishes") { session.stops == 2 }
                session.correctionUnavailable = true
                session.complete()
                try await wait("hold inserts once") { router.inserted.count == 2 }
                try await wait("uncorrected notice") { marker("voice-input-preview", in: hosting) != nil && session.voice.correctionNotice != nil }
                // Let both completion/phase observers run before checking that
                // normal finalization cleanup did not erase the notice.
                try await Task.sleep(for: .milliseconds(100))
                precondition(session.voice.correctionNotice != nil)
                precondition(!session.isPresented && window.firstResponder === terminal)
                try snapshot(hosting, name: "notice")
                let cancellations = session.cancellations
                sendEscape(to: window)
                precondition(terminal.escapes == 2, "Notice must not intercept terminal Escape")
                try await click(marker("voice-preview-cancel", in: hosting)!)
                try await wait("notice dismissed") { session.voice.correctionNotice == nil }
                precondition(session.cancellations == cancellations && router.inserted.count == 2)
                session.correctionUnavailable = false
                print("PASS: uncorrected notice survives delivery, preserves focus/Escape, dismisses without resending")

                session.needsPermission = true
                try await hold(anchor) {
                    precondition(session.voice.phase == .requestingPermission)
                }
                try await wait("release cancels pending permission") { session.voice.phase == .idle }
                precondition(session.stops == 2 && router.inserted.count == 2)
                session.needsPermission = false

                try await hold(anchor) {
                    precondition(session.voice.phase == .recording)
                    router.token += 1
                }
                try await wait("target change cancels hold") { session.voice.phase == .idle }
                precondition(session.stops == 2 && router.inserted.count == 2)
                precondition(router.voiceInputHold?.state != .pressed)
                window.close()
                print("PASS: inline preview, stable viewport/focus, microphone stop, cancel, scoped Escape")
                print("PASS: native hold/release, pending permission, changed target")
                NSApp.terminate(nil)
            } catch {
                print("phase=\(session.voice.phase) cancellations=\(session.cancellations)")
                print("FAIL: \(error)")
                exit(1)
            }
        }
    }

    func marker(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id {
            return view
        }
        return view.subviews.lazy.compactMap { self.marker(id, in: $0) }.first
    }

    func snapshot(_ view: NSView, name: String) throws {
        guard let prefix = ProcessInfo.processInfo.environment["CTRLX_VOICE_PROBE_SNAPSHOT"] else { return }
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
    }

    func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T {
            return result
        }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    func wait(_ label: String, _ condition: () -> Bool) async throws {
        for _ in 0 ..< 100 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "VoiceInlineProbeTimeout", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
    }

    func sendEscape(to window: NSWindow) {
        NSApp.sendEvent(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        )!)
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
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        // The production control consumes mouse-up. Wait for the app loop,
        // then assert behavior instead of depending on event-monitor ordering.
        try await Task.sleep(for: .milliseconds(100))
    }

    func hold(_ view: NSView, whileHeld: () -> Void) async throws {
        let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!, atStart: false)
            try await Task.sleep(for: .milliseconds(type == .leftMouseDown ? 600 : 100))
            if type == .leftMouseDown {
                whileHeld()
            }
        }
    }
}

@main
struct VoiceInlineProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Delegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
