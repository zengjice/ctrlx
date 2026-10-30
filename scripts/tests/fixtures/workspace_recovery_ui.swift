import AppKit
import Observation
import SwiftUI

/// Capture the production actions while retaining native SwiftUI controls.
/// The hidden fixture never sends mouse or keyboard input to another app.
@MainActor private enum RecoveryActions {
    static var actions: [String: () -> Void] = [:]
}

extension Button where Label == Text {
    @MainActor init(_ title: String, action: @escaping @MainActor () -> Void) {
        self.init(action: action) { Text(title) }
        RecoveryActions.actions[title] = action
    }
}

@MainActor @Observable final class AppCoordinator {
    var workspaceRecovery: WorkspaceRecoveryController? = .init()
}

@MainActor @Observable final class AppSettings {
    enum Mode { case enabled, disabled }
    var workspaceRecoveryMode = Mode.enabled
}

@MainActor @Observable final class WorkspaceRecoveryController {
    enum Phase { case needsRecovery }
    var phase = Phase.needsRecovery
    var isReady = true
    var error: String?
    var failures = (1 ... 30).map { WorkspaceRecoveryFailure(name: "Fixture / Terminal \($0)") }
    var keeps = 0
    func retry() async {}
    func useShell(_: UUID) async {}
    func resumeAgent(_: UUID) async {}
    func keepCurrentTerminals() async {
        keeps += 1
    }
}

struct WorkspaceRecoveryFailure: Identifiable {
    let id = UUID()
    let name: String
    let reason = "Agent is starting; waiting to verify the original conversation."
    let canRetry = false
    let canResume = false
    let canUseShell = true
    let keepCurrentTerminal = true
}

@MainActor struct RecoveryProbe: NSViewRepresentable {
    let name: String
    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        view.identifier = .init(name)
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

@main struct RecoveryUIFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let coordinator = AppCoordinator()
        let root = VStack(spacing: 0) {
            WorkspaceRecoveryStatusView()
            Color.black.frame(minHeight: 160, maxHeight: .infinity)
                .background(RecoveryProbe(name: "workspace"))
        }
        .environment(coordinator)
        .environment(AppSettings())
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // The fixture never activates or orders a window onto the user's desktop.
        Task { @MainActor in
            do {
                try await settle(host)
                for size in [NSSize(width: 1000, height: 600), NSSize(width: 640, height: 480)] {
                    window.setContentSize(size)
                    try await settle(host)
                    for name in ["workspace-recovery-collapse", "workspace-recovery-keep-all", "workspace"] {
                        guard let view = descendants(host).first(where: { $0.identifier?.rawValue == name }) else {
                            throw failure("Missing \(name)")
                        }
                        let frame = view.convert(view.bounds, to: host)
                        guard frame.height > 0, NSContainsRect(host.bounds, frame) else {
                            throw failure("\(name) escaped \(host.bounds): \(frame)")
                        }
                    }
                }
                guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first else {
                    throw failure("Missing native scroll view")
                }
                let clip = scroll.contentView
                clip.scroll(to: .init(x: 0, y: 100))
                scroll.reflectScrolledClipView(clip)
                try await settle(host)
                guard clip.bounds.minY > 0 else { throw failure("Details did not scroll") }
                try runAction("Keep All Current Terminals")
                try await settle(host)
                guard coordinator.workspaceRecovery?.keeps == 1 else { throw failure("Keep action did not run") }
                try runAction("Collapse")
                try await settle(host)
                guard !descendants(host).contains(where: { $0.identifier?.rawValue == "workspace-recovery-collapse" }) else {
                    throw failure("Collapse did not dismiss the details")
                }
                print("PASS: recovery details scroll, header stays visible and Collapse works")
                window.close()
                exit(0)
            } catch {
                print("FAIL: \(error)")
                window.close()
                exit(1)
            }
        }
        app.run()
    }

    @MainActor private static func settle(_ view: NSView) async throws {
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor private static func runAction(_ title: String) throws {
        guard let action = RecoveryActions.actions[title] else { throw failure("Missing button: \(title)") }
        action()
    }

    private static func failure(_ message: String) -> NSError {
        .init(domain: "WorkspaceRecoveryUI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
