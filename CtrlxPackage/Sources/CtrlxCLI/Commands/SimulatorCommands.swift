import ArgumentParser
import CtrlxSimulatorProtocol
import Darwin
import Dependencies
import DependenciesMacros
import Foundation

struct SimulatorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ios", abstract: "Control iOS in this coding agent's CtrlX session (currently iOS Simulator only)",
        subcommands: [SimulatorActionCommand.self, SimulatorBatchCommand.self, SimulatorRunCommand.self], defaultSubcommand: SimulatorActionCommand.self)
}

struct SimulatorRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run Codex with its native --no-daemon flag so tools retain this terminal's process identity")
    @Argument(parsing: .captureForPassthrough) var command: [String]

    func run() async throws {
        let words = command.first == "--" ? Array(command.dropFirst()) : command
        guard let executable = words.first, URL(fileURLWithPath: executable).lastPathComponent == "codex" else {
            throw ValidationError("Use ctrlx ios run -- codex [options]; Codex must support --no-daemon")
        }
        var arguments = Array(words.dropFirst())
        let options = arguments.prefix { $0 != "--" }
        guard !options.contains(where: { $0 == "--remote" || $0.hasPrefix("--remote=") }) else {
            throw ValidationError("run requires local Codex execution; do not pass --remote")
        }
        if !options.contains("--no-daemon") { arguments.insert("--no-daemon", at: 0) }
        @Dependency(SimulatorLaunchClient.self) var launcher
        try await launcher.run(executable, arguments)
    }
}

@DependencyClient
struct SimulatorLaunchClient: Sendable {
    var run: @Sendable (String, [String]) async throws -> Void
}

extension SimulatorLaunchClient: DependencyKey {
    static let liveValue = Self(run: { executable, arguments in
        let pointers = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { for pointer in pointers { free(pointer) } }
        pointers.withUnsafeBufferPointer { buffer in _ = execvp(executable, buffer.baseAddress!) }
        throw ValidationError("Cannot execute \(executable): \(String(cString: strerror(errno)))")
    })
}

