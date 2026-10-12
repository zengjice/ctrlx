import AppKit
@preconcurrency import CtrlxSimulatorBridge
import Darwin
import Metal

@MainActor
final class DisplayBaseline: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var view: SimulatorMetalView!
    private var connection: CXSimulatorConnection?
    private let root = URL(fileURLWithPath: CommandLine.arguments[1])
    private let service = CommandLine.arguments[2]
    private let measurementSeconds = Double(ProcessInfo.processInfo.environment["CTRLX_BASELINE_SECONDS"] ?? "20") ?? 20

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let metal = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "Metal", code: 1) }
            view = try SimulatorMetalView(metal: metal)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1665, height: 930.5),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "CtrlX Simulator — AppKit baseline"
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
            Task { await measure() }
        } catch { fail(error.localizedDescription) }
    }

    private func request(_ command: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["command": command])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection?.request(data) { result, error in
                if let error { continuation.resume(throwing: error) }
                else if result != nil { continuation.resume() }
                else { continuation.resume(throwing: NSError(domain: "Empty response", code: 1)) }
            }
        }
    }

    private func measure() async {
        do {
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) else {
                throw NSError(domain: "Bootstrap timeout", code: 1)
            }
            connection = CXSimulatorConnection(serviceName: service, frameHandler: { [weak self] frame in
                Task { @MainActor in
                    guard let self else { frame.finish(); return }
                    self.view.receive(frame)
                }
            }, errorHandler: { [weak self] message in
                Task { @MainActor [weak self] in self?.fail(message) }
            })
            try await request("connect")
            try await request("subscribe")
            try await Task.sleep(for: .seconds(3))
            let first = view.measurements.read()
            let start = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .seconds(measurementSeconds))
            let sample = view.measurements.read()
            let seconds = ProcessInfo.processInfo.systemUptime - start
            func p95(_ values: [Double]) -> Double {
                let sorted = values.sorted()
                return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            }
            let result: [String: Any] = ["seconds": seconds, "frames": sample.frames - first.frames,
                "sourceCallbacks": sample.sourceSequence - first.sourceSequence,
                "fps": Double(sample.frames - first.frames) / seconds,
                "sourceToPresentP95Ms": p95(Array(sample.milliseconds.dropFirst(first.milliseconds.count))),
                "stageP95Ms": zip(sample.stages, first.stages).map { p95(Array($0.dropFirst($1.count))) },
                "copyStageP95Ms": zip(sample.copyStages, first.copyStages).map { p95(Array($0.dropFirst($1.count))) },
                "renderStageP95Ms": zip(sample.renderStages, first.renderStages).map { p95(Array($0.dropFirst($1.count))) },
                "renderedDrawableSamples": sample.renderRecords - first.renderRecords,
                "copyStageSamples": sample.copyRecords - first.copyRecords,
                "drawableWaitP95Ms": p95(Array(sample.drawableWaits.dropFirst(first.drawableWaits.count))),
                "drawableWaitMaxMs": sample.drawableWaits.max() ?? 0,
                "width": view.bounds.width, "height": view.bounds.height]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("metrics.json"))
            view.close()
            connection?.invalidate()
            NSApp.terminate(nil)
        } catch { fail(error.localizedDescription) }
    }

    private func fail(_ message: String) {
        try? message.write(to: root.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
        view?.close()
        connection?.invalidate()
        NSApp.terminate(nil)
    }
}

@main
@MainActor
enum BaselineMain {
    static func main() {
        guard CommandLine.arguments.count >= 3 else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = DisplayBaseline()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
