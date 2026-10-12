import AppKit
@preconcurrency import CtrlxSimulatorBridge
import Darwin
import Metal
import QuartzCore

@MainActor
final class PresentationReadiness: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var view: SimulatorMetalView?
    private var connection: CXSimulatorConnection?
    private let root = URL(fileURLWithPath: CommandLine.arguments[1])
    private let service = CommandLine.arguments[2]

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let metal = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "Metal", code: 1) }
            let view = try SimulatorMetalView(metal: metal)
            self.view = view
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1665, height: 930.5),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            self.window = window
            window.title = "CtrlX Simulator — presentation readiness regression"
            window.contentView = view
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            var info = proc_bsdinfo()
            guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0 else {
                throw NSError(domain: "Process", code: 1)
            }
            try JSONSerialization.data(withJSONObject: ["pid": getpid(), "seconds": info.pbi_start_tvsec,
                "micros": info.pbi_start_tvusec]).write(to: root.appendingPathComponent("parent.json"))
            Task { await checkReadiness() }
        } catch { finish(error: error) }
    }

    private func request(_ command: String) async throws {
        guard let connection else { throw NSError(domain: "Connection", code: 1) }
        let data = try JSONSerialization.data(withJSONObject: ["command": command])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.request(data) { result, error in
                if let error { continuation.resume(throwing: error) }
                else if result != nil { continuation.resume() }
                else { continuation.resume(throwing: NSError(domain: "Empty response", code: 1)) }
            }
        }
    }

    private func checkReadiness() async {
        do {
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let view, FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) else {
                throw NSError(domain: "Bootstrap", code: 1)
            }
            connection = CXSimulatorConnection(serviceName: service, frameHandler: { [weak self] frame in
                Task { @MainActor [weak self] in
                    guard let self, let view = self.view else { frame.finish(); return }
                    view.receive(frame)
                }
            }, errorHandler: { [weak self] message in
                Task { @MainActor [weak self] in self?.finish(error: NSError(domain: message, code: 1)) }
            })
            try await request("connect")
            guard let originalLayer = view.layer else { throw NSError(domain: "Missing Metal layer", code: 1) }
            view.layer = CALayer()
            CATransaction.flush()
            try await request("subscribe")
            try await Task.sleep(for: .seconds(3))
            let hidden = view.measurements.read()
            let hiddenReady = view.inputReady
            let expectation = ProcessInfo.processInfo.environment["CTRLX_BASELINE_READINESS_EXPECTATION"] ?? "reject"
            guard expectation == "reject" || expectation == "reproduce-old" else {
                throw NSError(domain: "Expectation", code: 1)
            }
            try JSONSerialization.data(withJSONObject: ["inputReady": hiddenReady,
                "drawableAcquisitions": hidden.drawableAcquisitions, "presentedFrames": hidden.frames,
                "windowOcclusionState": window?.occlusionState.rawValue ?? 0,
                "viewHidden": view.isHiddenOrHasHiddenAncestor,
                "geometryAvailable": view.geometry != nil], options: [.sortedKeys])
                .write(to: root.appendingPathComponent("detached-state.json"))
            guard hidden.drawableAcquisitions > 0, hidden.frames == 0 else {
                throw NSError(domain: "Detached layer did not exercise dropped drawables", code: 1)
            }
            guard hiddenReady == (expectation == "reproduce-old") else {
                throw NSError(domain: "Input readiness disagrees with actual presentation", code: 1)
            }
            let restoredAt = ProcessInfo.processInfo.systemUptime
            view.layer = originalLayer
            CATransaction.flush()
            let deadline = restoredAt + 2
            while !view.inputReady || view.measurements.read().frames == 0 {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw NSError(domain: "Valid presentation did not restore readiness", code: 1)
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            let actual = view.measurements.read()
            let result: [String: Any] = [
                "scope": "Actual Metal drawables: detached layer has zero positive presentations; reattached layer must present before input readiness",
                "expectation": expectation, "detachedInputReady": hiddenReady,
                "detachedDrawableAcquisitions": hidden.drawableAcquisitions, "detachedPresentedFrames": hidden.frames,
                "visibleInputReady": view.inputReady, "visiblePresentedFrames": actual.frames,
                "firstPositivePresentedAt": actual.firstTime, "restoredAt": restoredAt,
                "readyAt": view.inputReadyAt, "passed": true,
            ]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("metrics.json"))
            finish(error: nil)
        } catch { finish(error: error) }
    }

    private func finish(error: Error?) {
        if let error {
            do { try error.localizedDescription.write(to: root.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8) }
            catch { fputs("Cannot save readiness error: \(error)\n", stderr) }
        }
        view?.close()
        connection?.invalidate()
        NSApp.terminate(nil)
    }
}

@main
@MainActor
enum ReadinessMain {
    static func main() {
        guard CommandLine.arguments.count >= 3 else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = PresentationReadiness()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