struct SimulatorActionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "action",
        abstract:
            "inventory | config | resources | identity | devices | storage | open | erase | delete | status | metrics | logs | crashes | show | display-mode | snapshot | wait | tap | swipe | long-press | drag | pinch | rotate | key | button | paste | install | uninstall | launch | terminate | open-url | location | appearance | privacy | push | screenshot | record-start | record-stop | record-status | claim | close"
    )
    @Argument var operation: String
    @Option var socket: String?
    @Option(help: "CtrlX device ID returned by open, distinct from the simulator UDID") var device: String?
    @Option(help: "Exact private simulator UUID from storage; open, erase or delete only. Erase/delete require an idle, shut-down device") var udid: String?
    @Flag(name: .customLong("new"), help: "Open an additional device instead of reusing this pane's default; open only") var newDevice = false
    @Option var runtime: String?
    @Option var deviceType: String?
    @Option(help: "standard (default) or balanced; applied before the app starts") var profile: String?
    @Option(help: "Required features to retain, e.g. push,storekit,widgets,siri") var requires: String?
    @Option(help: "synchronized (default) or low-latency; display-mode only") var mode: String?
    @Flag(help: "Show this simulator in the right split pane; show only") var split = false
    @Option(help: "Global open-device limit, 1...32; config only") var maxDevices: Int?
    @Option(help: "Memory reserve in MiB before starting another device; config only") var memoryReserveMiB: Int?
    @Option(help: "Disk reserve in MiB before starting another device; config only") var diskReserveMiB: Int?
    @Option var x: Double?
    @Option var y: Double?
    @Option var endX: Double?
    @Option var endY: Double?
    @Option(help: "Origin edge for a system swipe: top, left, bottom or right; swipe only") var edge: SimulatorTouchEdge?
    @Option var durationMs: Int?
    @Option(help: "Final / initial finger distance, 0.25...4 except 1; pinch only, centered at --x/--y") var scale: Double?
    @Option(help: "Recording duration limit, 1...60, default 60; record-start only") var seconds: Int?
    @Option(help: "Hold before dragging, default 500 ms") var holdMs: Int?
    @Option(help: "Element reference from the most recent snapshot") var ref: String?
    @Option(help: "Exact accessibility identifier") var identifier: String?
    @Option(help: "Exact accessibility label or title") var label: String?
    @Option(help: "Exact AX role, optionally combined with identifier or label") var role: String?
    @Option(help: "visible (default) or absent; wait only") var state: String?
    @Option(help: "wait/launch readiness deadline in milliseconds, 1...60000; defaults: wait 5000, launch 30000") var timeoutMs: Int?
    @Option(help: "portrait, portrait-upside-down, landscape-left or landscape-right") var orientation: String?
    @Option(help: "USB HID keyboard usage (4...231)") var usage: Int?
    @Option(help: "Comma-separated control,shift,alt,command; key only") var modifiers: String?
    @Option(help: "home, lock, volume-up, volume-down") var button: String?
    @Option(help: "UTF-8 text for explicit paste (simulator clipboard only, up to 16 KB)") var text: String?
    @Flag(help: "Paste through the iOS edit menu at an explicit target; long press may change the selection") var viaMenu = false
    @Option(help: "Absolute path to an iPhoneSimulator .app") var app: String?
    @Option var bundle: String?
    @Option var url: String?
    @Option(parsing: .unconditional, help: "Simulated latitude, -90...90; location only") var latitude: Double?
    @Option(parsing: .unconditional, help: "Simulated longitude, -180...180; location only") var longitude: Double?
    @Flag(help: "Stop location simulation; location only") var clear = false
    @Option(help: "light or dark; appearance only, omit to read the current style") var style: SimulatorAppearance?
    @Option(name: .customLong("action"), help: "grant, revoke or reset; privacy only") var privacyAction: SimulatorPrivacyAction?
    @Option(help: "Permission service, e.g. location, photos or microphone; privacy only") var service: SimulatorPrivacyService?
    @Option(help: "Path to a UTF-8 JSON push payload, up to 4096 bytes; push only") var payload: String?
    @Option(help: "Recent time range; logs 1...300 (default 30), crashes 1...86400 (default 3600)") var lastSeconds: Int?
    @Option(help: "Retained diagnostic bytes, 1...262144, default 65536; logs/crashes only") var maxBytes: Int?
    @Option(help: "Accessibility nodes, 1...1000, default 200") var limit: Int?
    @Option(help: "New PNG path for screenshot, or absolute new MP4 path for record-start; never overwrites") var output: String?
    @Flag(help: "Start a display measurement window in an isolated --e2e-test app; status only") var resetMeasurements = false

    func parameters() throws -> [String: JSONValue] {
        guard SimulatorOperation(rawValue: operation) != nil else { throw ValidationError("Unsupported simulator operation") }
        if newDevice, operation != "open" {
            throw ValidationError("--new requires open")
        }
        if let timeoutMs {
            guard ["wait", "launch"].contains(operation), (1...60000).contains(timeoutMs) else {
                throw ValidationError("--timeout-ms requires wait or launch and a value of 1...60000")
            }
        }
        if resetMeasurements, operation != "status" {
            throw ValidationError("--reset-measurements requires status")
        }
        if viaMenu, operation != "paste" { throw ValidationError("--via-menu requires paste") }
        if split, operation != "show" { throw ValidationError("--split requires show") }
        if modifiers != nil, operation != "key" { throw ValidationError("--modifiers requires key") }
        if edge != nil, operation != "swipe" { throw ValidationError("--edge requires swipe") }
        if scale != nil, operation != "pinch" { throw ValidationError("--scale requires pinch") }
        if seconds != nil, operation != "record-start" { throw ValidationError("--seconds requires record-start") }
        if operation == "pinch" {
            guard let x, let y, let scale, endX == nil, endY == nil, holdMs == nil else {
                throw ValidationError("pinch requires --x, --y and --scale; no endpoint or hold options")
            }
            _ = try SimulatorPinch(center: SimulatorPoint(x: x, y: y), scale: scale, durationMs: durationMs ?? 500)
        }
        let keyModifiers = modifiers.map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) } ?? []
        if operation == "key" {
            guard let usage else { throw ValidationError("key requires --usage") }
            _ = try SimulatorKeyPress(usage: usage, modifiers: keyModifiers)
        }
        if viaMenu, ref == nil, identifier == nil, label == nil, role == nil, x == nil || y == nil {
            throw ValidationError("Menu paste requires an element target or both --x and --y")
        }
        if let udid {
            guard ["open", "erase", "delete"].contains(operation), UUID(uuidString: udid) != nil,
                  device == nil, runtime == nil, deviceType == nil else {
                throw ValidationError("--udid requires open, erase or delete and one UUID, without --device, --runtime or --device-type")
            }
        }
        if ["erase", "delete"].contains(operation), udid == nil {
            throw ValidationError("\(operation) requires --udid from storage; close the device first")
        }
        if operation == "uninstall" {
            guard let bundle else { throw ValidationError("uninstall requires --bundle") }
            try validateSimulatorBundle(bundle)
        }
        if !["inventory", "config", "resources", "identity", "devices", "storage", "open", "erase", "delete"].contains(operation), device == nil {
            throw ValidationError("This operation requires --device")
        }
        if operation != "config", maxDevices != nil || memoryReserveMiB != nil || diskReserveMiB != nil {
            throw ValidationError("Resource configuration options require config")
        }
        if operation != "open", profile != nil || requires != nil {
            throw ValidationError("Service profile options require open")
        }
        if operation != "location", latitude != nil || longitude != nil || clear {
            throw ValidationError("Location options require location")
        }
        if operation == "location" {
            if clear {
                guard latitude == nil, longitude == nil else { throw ValidationError("Choose coordinates or --clear") }
            } else {
                guard let latitude, let longitude else { throw ValidationError("location requires both coordinates or --clear") }
                _ = try SimulatorLocation(latitude: latitude, longitude: longitude)
            }
        }
        if operation != "appearance", style != nil { throw ValidationError("--style requires appearance") }
        if operation != "privacy", privacyAction != nil || service != nil { throw ValidationError("Permission options require privacy") }
        if operation == "privacy" {
            guard let privacyAction, let service, let bundle else { throw ValidationError("privacy requires --action, --service and --bundle") }
            _ = try SimulatorPrivacyRequest(action: privacyAction, service: service, bundle: bundle)
        }
        if operation != "push", payload != nil { throw ValidationError("--payload requires push") }
        if !["logs", "crashes"].contains(operation), lastSeconds != nil || maxBytes != nil {
            throw ValidationError("Diagnostic bounds require logs or crashes")
        }
        if operation == "logs" {
            guard let bundle, limit == nil else { throw ValidationError("logs requires --bundle; --limit applies to crash reports or AX") }
            _ = try SimulatorLogRequest(bundle: bundle, lastSeconds: lastSeconds ?? 30, maximumBytes: maxBytes ?? 65536)
        }
        if operation == "crashes" {
            guard let bundle else { throw ValidationError("crashes requires --bundle") }
            _ = try SimulatorCrashRequest(bundle: bundle, lastSeconds: lastSeconds ?? 3600, limit: limit ?? 5, maximumBytes: maxBytes ?? 65536)
        }
        var push: SimulatorPushNotification?
        if operation == "push" {
            guard let bundle, let payload else { throw ValidationError("push requires --bundle and --payload") }
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: payload))
            defer { try? file.close() }
            let data = try file.read(upToCount: 4097) ?? Data()
            push = try SimulatorPushNotification(bundle: bundle, payload: data)
        }
        if operation == "display-mode" {
            guard let mode, ["synchronized", "low-latency"].contains(mode) else {
                throw ValidationError("display-mode requires --mode synchronized or low-latency")
            }
        } else if mode != nil {
            throw ValidationError("--mode requires display-mode")
        }
        if let profile, !["standard", "balanced"].contains(profile) { throw ValidationError("Unknown simulator profile") }
        if ref != nil, identifier != nil || label != nil || role != nil {
            throw ValidationError("Choose a snapshot reference or semantic selectors")
        }
        if ref != nil || identifier != nil || label != nil || role != nil {
            guard (["tap", "long-press", "drag", "wait"].contains(operation) || operation == "paste" && viaMenu), x == nil, y == nil else {
                throw ValidationError("Element selectors require tap, long-press, drag, wait or menu paste, without start coordinates")
            }
        }
        if operation == "wait", ref != nil || (identifier == nil && label == nil && role == nil) {
            throw ValidationError("wait requires an identifier, label or role selector")
        }
        if operation == "screenshot" {
            guard let output, !FileManager.default.fileExists(atPath: output) else {
                throw ValidationError("screenshot requires --output <new.png>; existing files are preserved")
            }
        } else if operation == "record-start" {
            guard let output else { throw ValidationError("record-start requires --output /absolute/new.mp4") }
            _ = try SimulatorRecordingOptions(output: output, seconds: seconds ?? 60)
        } else if output != nil {
            throw ValidationError("Only screenshot and record-start accept --output")
        }
        var params: [String: JSONValue] = ["command": .string(operation)]
        if operation == "record-start", let output { params["output"] = .string(output) }
        if let seconds { params["seconds"] = .int(seconds) }
        if let scale { params["scale"] = .double(scale) }
        if newDevice {
            params["new"] = .bool(true)
        }
        if split { params["split"] = .bool(true) }
        if clear { params["clear"] = .bool(true) }
        if let edge { params["edge"] = .string(edge.rawValue) }
        if let style { params["style"] = .string(style.rawValue) }
        if let privacyAction { params["action"] = .string(privacyAction.rawValue) }
        if let service { params["service"] = .string(service.rawValue) }
        if let push { params["payload"] = .string(String(decoding: push.payload, as: UTF8.self)) }
        if resetMeasurements { params["resetMeasurements"] = .bool(true) }
        if let lastSeconds { params["lastSeconds"] = .int(lastSeconds) }
        if let maxBytes { params["maximumBytes"] = .int(maxBytes) }
        if viaMenu { params["viaMenu"] = .bool(true) }
        if modifiers != nil { params["modifiers"] = .array(keyModifiers.map(JSONValue.string)) }
        for (name, value) in [
            ("device", device), ("udid", udid), ("runtime", runtime), ("deviceType", deviceType), ("button", button), ("text", text), ("app", app),
            ("bundle", bundle), ("url", url), ("profile", profile), ("requires", requires), ("mode", mode),
            ("ref", ref), ("identifier", identifier), ("label", label), ("role", role), ("state", state), ("orientation", orientation),
        ] {
            if let value { params[name] = .string(value) }
        }
        for (name, value) in [("x", x), ("y", y), ("endX", endX), ("endY", endY)] {
            if let value {
                guard value.isFinite else { throw ValidationError("Coordinates must be finite") }
                params[name] = .double(value)
            }
        }
        if let latitude { params["latitude"] = .double(latitude) }
        if let longitude { params["longitude"] = .double(longitude) }
        for (name, value) in [("durationMs", durationMs), ("usage", usage), ("limit", limit), ("maximumDevices", maxDevices),
            ("memoryReserveMiB", memoryReserveMiB), ("diskReserveMiB", diskReserveMiB), ("holdMs", holdMs), ("timeoutMs", timeoutMs)] {
            if let value { params[name] = .int(value) }
        }
        guard try JSONEncoder().encode(params).count <= 64000 else { throw ValidationError("Simulator request exceeds 64 KB") }
        return params
    }

    func run() throws {
        let params = try parameters()
        let screenshotRequestedAt = operation == "screenshot" ? ProcessInfo.processInfo.systemUptime : 0
        @Dependency(SimulatorCommandClient.self) var client
        let response = try client.send(
            JSONRPCRequest(id: UUID().uuidString, method: "simulator.action", params: params), socket,
            operation == "open" ? 240 : 130, 9 * 1024 * 1024)
        guard response.ok else { throw ValidationError(response.error?.message ?? "Simulator action failed") }
        let result = try saveScreenshot(response.result ?? [:], requestedAt: screenshotRequestedAt)
        let data = try JSONEncoder().encode(result)
        print(String(decoding: data, as: UTF8.self))
    }

    func saveScreenshot(_ original: [String: JSONValue], requestedAt: Double) throws -> [String: JSONValue] {
        var result = original
        if operation == "screenshot", let output {
            guard let encoded = result["data"]?.stringValue, let data = Data(base64Encoded: encoded), data.count <= 6 * 1024 * 1024,
                data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
            else { throw ValidationError("Invalid simulator PNG") }
            let fd = Darwin.open(output, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw ValidationError("Output exists or cannot be created") }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try file.write(contentsOf: data)
            try file.close()
            if case let .object(originalGeometry)? = result["geometry"],
               case let .object(originalTiming)? = originalGeometry["screenshotTiming"] {
                var geometry = originalGeometry
                var timing = originalTiming
                timing["cliRequestedAt"] = .double(requestedAt)
                timing["cliFileWrittenAt"] = .double(ProcessInfo.processInfo.systemUptime)
                geometry["screenshotTiming"] = .object(timing)
                result["geometry"] = .object(geometry)
            }
            result.removeValue(forKey: "data")
            result["path"] = .string(output)
            result["bytes"] = .int(data.count)
        }
        return result
    }
}

@DependencyClient
struct SimulatorCommandClient: Sendable {
    var send: @Sendable (_ request: JSONRPCRequest, _ socketPath: String?, _ timeoutSeconds: Int, _ responseLimit: Int) throws -> JSONRPCResponse
}

extension SimulatorCommandClient: DependencyKey {
    static let liveValue = Self(send: { request, socketPath, timeoutSeconds, responseLimit in
        try SocketClient.send(request, socketPath: socketPath, timeoutSeconds: TimeInterval(timeoutSeconds), responseLimit: responseLimit)
    })
}

extension SimulatorAppearance: ExpressibleByArgument {}
extension SimulatorPrivacyAction: ExpressibleByArgument {}
extension SimulatorPrivacyService: ExpressibleByArgument {}
extension SimulatorTouchEdge: ExpressibleByArgument {}
