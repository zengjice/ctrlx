#if os(macOS)
    import AppKit
    import CtrlxCommon
    import CtrlxNetworking
    import CtrlxSimulatorProtocol
    import Darwin
    import Dependencies
    import Foundation
    import Metal
    import Observation
    import QuartzCore

    @MainActor
    public final class AgentSimulatorService {
        private var coordinator: SimulatorCoordinator?
        private var workspaces: [UUID: SimulatorWorkspace] = [:]
        private var tabs: [UUID: SimulatorTabState] = [:]
        private var resolvePane: (@MainActor (Int32) async throws -> PaneInfo)?
        private var opening = 0
        private var closeTasks: [UUID: Task<Void, Never>] = [:]
        private var closing = false
        private var ownerMonitor: Task<Void, Never>?
        private let system: SimulatorSystemClient

        public init() {
            @Dependency(SimulatorSystemClient.self) var system
            self.system = system
        }

        func start(root: URL, resolvePane: @escaping @MainActor (Int32) async throws -> PaneInfo) {
            @Dependency(ProcessRunner.self) var runner
            @Dependency(SimulatorResourceClient.self) var resources
            self.resolvePane = resolvePane
            coordinator = SimulatorCoordinator(
                root: root.appendingPathComponent("agent-simulator", isDirectory: true),
                helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CtrlxSimulatorHost"), runner: runner, system: system,
                resources: resources)
            ownerMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.expireInactiveDevices()
                }
            }
        }

        private func expireInactiveDevices() {
            for state in Array(tabs.values) {
                let ownerEnded = (try? system.inspect(state.owner.pid).owner) != state.owner
                let idle = !state.visible && !state.writing && state.lastActivity.duration(to: .now) > .seconds(600)
                if ownerEnded || idle {
                    close(state)
                } else if !state.visible, !state.writing, state.lastActivity.duration(to: .now) > .seconds(60),
                          state.displayIdleTask == nil {
                    suspendIdleDisplay(state)
                }
            }
        }

        private func suspendIdleDisplay(_ state: SimulatorTabState) {
            let previous = state.visibilityTask
            state.displayIdleTask = Task { [weak state] in
                await previous?.value
                guard let state, !Task.isCancelled, !state.isClosed, !state.visible, !state.writing,
                      state.lastActivity.duration(to: .now) > .seconds(60) else { return }
                do {
                    let result = try await state.handle.worker.request(["command": .string("suspend-display")])
                    if !Task.isCancelled, result["suspended"]?.boolValue != true { state.displayIdleTask = nil }
                } catch {
                    if !Task.isCancelled { state.error = error.localizedDescription }
                }
            }
        }

        func register(_ workspace: SimulatorWorkspace) { workspaces[workspace.id] = workspace }
        func unregister(_ workspace: SimulatorWorkspace) {
            for state in tabs.values.filter({ $0.workspaceID == workspace.id }) { close(state) }
            workspaces.removeValue(forKey: workspace.id)
        }

        private func callingAgent(peer: Int32) throws -> SimulatorOwner {
            var pid = peer
            var seen = Set<Int32>()
            for _ in 0..<64 {
                guard pid > 1, seen.insert(pid).inserted else { break }
                let process = try system.inspect(pid)
                guard process.owner.uid == getuid() else { break }
                if ["codex", "claude", "opencode", "omp", "pi"].contains(URL(fileURLWithPath: process.executable).lastPathComponent) {
                    return process.owner
                }
                pid = process.parentPID
            }
            throw SimulatorFailure(
                "Run simulator actions from a local coding agent in CtrlX. The socket caller has no supported agent ancestor")
        }

        private func validate(_ owner: SimulatorOwner) throws {
            guard try system.inspect(owner.pid).owner == owner else {
                throw SimulatorFailure("The owning agent process exited or changed identity")
            }
        }

        func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse {
            do {
                guard let peer = request.params["_peerPID"]?.intValue, let pid = Int32(exactly: peer) else {
                    throw SimulatorFailure("Missing kernel socket peer identity")
                }
                guard let coordinator, !closing else { throw SimulatorFailure("Simulator host is unavailable") }
                let parameters = request.params
                if parameters["command"]?.stringValue == "batch" {
                    let result = try await performBatch(parameters, peer: pid, coordinator: coordinator)
                    return JSONRPCResponse(id: request.id, result: result)
                }
                let result = try await performAction(parameters, peer: pid, coordinator: coordinator)
                return JSONRPCResponse(id: request.id, result: result)
            } catch {
                return JSONRPCResponse(id: request.id, error: JSONRPCError(code: "simulator_error", message: error.localizedDescription))
            }
        }

        private func performAction(_ parameters: [String: JSONValue], peer: Int32, coordinator: SimulatorCoordinator,
                                   owner: SimulatorOwner? = nil) async throws -> [String: JSONValue] {
            let command = parameters["command"]?.stringValue ?? ""
            if ["inventory", "config", "resources"].contains(command) {
                guard try system.inspect(peer).owner.uid == getuid() else {
                    throw SimulatorFailure("Simulator caller belongs to another user")
                }
                switch command {
                case "config":
                    let value = try await coordinator.configuration(
                        maximumDevices: parameters["maximumDevices"]?.intValue,
                        memoryReserveMiB: parameters["memoryReserveMiB"]?.intValue,
                        diskReserveMiB: parameters["diskReserveMiB"]?.intValue)
                    return ["configuration": try JSONValue(encoding: value), "open": .int(tabs.count),
                            "opening": .int(opening), "closing": .int(closeTasks.count)]
                case "resources": return ["system": try JSONValue(encoding: await coordinator.resourceSnapshot())]
                default: return try await coordinator.inventory()
                }
            }
            let owner = try owner ?? callingAgent(peer: peer)
            return try await perform(command, parameters: parameters, owner: owner, coordinator: coordinator)
        }

        private func performBatch(_ parameters: [String: JSONValue], peer: Int32,
                                  coordinator: SimulatorCoordinator) async throws -> [String: JSONValue] {
            guard case let .array(values)? = parameters["actions"],
                  (1...SimulatorBatchLimits.maximumActions).contains(values.count),
                  try JSONEncoder().encode(parameters).count <= SimulatorBatchLimits.maximumRequestBytes else {
                throw SimulatorFailure("Batch requires 1...16 actions and at most 64 KB")
            }
            let actions = try values.enumerated().map { index, value -> [String: JSONValue] in
                guard case let .object(action) = value, let command = action["command"]?.stringValue,
                      SimulatorOperation(rawValue: command) != nil,
                      !action.keys.contains(where: { $0.hasPrefix("_") }),
                      action["output"] == nil || command == "record-start" else {
                    throw SimulatorFailure("Batch actions must be simulator operations without authority fields; only record-start accepts output")
                }
                guard command != "screenshot" || index == values.count - 1 else {
                    throw SimulatorFailure("A batch can contain one screenshot, as its final action")
                }
                return action
            }
            let owner = try callingAgent(peer: peer)
            let deadline = ContinuousClock.now.advanced(by: .seconds(SimulatorBatchLimits.admissionSeconds))
            var rows: [JSONValue] = []
            var retainedBytes = 0
            var completed = 0
            var stoppedAt: Int?
            for (index, action) in actions.enumerated() {
                let command = action["command"] ?? .string("")
                do {
                    try Task.checkCancellation()
                    guard !closing, ContinuousClock.now < deadline else {
                        throw SimulatorFailure("Batch stopped before this action: host closed or its 60-second admission deadline elapsed")
                    }
                    try validate(owner)
                    guard try callingAgent(peer: peer) == owner else { throw SimulatorFailure("Batch caller changed its owning agent") }
                    let result = try await performAction(action, peer: peer, coordinator: coordinator, owner: owner)
                    let row: JSONValue = .object(["index": .int(index), "command": command, "ok": .bool(true), "result": .object(result)])
                    let bytes = try JSONEncoder().encode(row).count
                    guard retainedBytes + bytes <= SimulatorBatchLimits.maximumResponseBytes - 65536 else {
                        rows.append(.object(["index": .int(index), "command": command, "ok": .bool(false),
                            "outcome": .string("action-completed-result-omitted"),
                            "error": .object(["code": .string("result_limit"), "message": .string("Batch result limit exceeded; this action completed and was not retried")])]))
                        stoppedAt = index
                        break
                    }
                    rows.append(row)
                    retainedBytes += bytes
                    completed += 1
                } catch {
                    rows.append(.object(["index": .int(index), "command": command, "ok": .bool(false),
                        "error": .object(["code": .string("simulator_error"), "message": .string(error.localizedDescription)])]))
                    stoppedAt = index
                    break
                }
            }
            var result: [String: JSONValue] = ["success": .bool(stoppedAt == nil), "planned": .int(actions.count),
                "completed": .int(completed), "results": .array(rows)]
            if let stoppedAt { result["stoppedAt"] = .int(stoppedAt) }
            return result
        }

        private func perform(_ command: String, parameters: [String: JSONValue], owner: SimulatorOwner, coordinator: SimulatorCoordinator)
            async throws -> [String: JSONValue]
        {
            let traceTap = command == "tap" && CommandLine.arguments.contains("--e2e-test")
            let actionStartedAt = traceTap ? ProcessInfo.processInfo.systemUptime : 0
            try validate(owner)
            if parameters["scale"] != nil, command != "pinch" { throw SimulatorFailure("scale requires pinch") }
            if parameters["seconds"] != nil, command != "record-start" { throw SimulatorFailure("seconds requires record-start") }
            if parameters["output"] != nil, command != "record-start" { throw SimulatorFailure("output requires record-start") }
            if let udid = parameters["udid"] {
                guard ["open", "erase", "delete"].contains(command),
                      let value = udid.stringValue, UUID(uuidString: value) != nil,
                      parameters["device"] == nil, parameters["runtime"] == nil, parameters["deviceType"] == nil else {
                    throw SimulatorFailure("udid requires open, erase or delete and one UUID without device, runtime or deviceType")
                }
            }
            if command == "storage" { return try await coordinator.storage() }
            if command == "erase" || command == "delete" {
                guard let udid = parameters["udid"]?.stringValue,
                      let operation = SimulatorOperation(rawValue: command) else {
                    throw SimulatorFailure("\(command) requires one private device UDID from storage; close the device first")
                }
                return try await coordinator.modifyStorage(operation, udid: udid, owner: owner)
            }
            if let split = parameters["split"], command != "show" || split.boolValue == nil {
                throw SimulatorFailure("split requires show and a boolean value")
            }
            let edge: SimulatorTouchEdge?
            if let value = parameters["edge"] {
                guard command == "swipe", let name = value.stringValue, let parsed = SimulatorTouchEdge(rawValue: name) else {
                    throw SimulatorFailure("edge requires swipe and top, left, bottom or right")
                }
                edge = parsed
            } else { edge = nil }
            if command == "identity" { return ["owner": try JSONValue(encoding: owner)] }
            if command == "devices" {
                return ["devices": .array(try tabs.values.filter { $0.owner == owner }.map { .object(try describe($0)) })]
            }
            if command == "open" {
                let configuration = try await coordinator.configuration()
                guard tabs.count + opening + closeTasks.count < configuration.maximumDevices else {
                    throw SimulatorFailure("The configured simulator limit (\(configuration.maximumDevices)) has been reached")
                }
                guard let profile = SimulatorProfile(rawValue: parameters["profile"]?.stringValue ?? "standard") else {
                    throw SimulatorFailure("Simulator profile must be standard or balanced")
                }
                let requires = Array(Set((parameters["requires"]?.stringValue ?? "").split(separator: ",").map(String.init))).sorted()
                guard requires.count <= 32, requires.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }) else {
                    throw SimulatorFailure("Provide at most 32 required simulator features")
                }
                guard let resolvePane else { throw SimulatorFailure("Simulator pane routing is unavailable") }
                opening += 1
                defer { opening -= 1 }
                var pane: PaneInfo
                do { pane = try await resolvePane(owner.pid) } catch {
                    throw SimulatorFailure(
                        "Cannot route this agent process to a local CtrlX pane: \(error.localizedDescription). For Codex with a shared daemon, launch it using ctrlx simulator run -- codex"
                    )
                }
                let candidates = workspaces.values.filter { $0.acceptsPane(pane) }
                guard let workspace = candidates.first(where: { $0.window?.isVisible == true }) ?? candidates.first else {
                    throw SimulatorFailure("Open this agent's local CtrlX workbench first")
                }
                guard let metal = MTLCreateSystemDefaultDevice() else { throw SimulatorFailure("Metal is unavailable") }
                let view = try SimulatorMetalView(metal: metal)
                let frames = SimulatorFrameMailbox { [weak view] frame in
                    guard let view else {
                        frame.finish()
                        return
                    }
                    view.receive(frame)
                }
                let handle = try await coordinator.open(
                    runtime: parameters["runtime"]?.stringValue, deviceType: parameters["deviceType"]?.stringValue,
                    udid: parameters["udid"]?.stringValue,
                    profile: profile, requires: requires,
                    frames: { frame in frames.receive(frame) },
                    errors: { [weak view] message in
                        Task { @MainActor in view?.onError(message) }
                    })
                do {
                    pane = try await resolvePane(owner.pid)
                    try validate(owner)
                } catch {
                    try await coordinator.close(handle, shutdown: true)
                    throw error
                }
                guard !closing, workspaces[workspace.id] === workspace else {
                    try await coordinator.close(handle, shutdown: true)
                    throw SimulatorFailure("The source workbench closed while the simulator was booting")
                }
                let state = SimulatorTabState(
                    handle: handle, owner: owner, sourcePane: pane, workspaceID: workspace.id, view: view, service: self)
                tabs[state.id] = state
                view.onTouch = { [weak self, weak state] point, phase in
                    guard let self, let state else { return }
                    self.manualTouch(state, point: point, phase: phase, receivedAt: state.view.inputEventReceivedAt)
                }
                view.onVisibility = { [weak self, weak state] visible in
                    guard let self, let state else { return }
                    self.visibility(state, visible: visible)
                }
                view.onKey = { [weak self, weak state] usage, down in
                    guard let self, let state else { return }
                    self.manualKey(state, usage: usage, down: down)
                }
                view.onCancelInput = { [weak self, weak state] in
                    guard let self, let state else { return }
                    self.cancelManualInput(state)
                }
                view.onError = { [weak state] message in
                    guard let state else { return }
                    state.error = message
                    state.writer = nil
                    state.generation += 1
                }
                workspace.onCreate(state)
                workspace.onSelect(state, false)
                guard !state.isClosed else {
                    await closeTasks[state.id]?.value
                    throw SimulatorFailure("The source workbench closed while the simulator tab was being created")
                }
                return try describe(state)
            }
            guard let rawID = parameters["device"]?.stringValue, let id = UUID(uuidString: rawID),
                let state = tabs[id], state.owner == owner, !state.isClosed
            else { throw SimulatorFailure("Device does not belong to this agent process") }
            state.markActivity()
            if command == "status" {
                if parameters["resetMeasurements"]?.boolValue == true {
                    guard CommandLine.arguments.contains("--e2e-test") else {
                        throw SimulatorFailure("Measurement reset requires an isolated --e2e-test app")
                    }
                    state.view.resetMeasurements()
                }
                return try describe(state)
            }
            if command == "show" {
                workspaces[state.workspaceID]?.onSelect(state, parameters["split"]?.boolValue == true)
                return try describe(state)
            }
            if command == "close" {
                close(state)
                await closeTasks[state.id]?.value
                if let error = state.error { throw SimulatorFailure("Tab closed; device cleanup failed: \(error)") }
                return ["closed": .bool(true)]
            }
            if command == "screenshot" { return try await coordinator.screenshot(state.handle) }
            if command == "record-status" { return await coordinator.recordingStatus(state.handle) }
            if command == "record-stop" {
                let result = await coordinator.stopRecording(state.handle)
                if let error = result["error"]?.stringValue { throw SimulatorFailure(error) }
                return result
            }
            if command == "metrics" { return try await coordinator.metrics(state.handle) }
            if command == "logs" {
                guard let bundle = parameters["bundle"]?.stringValue else { throw SimulatorFailure("logs requires a bundle identifier") }
                let request = try SimulatorLogRequest(bundle: bundle, lastSeconds: parameters["lastSeconds"]?.intValue ?? 30,
                    maximumBytes: parameters["maximumBytes"]?.intValue ?? 65536)
                return try await coordinator.logs(state.handle, request: request)
            }
            if command == "crashes" {
                guard let bundle = parameters["bundle"]?.stringValue else { throw SimulatorFailure("crashes requires a bundle identifier") }
                let request = try SimulatorCrashRequest(bundle: bundle, lastSeconds: parameters["lastSeconds"]?.intValue ?? 3600,
                    limit: parameters["limit"]?.intValue ?? 5, maximumBytes: parameters["maximumBytes"]?.intValue ?? 65536)
                return try await coordinator.crashes(state.handle, request: request)
            }
            if command == "snapshot" {
                return try await observe(state, coordinator: coordinator, limit: parameters["limit"]?.intValue ?? 200).snapshot
            }
            if command == "wait" {
                guard parameters["ref"] == nil else { throw SimulatorFailure("wait requires a semantic selector rather than a snapshot reference") }
                let query = try elementQuery(parameters)
                let wanted = parameters["state"]?.stringValue ?? "visible"
                let timeout = parameters["timeoutMs"]?.intValue ?? 5000
                let limit = parameters["limit"]?.intValue ?? 200
                guard ["visible", "absent"].contains(wanted), (1...60000).contains(timeout) else {
                    throw SimulatorFailure("wait accepts visible or absent and a timeout of 1...60000 ms")
                }
                guard (1...1000).contains(limit) else { throw SimulatorFailure("Snapshot limit must be 1...1000") }
                let start = ContinuousClock.now
                let deadline = start.advanced(by: .milliseconds(timeout))
                var partial = false
                var lastError: String?
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    try validate(owner)
                    guard !state.isClosed else { throw SimulatorFailure("The simulator closed while waiting") }
                    do {
                        let observed = try await observe(state, coordinator: coordinator,
                            limit: limit, deadline: deadline)
                        partial = observed.snapshot["partial"]?.boolValue == true
                        lastError = nil
                        guard let geometry = state.observation?.geometry else { throw SimulatorFailure("The observation geometry is unavailable") }
                        let matches = observed.elements.filter { query.matches($0) }
                        let visible = matches.contains { $0.isVisible(in: geometry) }
                        if ContinuousClock.now <= deadline && (wanted == "visible" ? visible : matches.isEmpty && !partial) {
                            return ["matched": .bool(true), "state": .string(wanted), "snapshot": .object(observed.snapshot)]
                        }
                    } catch {
                        try Task.checkCancellation()
                        guard !state.isClosed else { throw SimulatorFailure("The simulator closed while waiting") }
                        lastError = error.localizedDescription
                    }
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    if remaining > .zero { try await Task.sleep(for: min(.milliseconds(100), remaining)) }
                }
                if let lastError { throw SimulatorFailure("Wait timed out without a valid observation: \(lastError)") }
                throw SimulatorFailure(partial ? "Wait timed out; an incomplete AX tree cannot prove absence" : "Wait timed out before the requested element state appeared")
            }
            if command == "claim" {
                try await claimWriter(state) {
                    _ = try await state.handle.worker.request(["command": .string("cancel")])
                }
                return try describe(state)
            }
            guard state.writer == owner else {
                throw SimulatorFailure("Human control revoked the agent writer. Use claim explicitly before continuing")
            }
            guard !state.writing else { throw SimulatorFailure("Another operation is in progress on this device; no action was sent") }
            state.writing = true
            defer { state.writing = false }
            let generation = state.generation
            func checkWriter() throws {
                try validate(owner)
                guard !state.isClosed, state.writer == owner, state.generation == generation else {
                    throw SimulatorFailure("Simulator operation cancelled by human takeover or tab closure")
                }
            }
            do {
                var result: [String: JSONValue] = ["accepted": .bool(true)]
                switch command {
                case "record-start":
                    guard let output = parameters["output"]?.stringValue,
                          parameters["seconds"] == nil || parameters["seconds"]?.intValue != nil else {
                        throw SimulatorFailure("record-start requires an output path and an integer duration")
                    }
                    let options = try SimulatorRecordingOptions(output: output, seconds: parameters["seconds"]?.intValue ?? 60)
                    result = try await coordinator.startRecording(state.handle, options: options)
                    do { try checkWriter() } catch {
                        _ = await coordinator.stopRecording(state.handle)
                        throw error
                    }
                case "display-mode":
                    guard let mode = SimulatorDisplayMode(rawValue: parameters["mode"]?.stringValue ?? "") else {
                        throw SimulatorFailure("display-mode requires synchronized or low-latency")
                    }
                    state.displayMode = mode
                    return try describe(state)
                case "install":
                    state.observation = nil
                    guard let path = parameters["app"]?.stringValue else {
                        throw SimulatorFailure("install requires an absolute simulator .app path")
                    }
                    try await coordinator.install(state.handle, app: path)
                case "uninstall":
                    guard let bundle = parameters["bundle"]?.stringValue else { throw SimulatorFailure("uninstall requires a bundle identifier") }
                    state.observation = nil
                    try await coordinator.uninstall(state.handle, bundle: bundle)
                case "launch", "terminate":
                    state.observation = nil
                    guard let bundle = parameters["bundle"]?.stringValue, !bundle.isEmpty, bundle.utf8.count <= 255, !bundle.hasPrefix("-")
                    else { throw SimulatorFailure("Provide a bundle identifier") }
                    let activationTimeoutMs = parameters["timeoutMs"]?.intValue ?? 30000
                    if command == "launch" {
                        guard (1...60000).contains(activationTimeoutMs) else {
                            throw SimulatorFailure("launch accepts a timeout of 1...60000 ms")
                        }
                        // Inspector startup has its own budget; the Scene deadline starts after launch.
                        try await coordinator.prepareInspector(state.handle)
                        try checkWriter()
                    }
                    let launched = try await coordinator.simctl([command, state.handle.udid, bundle], timeout: command == "launch" ? 120 : 30)
                    if command == "launch" {
                        let activationTrace = CommandLine.arguments.contains("--e2e-test")
                            && CommandLine.arguments.contains("--e2e-simulator-activation-trace")
                        let processID = try SimulatorCoordinator.launchedProcessID(launched.stdout, bundle: bundle)
                        let deadline = ContinuousClock.now.advanced(by: .milliseconds(activationTimeoutMs))
                        var confirmed = false
                        if activationTrace {
                            FileHandle.standardError.write(Data(String(format:
                                "SimulatorActivation stage=service-begin device=%@ pid=%d at=%.9f\n",
                                state.handle.udid, processID, ProcessInfo.processInfo.systemUptime).utf8))
                        }
                        defer {
                            if activationTrace {
                                FileHandle.standardError.write(Data(String(format:
                                    "SimulatorActivation stage=service-end device=%@ pid=%d at=%.9f confirmed=%d\n",
                                    state.handle.udid, processID, ProcessInfo.processInfo.systemUptime, confirmed ? 1 : 0).utf8))
                            }
                        }
                        try checkWriter()
                        try await coordinator.waitForApplicationActive(state.handle, processID: processID, owner: owner, deadline: deadline)
                        try checkWriter()
                        confirmed = true
                        result["applicationPID"] = .int(Int(processID))
                        result["active"] = .bool(true)
                    }
                case "open-url":
                    state.observation = nil
                    guard let text = parameters["url"]?.stringValue, text.utf8.count <= 8192, let url = URL(string: text), url.scheme != nil
                    else { throw SimulatorFailure("Provide an absolute URL") }
                    _ = try await coordinator.simctl(["openurl", state.handle.udid, url.absoluteString])
                case "location":
                    if let clear = parameters["clear"], clear.boolValue == nil { throw SimulatorFailure("clear must be a boolean") }
                    if parameters["clear"]?.boolValue == true {
                        guard parameters["latitude"] == nil, parameters["longitude"] == nil else {
                            throw SimulatorFailure("Choose coordinates or clear")
                        }
                        _ = try await coordinator.simctl(["location", state.handle.udid, "clear"])
                    } else {
                        func number(_ name: String) -> Double? {
                            switch parameters[name] {
                            case let .double(value): return value
                            case let .int(value): return Double(value)
                            default: return nil
                            }
                        }
                        guard let latitude = number("latitude"), let longitude = number("longitude") else {
                            throw SimulatorFailure("location requires both coordinates or clear")
                        }
                        let location = try SimulatorLocation(latitude: latitude, longitude: longitude)
                        _ = try await coordinator.simctl(["location", state.handle.udid, "set", location.coordinate])
                    }
                case "appearance":
                    let arguments = ["ui", state.handle.udid, "appearance"]
                    if let value = parameters["style"] {
                        guard let raw = value.stringValue, let style = SimulatorAppearance(rawValue: raw) else {
                            throw SimulatorFailure("appearance accepts light or dark")
                        }
                        state.observation = nil
                        _ = try await coordinator.simctl(arguments + [style.rawValue])
                        try checkWriter()
                    }
                    let style = try await coordinator.simctl(arguments).stdoutString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard SimulatorAppearance(rawValue: style) != nil else { throw SimulatorFailure("Appearance unavailable: \(style)") }
                    result["style"] = .string(style)
                case "privacy":
                    guard let rawAction = parameters["action"]?.stringValue, let action = SimulatorPrivacyAction(rawValue: rawAction),
                          let rawService = parameters["service"]?.stringValue, let service = SimulatorPrivacyService(rawValue: rawService),
                          let bundle = parameters["bundle"]?.stringValue else {
                        throw SimulatorFailure("privacy requires an action, permission service and bundle identifier")
                    }
                    let request = try SimulatorPrivacyRequest(action: action, service: service, bundle: bundle)
                    state.observation = nil
                    _ = try await coordinator.simctl(["privacy", state.handle.udid, request.action.rawValue, request.service.rawValue, request.bundle])
                    result["mayTerminateApp"] = .bool(true)
                case "push":
                    guard let bundle = parameters["bundle"]?.stringValue, let payload = parameters["payload"]?.stringValue else {
                        throw SimulatorFailure("push requires a bundle identifier and JSON payload")
                    }
                    let notification = try SimulatorPushNotification(bundle: bundle, payload: Data(payload.utf8))
                    state.observation = nil
                    try await coordinator.push(state.handle, notification: notification)
                case "rotate":
                    let orientation: Int
                    switch parameters["orientation"]?.stringValue {
                    case "portrait": orientation = 1
                    case "portrait-upside-down": orientation = 2
                    case "landscape-right": orientation = 3
                    case "landscape-left": orientation = 4
                    default: throw SimulatorFailure("rotate requires portrait, portrait-upside-down, landscape-left or landscape-right")
                    }
                    state.observation = nil
                    let initialGeometry = try await coordinator.geometry(state.handle)
                    try checkWriter()
                    let settlingDuration: Duration
                    switch (initialGeometry.orientation, orientation) {
                    case (1, 2), (2, 1), (3, 4), (4, 3):
                        settlingDuration = .milliseconds(1250)
                    default:
                        settlingDuration = .milliseconds(750)
                    }
                    _ = try await state.handle.worker.request(["command": .string("rotate"), "orientation": .int(orientation)])
                    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                    var matchedGeometry: SimulatorGeometry?
                    var settledAt: ContinuousClock.Instant?
                    while ContinuousClock.now < deadline {
                        try checkWriter()
                        let parts = ContinuousClock.now.duration(to: deadline).components
                        let remaining = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                        guard remaining >= 0.001 else { break }
                        let geometry: SimulatorGeometry
                        do {
                            geometry = try await coordinator.geometry(state.handle, timeoutSeconds: remaining)
                        } catch let failure as SimulatorFailure where failure == SimulatorFailure("The simulator display is not ready") {
                            // Rotation invalidates geometry before CoreSimulator publishes its replacement.
                            matchedGeometry = nil
                            settledAt = nil
                            let delay = ContinuousClock.now.duration(to: deadline)
                            if delay > .zero { try await Task.sleep(for: min(.milliseconds(50), delay)) }
                            continue
                        }
                        if geometry.orientation == orientation {
                            if matchedGeometry != geometry {
                                matchedGeometry = geometry
                                // Geometry precedes input readiness; half turns after
                                // returning from Home need a longer stable interval.
                                settledAt = ContinuousClock.now.advanced(by: settlingDuration)
                            }
                            if let settledAt, ContinuousClock.now >= settledAt {
                                return ["accepted": .bool(true), "geometry": try JSONValue(encoding: geometry)]
                            }
                        } else {
                            matchedGeometry = nil
                            settledAt = nil
                        }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    throw SimulatorFailure("Orientation event was sent, but the interface did not rotate; the app may lock its orientation")
                case "tap", "swipe", "long-press", "drag", "pinch":
                    let selected: SimulatorPoint?
                    if parameters["ref"] != nil || parameters["identifier"] != nil || parameters["label"] != nil || parameters["role"] != nil {
                        guard command != "pinch", parameters["x"] == nil, parameters["y"] == nil else {
                            throw SimulatorFailure("Choose an element selector or start coordinates")
                        }
                        selected = try await resolveElement(parameters, state: state, coordinator: coordinator)
                    } else { selected = nil }
                    let observedGeometry = traceTap ? state.observation?.geometry : nil
                    let geometryRequestedAt = traceTap ? ProcessInfo.processInfo.systemUptime : 0
                    let geometry = try await coordinator.geometry(state.handle)
                    let geometryReadyAt = traceTap ? ProcessInfo.processInfo.systemUptime : 0
                    try checkWriter()
                    let nativeEdge = try edge?.digitizerValue(in: geometry) ?? 0
                    func number(_ name: String) throws -> Double {
                        switch parameters[name] {
                        case .double(let value): return value
                        case .int(let value): return Double(value)
                        default: throw SimulatorFailure("Missing coordinate \(name)")
                        }
                    }
                    let duration = parameters["durationMs"]?.intValue ?? (command == "tap" ? 20 : command == "long-press" ? 650 : command == "pinch" ? 500 : 300)
                    guard (20...5000).contains(duration) else { throw SimulatorFailure("Gesture duration must be 20...5000 ms") }
                    let first: [SimulatorPoint], last: [SimulatorPoint]
                    if command == "pinch" {
                        guard parameters["endX"] == nil, parameters["endY"] == nil, parameters["holdMs"] == nil,
                              parameters["durationMs"] == nil || parameters["durationMs"]?.intValue != nil else {
                            throw SimulatorFailure("pinch accepts a center, scale and integer duration, without endpoint or hold options")
                        }
                        let gesture = try SimulatorPinch(center: SimulatorPoint(x: number("x"), y: number("y")),
                            scale: number("scale"), durationMs: duration)
                        (first, last) = try gesture.contacts(in: geometry)
                    } else {
                        first = [try geometry.normalizedDevicePoint(selected ?? SimulatorPoint(x: number("x"), y: number("y")))]
                        last = command == "swipe" || command == "drag"
                            ? [try geometry.normalizedDevicePoint(SimulatorPoint(x: number("endX"), y: number("endY")))] : first
                    }
                    let hold = parameters["holdMs"]?.intValue ?? (command == "drag" ? 500 : 0)
                    guard (0...5000).contains(hold) else { throw SimulatorFailure("Gesture hold must be 0...5000 ms") }
                    state.observation = nil
                    let downRequestedAt = traceTap ? ProcessInfo.processInfo.systemUptime : 0
                    try await touch(state, points: first, phase: 0, geometry: geometry, edge: nativeEdge)
                    let downReturnedAt = traceTap ? ProcessInfo.processInfo.systemUptime : 0
                    if hold > 0 { try await Task.sleep(for: .milliseconds(hold)); try checkWriter() }
                    let steps = command == "tap" || command == "long-press" ? 1 : max(2, duration / 16)
                    let movementStarted = ContinuousClock.now
                    for index in 1...steps {
                        try await Task.sleep(
                            until: movementStarted.advanced(by: .milliseconds(duration * index / steps)), clock: .continuous)
                        try checkWriter()
                        let fraction = Double(index) / Double(steps)
                        let points = zip(first, last).map { start, end in
                            SimulatorPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
                        }
                        try await touch(state, points: points, phase: steps == 1 ? 2 : 1, geometry: geometry, edge: nativeEdge)
                    }
                    if traceTap {
                        result["inputTiming"] = .object([
                            "actionStartedAt": .double(actionStartedAt),
                            "geometryRequestedAt": .double(geometryRequestedAt),
                            "geometryReadyAt": .double(geometryReadyAt),
                            "observedGeometryMatched": .bool(observedGeometry == geometry),
                            "downRequestedAt": .double(downRequestedAt),
                            "downSubmittedAt": .double(state.inputDownSubmittedAt),
                            "downReturnedAt": .double(downReturnedAt),
                            "upSubmittedAt": .double(state.inputUpSubmittedAt),
                            "upReturnedAt": .double(ProcessInfo.processInfo.systemUptime),
                        ])
                    }
                    if steps > 1 {
                        // Repeat the endpoint within this gesture before lifting.
                        try await Task.sleep(for: .milliseconds(16))
                        try checkWriter()
                        try await touch(state, points: last, phase: 1, geometry: geometry, edge: nativeEdge)
                        try await Task.sleep(for: .milliseconds(16))
                        try checkWriter()
                        try await touch(state, points: last, phase: 2, geometry: geometry, edge: nativeEdge)
                    }
                case "key":
                    guard let usage = parameters["usage"]?.intValue else {
                        throw SimulatorFailure("key requires a USB HID keyboard usage (4...231)")
                    }
                    var modifiers: [String] = []
                    if let value = parameters["modifiers"] {
                        guard case .array(let values) = value else { throw SimulatorFailure("modifiers must be an array of names") }
                        modifiers = try values.map {
                            guard let name = $0.stringValue else { throw SimulatorFailure("modifiers must be an array of names") }
                            return name
                        }
                    }
                    let press = try SimulatorKeyPress(usage: usage, modifiers: modifiers)
                    for event in press.events {
                        try checkWriter()
                        _ = try await state.handle.worker.request(["command": .string("key"), "usage": .int(event.usage), "down": .bool(event.down)])
                    }
                case "button":
                    let usage: Int
                    switch parameters["button"]?.stringValue {
                    case "home": usage = 0x40
                    case "lock": usage = 0x30
                    case "volume-up": usage = 0xe9
                    case "volume-down": usage = 0xea
                    default: throw SimulatorFailure("button accepts home, lock, volume-up, volume-down")
                    }
                    _ = try await state.handle.worker.request(["command": .string("button"), "usage": .int(usage), "down": .bool(true)])
                    try checkWriter()
                    _ = try await state.handle.worker.request(["command": .string("button"), "usage": .int(usage), "down": .bool(false)])
                case "paste":
                    guard let text = parameters["text"]?.stringValue, text.utf8.count <= 16000 else {
                        throw SimulatorFailure("paste accepts UTF-8 text up to 16 KB")
                    }
                    if let mode = parameters["viaMenu"], mode.boolValue == nil {
                        throw SimulatorFailure("viaMenu must be a boolean")
                    }
                    if parameters["viaMenu"]?.boolValue == true {
                        try await pasteViaMenu(
                            text, parameters: parameters, state: state, coordinator: coordinator, checkWriter: checkWriter)
                        break
                    }
                    try await coordinator.paste(state.handle, text: text)
                    try checkWriter()
                    for (usage, down) in [(227, true), (25, true), (25, false), (227, false)] {
                        try checkWriter()
                        _ = try await state.handle.worker.request(["command": .string("key"), "usage": .int(usage), "down": .bool(down)])
                    }
                default:
                    throw SimulatorFailure("Unsupported simulator operation: \(command)")
                }
                try checkWriter()
                return result
            } catch {
                if state.generation == generation, !state.isClosed {
                    do { _ = try await state.handle.worker.request(["command": .string("cancel")]) } catch {
                        state.error = "Input cancellation failed: \(error.localizedDescription)"
                    }
                }
                throw error
            }
        }

        private func elementQuery(_ parameters: [String: JSONValue]) throws -> SimulatorElementQuery {
            try SimulatorElementQuery(identifier: parameters["identifier"]?.stringValue,
                label: parameters["label"]?.stringValue, role: parameters["role"]?.stringValue)
        }

        private func observe(_ state: SimulatorTabState, coordinator: SimulatorCoordinator, limit: Int,
            deadline: ContinuousClock.Instant? = nil) async throws
            -> (snapshot: [String: JSONValue], elements: [SimulatorElement]) {
            func budget(_ maximum: Double) throws -> Double {
                guard let deadline else { return maximum }
                let parts = ContinuousClock.now.duration(to: deadline).components
                let remaining = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                guard remaining >= 0.001 else { throw SimulatorFailure("Observation deadline expired") }
                return min(maximum, remaining)
            }
            let generation = state.generation
            let before = try await coordinator.geometry(state.handle, timeoutSeconds: budget(10))
            var snapshot = try await coordinator.snapshot(state.handle, limit: limit, deadline: deadline)
            guard snapshot["partial"]?.boolValue != nil else {
                state.observation = nil
                throw SimulatorFailure("AX did not report a boolean completeness flag")
            }
            let after = try await coordinator.geometry(state.handle, timeoutSeconds: budget(10))
            guard before == after, !state.isClosed, generation == state.generation else {
                state.observation = nil
                throw SimulatorFailure("Geometry or control changed while observing; observe again")
            }
            guard let pid = snapshot["applicationPID"]?.intValue, let processID = Int32(exactly: pid), processID > 0,
                case .array(let nodes) = snapshot["nodes"] else {
                throw SimulatorFailure("AX did not report an application identity or element tree")
            }
            let application = try system.inspect(processID).owner
            let elements = try JSONDecoder().decode([SimulatorElement].self, from: JSONEncoder().encode(nodes))
            let observationID = UUID().uuidString
            var references: [String: SimulatorElement] = [:]
            snapshot["nodes"] = .array(nodes.enumerated().map { index, value in
                guard var node = value.objectValue else { return value }
                let reference = "@\(observationID):\(index)"
                references[reference] = elements[index]
                node["ref"] = .string(reference)
                return .object(node)
            })
            state.observation = SimulatorObservation(generation: generation, geometry: after, application: application, references: references)
            snapshot["device"] = .string(state.id.uuidString)
            snapshot["geometry"] = try JSONValue(encoding: after)
            snapshot["observation"] = .string(observationID)
            return (snapshot, elements)
        }

        private func resolveElement(_ parameters: [String: JSONValue], state: SimulatorTabState, coordinator: SimulatorCoordinator) async throws
            -> SimulatorPoint {
            let element = try await resolveTarget(parameters, state: state, coordinator: coordinator)
            guard let geometry = state.observation?.geometry, let point = element.interactionPoint(in: geometry) else {
                throw SimulatorFailure("AX did not report a visible interaction point for the target")
            }
            return point
        }

        private func resolveTarget(_ parameters: [String: JSONValue], state: SimulatorTabState, coordinator: SimulatorCoordinator)
            async throws
            -> SimulatorElement
        {
            let reference = parameters["ref"]?.stringValue
            let previous = state.observation
            let target: SimulatorElement?
            if let reference {
                guard parameters["identifier"] == nil, parameters["label"] == nil, parameters["role"] == nil,
                    let previous, previous.generation == state.generation, let element = previous.references[reference] else {
                    throw SimulatorFailure("Stale or conflicting element reference; take a fresh snapshot")
                }
                target = element
            } else { target = nil }
            let observed = try await observe(state, coordinator: coordinator, limit: 1000)
            guard observed.snapshot["partial"]?.boolValue == false else {
                let reason = observed.snapshot["partialReason"]?.stringValue.map { " (\($0))" } ?? ""
                throw SimulatorFailure("An incomplete AX tree cannot prove that the target is unique\(reason)")
            }
            let matches: [SimulatorElement]
            if let target, let previous {
                guard let current = state.observation, current.application == previous.application, current.geometry == previous.geometry else {
                    throw SimulatorFailure("The application or geometry changed since the referenced snapshot")
                }
                matches = observed.elements.filter { $0.hasSameIdentity(as: target) }
            } else {
                let query = try elementQuery(parameters)
                matches = observed.elements.filter { query.matches($0) }
            }
            guard matches.count == 1, let element = matches.first, let geometry = state.observation?.geometry,
                element.interactionPoint(in: geometry) != nil
            else {
                throw SimulatorFailure(matches.isEmpty ? "The target element disappeared" : "The target element is ambiguous or not visible")
            }
            return element
        }

        private func pasteViaMenu(
            _ text: String, parameters: [String: JSONValue], state: SimulatorTabState,
            coordinator: SimulatorCoordinator, checkWriter: @MainActor () throws -> Void
        ) async throws {
            let hasSelector = ["ref", "identifier", "label", "role"].contains { parameters[$0] != nil }
            let target: SimulatorElement?
            if hasSelector {
                guard parameters["x"] == nil, parameters["y"] == nil else {
                    throw SimulatorFailure("Choose an element target or coordinates for menu paste")
                }
                target = try await resolveTarget(parameters, state: state, coordinator: coordinator)
                guard let role = target?.role, ["AXTextField", "AXTextArea"].contains(role) else {
                    throw SimulatorFailure("Menu paste requires an editable text target; use coordinates when AX omits the field")
                }
            } else {
                target = nil
                _ = try await observe(state, coordinator: coordinator, limit: 1000)
            }
            guard let observation = state.observation else {
                throw SimulatorFailure("Menu paste requires a current application observation")
            }
            let geometry = observation.geometry
            func coordinate(_ name: String) throws -> Double {
                switch parameters[name] {
                case .double(let value): return value
                case .int(let value): return Double(value)
                default: throw SimulatorFailure("Menu paste requires an element target or both x and y coordinates")
                }
            }
            let point: SimulatorPoint
            if let target, let center = target.interactionPoint(in: geometry) {
                point = center
            } else {
                point = try SimulatorPoint(x: coordinate("x"), y: coordinate("y"))
            }
            func press(_ point: SimulatorPoint, duration: Duration) async throws {
                let normalized = try geometry.normalizedDevicePoint(point)
                try checkWriter()
                state.observation = nil
                try await touch(state, point: normalized, phase: 0, geometry: geometry)
                try await Task.sleep(for: duration)
                try checkWriter()
                try await touch(state, point: normalized, phase: 2, geometry: geometry)
            }
            try await press(point, duration: .milliseconds(50))
            try checkWriter()
            try await coordinator.paste(state.handle, text: text)
            try checkWriter()
            let refreshed = try await observe(state, coordinator: coordinator, limit: 1000)
            guard let current = state.observation, current.application == observation.application, current.geometry == geometry else {
                throw SimulatorFailure("The application or geometry changed before the paste menu was opened")
            }
            let menuTarget: SimulatorPoint
            if let target {
                let matches = refreshed.elements.filter { $0.hasSameIdentity(as: target) }
                guard refreshed.snapshot["partial"]?.boolValue == false, matches.count == 1,
                    let center = matches.first?.interactionPoint(in: geometry)
                else {
                    throw SimulatorFailure("The menu paste target disappeared, became ambiguous or could not be observed completely")
                }
                menuTarget = center
            } else {
                menuTarget = point
            }
            try await press(menuTarget, duration: .milliseconds(800))
            let labels: Set<String> = ["Paste", "粘贴", "貼上", "ペースト", "붙여넣기", "Einfügen", "Coller", "Pegar", "Incolla"]
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                try checkWriter()
                let menu: (snapshot: [String: JSONValue], elements: [SimulatorElement])
                do {
                    menu = try await observe(state, coordinator: coordinator, limit: 1000, deadline: deadline)
                } catch {
                    throw SimulatorFailure(
                        "The clipboard was written, but the Paste menu could not be observed: \(error.localizedDescription). No Paste tap was sent"
                    )
                }
                try checkWriter()
                guard let current = state.observation, current.application == observation.application, current.geometry == geometry else {
                    throw SimulatorFailure("The application or geometry changed while observing the paste menu")
                }
                if menu.snapshot["partial"]?.boolValue == false {
                    let matches = menu.elements.filter { element in
                        labels.contains(element.label ?? element.title ?? "") && element.interactionPoint(in: geometry) != nil
                    }
                    guard matches.count <= 1 else { throw SimulatorFailure("The iOS Paste menu item is ambiguous; no Paste tap was sent") }
                    if let center = matches.first?.interactionPoint(in: geometry) {
                        try await press(center, duration: .milliseconds(50))
                        return
                    }
                }
                let remaining = ContinuousClock.now.duration(to: deadline)
                if remaining > .zero { try await Task.sleep(for: min(.milliseconds(120), remaining)) }
            }
            throw SimulatorFailure("The iOS Paste menu did not appear; the clipboard was written but no Paste tap was sent")
        }

        private func describe(_ state: SimulatorTabState) throws -> [String: JSONValue] {
            var result: [String: JSONValue] = [
                "device": .string(state.id.uuidString), "udid": .string(state.handle.udid), "name": .string(state.handle.name),
                "runtime": .string(state.handle.runtime), "writer": .string(state.writer == nil ? "human" : "agent"),
                "profile": .string(state.handle.profile.rawValue),
                "displayMode": .string(state.displayMode.rawValue),
                "requiredFeatures": .array(state.handle.requiredFeatures.map(JSONValue.string)),
                "geometry": try state.view.geometry.map { try JSONValue(encoding: $0) } ?? .null,
                "error": state.error.map(JSONValue.string) ?? .null,
            ]
            if CommandLine.arguments.contains("--e2e-test") {
                result["inputMeasurements"] = .object([
                    "downSubmittedAt": .double(state.inputDownSubmittedAt),
                    "upSubmittedAt": .double(state.inputUpSubmittedAt),
                    "lastSubmissionMs": .double(state.lastInputSubmissionMs),
                    "manualDownReceivedAt": .double(state.manualDownReceivedAt),
                    "manualDownEnqueuedAt": .double(state.manualDownEnqueuedAt),
                    "manualUpReceivedAt": .double(state.manualUpReceivedAt),
                    "manualUpEnqueuedAt": .double(state.manualUpEnqueuedAt),
                    "manualDownStages": .object(state.manualDownStages.mapValues(JSONValue.double)),
                    "manualUpStages": .object(state.manualUpStages.mapValues(JSONValue.double)),
                ])
                let steadyPresentation = state.view.steadyPresentationObservable
                let sample = state.view.measurements.read()
                let sampledAt = CACurrentMediaTime()
                let latencies = sample.milliseconds.sorted()
                let drawableWaits = sample.drawableWaits.sorted()
                var presentation: [String: JSONValue] = [
                    "scope": .string(steadyPresentation ? "steady-metal" : "metal-bootstrap-only"),
                    "presentedFrames": .int(sample.frames),
                    "sourceSequence": .int(Int(sample.sourceSequence)),
                    "firstPresentedAt": .double(sample.firstTime),
                    "lastPresentedAt": .double(sample.lastTime),
                    "startedAt": .double(sample.startedAt),
                    "sampledAt": .double(sampledAt),
                    "elapsedSeconds": .double(sample.elapsed(at: sampledAt)),
                    "uniqueFPS": .double(sample.uniqueFPS(at: sampledAt)),
                    "sourceToPresentP95Ms": .double(
                        latencies.isEmpty ? 0 : latencies[min(latencies.count - 1, Int(Double(latencies.count) * 0.95))]),
                    "sourceToPresentP99Ms": .double(
                        latencies.isEmpty ? 0 : latencies[min(latencies.count - 1, Int(Double(latencies.count) * 0.99))]),
                    "drawableWaitP95Ms": .double(
                        drawableWaits.isEmpty ? 0 : drawableWaits[min(drawableWaits.count - 1, Int(Double(drawableWaits.count) * 0.95))]),
                    "drawableWaitMaxMs": .double(drawableWaits.last ?? 0),
                    "copyStageSamples": .int(sample.copyRecords),
                    "renderedDrawableSamples": .int(sample.renderRecords),
                ]
                if !steadyPresentation {
                    for key in ["uniqueFPS", "sourceToPresentP95Ms", "sourceToPresentP99Ms"] {
                        presentation[key] = .null
                    }
                }
                result["measurements"] = .object(presentation)
                result["stageP95Ms"] = .array(sample.stages.map { stage in
                    let values = stage.sorted()
                    return .double(values.isEmpty ? 0 : values[min(values.count - 1, Int(Double(values.count) * 0.95))])
                })
                result["copyStageP95Ms"] = .array(sample.copyStages.map { stage in
                    let values = stage.sorted()
                    return .double(values.isEmpty ? 0 : values[min(values.count - 1, Int(Double(values.count) * 0.95))])
                })
                result["renderStageP95Ms"] = .array(sample.renderStages.map { stage in
                    let values = stage.sorted()
                    return .double(values.isEmpty ? 0 : values[min(values.count - 1, Int(Double(values.count) * 0.95))])
                })
                if !steadyPresentation {
                    for key in ["stageP95Ms", "copyStageP95Ms", "renderStageP95Ms"] { result[key] = .null }
                }
                let render = state.view.renderState
                let display = state.view.displayCondition
                let counters = render.counters
                let firstInvalidGeometry = try render.firstInvalidGeometry.map { try JSONValue(encoding: $0) } ?? .null
                result["renderState"] = .object([
                    "renderer": .string(render.renderer),
                    "steadyPresentationObservable": .bool(render.steadyPresentationObservable),
                    "contentsVisible": .bool(render.contentsVisible),
                    "contentsSubmissions": .int(counters.contentsSubmissions),
                    "firstInvalidGeometry": firstInvalidGeometry,
                    "initialInFlight": .int(counters.initialInFlight),
                    "receivedFrames": .int(counters.receivedFrames),
                    "replacedPendingFrames": .int(counters.replacedPendingFrames),
                    "drawGateBlocked": .int(counters.drawGateBlocked),
                    "drawableUnavailable": .int(counters.drawableUnavailable),
                    "submittedDrawables": .int(counters.submittedDrawables),
                    "presentedCallbacks": .int(counters.presentedCallbacks),
                    "discardedDrawables": .int(counters.discardedDrawables),
                    "invalidatedDrawables": .int(counters.invalidatedDrawables),
                    "staleCallbacks": .int(counters.staleCallbacks),
                    "maximumInFlight": .int(counters.maximumInFlight),
                    "layoutCalls": .int(counters.layoutCalls),
                    "inFlight": .int(render.inFlight), "generation": .int(render.generation),
                    "hasPendingFrame": .bool(render.hasPendingFrame),
                    "hasCurrentFrame": .bool(render.hasCurrentFrame), "redrawNeeded": .bool(render.redrawNeeded),
                    "maximumDrawableCount": .int(render.maximumDrawableCount),
                    "presentsWithTransaction": .bool(render.presentsWithTransaction),
                    "layerOpaque": .bool(render.layerOpaque),
                    "drawableWidth": .double(render.drawableSize.width),
                    "drawableHeight": .double(render.drawableSize.height),
                    "contentsScale": .double(render.contentsScale),
                    "appActive": .bool(NSApp.isActive),
                    "windowKey": .bool(state.view.window?.isKeyWindow == true),
                    "windowMain": .bool(state.view.window?.isMainWindow == true),
                    "windowOpaque": .bool(state.view.window?.isOpaque == true),
                    "windowInLiveResize": .bool(state.view.window?.inLiveResize == true),
                    "viewInLiveResize": .bool(state.view.inLiveResize),
                    "viewOpaque": .bool(state.view.isOpaque),
                    "viewNeedsLayout": .bool(state.view.needsLayout),
                    "viewNeedsDisplay": .bool(state.view.needsDisplay),
                    "screenDisplayID": display.map { .int(Int($0.displayID)) } ?? .null,
                    "screenMaximumFPS": .int(display?.maximumFPS ?? 0),
                    "runLoopMode": RunLoop.current.currentMode.map { .string($0.rawValue) } ?? .null,
                ])
                if let lifecycle = render.lifecycle {
                    let rows: [JSONValue] = lifecycle.rows.map { row in
                        var fields: [String: JSONValue] = [
                            "id": .int(row.id), "drawableID": .int(row.drawableID),
                            "generation": .int(row.generation),
                            "sequence": row.sequence.map { .int(Int($0)) } ?? .null,
                            "sourceSequence": row.sourceSequence.map { .int(Int($0)) } ?? .null,
                            "submittedAt": .double(row.submittedAt), "commitReturnedAt": .double(row.commitReturnedAt),
                            "gpuStartedAt": .double(row.gpuStartedAt), "gpuEndedAt": .double(row.gpuEndedAt),
                            "gpuCallbackAt": .double(row.gpuCallbackAt), "gpuMainActorAt": .double(row.gpuMainActorAt),
                            "gpuStatus": .int(row.gpuStatus), "error": row.error.map { .string($0) } ?? .null,
                            "presentedAt": .double(row.presentedAt),
                            "presentationCallbackAt": .double(row.presentationCallbackAt),
                            "presentationMainActorAt": .double(row.presentationMainActorAt),
                        ]
                        if let display = row.displayCondition {
                            fields["screenDisplayID"] = .int(Int(display.displayID))
                            fields["screenMaximumFPS"] = .int(display.maximumFPS)
                            fields["contentsScale"] = .double(display.contentsScale)
                            fields["drawableWidth"] = .double(display.drawableSize.width)
                            fields["drawableHeight"] = .double(display.drawableSize.height)
                        }
                        return .object(fields)
                    }
                    result["renderLifecycle"] = .object([
                        "schemaVersion": .int(3),
                        "submitted": .int(lifecycle.submitted),
                        "gpuCompletedCallbacks": .int(lifecycle.completed),
                        "gpuFailedCommands": .int(lifecycle.failed),
                        "presentationCallbacks": .int(lifecycle.presentationCallbacks),
                        "historyLimit": .int(lifecycle.historyLimit),
                        "overwrittenRows": .int(lifecycle.overwrittenRows),
                        "rows": .array(rows),
                    ])
                }
                if let trace = state.view.frameTrace {
                    result["sourceFrameTrace"] = try JSONValue(encoding: trace.read())
                }
                result["view"] = .object([
                    "displaySyncEnabled": .bool(state.view.displaySyncEnabled),
                    "inputReady": .bool(state.view.inputReady),
                    "inputReadyAt": .double(state.view.inputReadyAt),
                    "visibilityChangedAt": .double(state.view.visibilityChangedAt),
                    "attached": .bool(state.view.window != nil), "visible": .bool(state.visible),
                    "width": .double(state.view.bounds.width), "height": .double(state.view.bounds.height),
                    "hidden": .bool(state.view.isHiddenOrHasHiddenAncestor),
                    "windowVisible": .bool(state.view.window?.isVisible == true),
                    "windowOcclusion": .int(Int(state.view.window?.occlusionState.rawValue ?? 0)),
                ])
            }
            return result
        }

        private func touch(
            _ state: SimulatorTabState, point: SimulatorPoint, phase: Int, geometry: SimulatorGeometry,
            edge: Int = 0, receivedAt: Double = 0, cancelBeforeTouch: Bool = false, taskStartedAt: Double = 0
        ) async throws {
            try await touch(state, points: [point], phase: phase, geometry: geometry, edge: edge,
                receivedAt: receivedAt, cancelBeforeTouch: cancelBeforeTouch, taskStartedAt: taskStartedAt)
        }

        private func touch(
            _ state: SimulatorTabState, points: [SimulatorPoint], phase: Int, geometry: SimulatorGeometry,
            edge: Int = 0, receivedAt: Double = 0, cancelBeforeTouch: Bool = false, taskStartedAt: Double = 0
        ) async throws {
            let requestStartedAt = receivedAt > 0 ? ProcessInfo.processInfo.systemUptime : 0
            let result = try await state.handle.worker.request([
                "command": .string("touch"), "phase": .int(phase), "cancelBeforeTouch": .bool(cancelBeforeTouch),
                "edge": .int(edge),
                "epoch": .string(geometry.epoch), "geometryVersion": .int(Int(geometry.geometryVersion)),
                "points": .array(points.map { .object(["x": .double($0.x), "y": .double($0.y)]) }),
            ])
            if CommandLine.arguments.contains("--e2e-test"), case .double(let submittedAt)? = result["submittedAt"],
                case .double(let enqueuedAt)? = result["enqueuedAt"]
            {
                if phase == 0 { state.inputDownSubmittedAt = submittedAt }
                if phase == 2 { state.inputUpSubmittedAt = submittedAt }
                state.lastInputSubmissionMs = (enqueuedAt - submittedAt) * 1000
                if receivedAt > 0, enqueuedAt >= receivedAt {
                    var stages = ["taskStartedAt": taskStartedAt, "requestStartedAt": requestStartedAt]
                    if case .double(let workerReceivedAt)? = result["receivedAt"] { stages["workerReceivedAt"] = workerReceivedAt }
                    if case .double(let workerStartedAt)? = result["startedAt"] { stages["workerStartedAt"] = workerStartedAt }
                    for key in ["transportEnteredAt", "clientEnteredAt", "nativeInputStartedAt", "nativeInputValidatedAt"] {
                        if case .double(let timestamp)? = result[key] { stages[key] = timestamp }
                    }
                    if phase == 0 {
                        state.manualDownReceivedAt = receivedAt
                        state.manualDownEnqueuedAt = enqueuedAt
                        state.manualDownStages = stages
                    }
                    if phase == 2 {
                        state.manualUpReceivedAt = receivedAt
                        state.manualUpEnqueuedAt = enqueuedAt
                        state.manualUpStages = stages
                    }
                }
            }
        }

        func manualTouch(_ state: SimulatorTabState, point: SimulatorPoint, phase: Int, receivedAt: Double) {
            state.markActivity()
            state.manualInputRevision += 1
            let takeover = phase == 0 && state.writer != nil
            if phase == 0 {
                state.writer = nil
                if takeover { state.generation += 1 }
            }
            let generation = state.generation
            let move: SimulatorPendingMove?
            if phase == 1 {
                if let pendingMove = state.pendingMove {
                    pendingMove.point = point
                    return
                }
                move = SimulatorPendingMove(point: point)
                state.pendingMove = move
            } else {
                move = nil
                state.pendingMove = nil
            }
            let previous = state.manualInput
            state.manualInput = Task { [weak self, weak state] in
                let taskStartedAt = receivedAt > 0 ? ProcessInfo.processInfo.systemUptime : 0
                await previous?.value
                guard let self, let state else { return }
                if let move, state.pendingMove === move {
                    state.pendingMove = nil
                }
                guard !state.isClosed, state.generation == generation else { return }
                let deliveredPoint = move?.point ?? point
                do {
                    if deliveredPoint.x < 0 {
                        // Leaving the viewport ends the touch, not the physical keyboard state.
                        _ = try await state.handle.worker.request(["command": .string("release-touch")])
                        return
                    }
                    guard let geometry = state.view.geometry else { return }
                    try await self.touch(state, point: geometry.normalizedDevicePoint(deliveredPoint), phase: phase, geometry: geometry,
                        receivedAt: receivedAt, cancelBeforeTouch: takeover, taskStartedAt: taskStartedAt)
                } catch { state.error = error.localizedDescription }
            }
        }

        private func visibility(_ state: SimulatorTabState, visible: Bool) {
            state.markActivity()
            state.visible = visible
            let previous = state.visibilityTask
            state.visibilityTask = Task { [weak state] in
                await previous?.value
                guard let state, !state.isClosed else { return }
                do { _ = try await state.handle.worker.request(["command": .string(state.visible ? "subscribe" : "unsubscribe")]) } catch {
                    state.error = error.localizedDescription
                }
            }
        }

        private func cancelManualInput(_ state: SimulatorTabState) {
            guard state.writer == nil else { return }
            state.manualInputRevision += 1
            state.pendingMove = nil
            let previous = state.manualInput
            state.manualInput = Task { [weak state] in
                await previous?.value
                guard let state, !state.isClosed, state.writer == nil else { return }
                do { _ = try await state.handle.worker.request(["command": .string("cancel")]) } catch {
                    state.error = error.localizedDescription
                }
            }
        }

        func manualKey(_ state: SimulatorTabState, usage: Int, down: Bool) {
            state.markActivity()
            state.manualInputRevision += 1
            state.pendingMove = nil
            let takeover = state.writer != nil
            state.writer = nil
            if takeover { state.generation += 1 }
            let previous = state.manualInput
            state.manualInput = Task { [weak state] in
                await previous?.value
                guard let state, !state.isClosed else { return }
                do {
                    if takeover { _ = try await state.handle.worker.request(["command": .string("cancel")]) }
                    _ = try await state.handle.worker.request(["command": .string("key"), "usage": .int(usage), "down": .bool(down)])
                } catch { state.error = error.localizedDescription }
            }
        }

        func claimWriter(_ state: SimulatorTabState, cancelInput: @MainActor () async throws -> Void) async throws {
            guard !state.writing else { throw SimulatorFailure("A simulator operation is still in progress") }
            state.writing = true
            defer { state.writing = false }
            let generation = state.generation
            let manualInputRevision = state.manualInputRevision
            func checkClaim() throws {
                try Task.checkCancellation()
                try validate(state.owner)
                guard !state.isClosed, state.generation == generation, state.manualInputRevision == manualInputRevision else {
                    throw SimulatorFailure("Simulator claim cancelled by human takeover or tab closure")
                }
            }
            // Finish old human input before cancellation; newer input wins at either suspension point.
            await state.manualInput?.value
            try checkClaim()
            try await cancelInput()
            try checkClaim()
            state.manualInput = nil
            state.writer = state.owner
            state.generation += 1
        }

        func manualHome(_ state: SimulatorTabState) {
            state.markActivity()
            state.manualInputRevision += 1
            state.pendingMove = nil
            state.writer = nil
            state.generation += 1
            let previous = state.manualInput
            state.manualInput = Task { [weak state] in
                await previous?.value
                guard let state, !state.isClosed else { return }
                do {
                    _ = try await state.handle.worker.request(["command": .string("cancel")])
                    for down in [true, false] {
                        _ = try await state.handle.worker.request(["command": .string("button"), "usage": .int(0x40), "down": .bool(down)])
                    }
                } catch { state.error = error.localizedDescription }
            }
        }

        func close(_ state: SimulatorTabState) {
            guard !state.isClosed else { return }
            state.isClosed = true
            state.displayIdleTask?.cancel()
            state.error = nil
            state.generation += 1
            state.writer = nil
            tabs.removeValue(forKey: state.id)
            workspaces[state.workspaceID]?.onClose(state)
            state.view.close()
            closeTasks[state.id] = Task {
                defer { closeTasks.removeValue(forKey: state.id) }
                do { try await coordinator?.close(state.handle, shutdown: true) } catch { state.error = error.localizedDescription }
            }
        }

        func shutdown() async {
            closing = true
            ownerMonitor?.cancel()
            ownerMonitor = nil
            let active = Array(tabs.values)
            for state in active {
                state.isClosed = true
                state.displayIdleTask?.cancel()
                state.view.close()
            }
            tabs.removeAll()
            // Stop every recorder before an existing close can consume the host's exit deadline.
            await coordinator?.prepareForShutdown()
            while let cleanup = closeTasks.values.first { await cleanup.value }
            await coordinator?.shutdown()
        }
    }

    @MainActor
    final class SimulatorWorkspace {
        let id = UUID()
        weak var window: NSWindow?
        var acceptsPane: (PaneInfo) -> Bool = { _ in false }
        var onCreate: (SimulatorTabState) -> Void = { _ in }
        var onSelect: (SimulatorTabState, Bool) -> Void = { _, _ in }
        var onClose: (SimulatorTabState) -> Void = { _ in }
    }

    // Each queued run owns its coordinates; later clicks or keys end coalescing without discarding it.
    @MainActor
    final class SimulatorPendingMove {
        var point: SimulatorPoint

        init(point: SimulatorPoint) { self.point = point }
    }

    @MainActor @Observable
    final class SimulatorTabState {
        let handle: SimulatorDeviceHandle
        var id: UUID { handle.id }
        let owner: SimulatorOwner
        let sourcePane: PaneInfo
        var paneID: String { sourcePane.paneId }
        let workspaceID: UUID
        let view: SimulatorMetalView
        let service: AgentSimulatorService
        var writer: SimulatorOwner?
        var displayMode: SimulatorDisplayMode = .synchronized {
            didSet { view.setDisplayMode(displayMode) }
        }
        var error: String?
        var isClosed = false
        @ObservationIgnored var generation = 0
        // Keyboard activity must revoke pending claims without discarding queued touch events.
        @ObservationIgnored var manualInputRevision = 0
        @ObservationIgnored var writing = false
        @ObservationIgnored var visible = false
        @ObservationIgnored var lastActivity = ContinuousClock.now
        @ObservationIgnored var pendingMove: SimulatorPendingMove?
        @ObservationIgnored var manualInput: Task<Void, Never>?
        @ObservationIgnored var visibilityTask: Task<Void, Never>?
        @ObservationIgnored var displayIdleTask: Task<Void, Never>?
        @ObservationIgnored var observation: SimulatorObservation?
        @ObservationIgnored var inputDownSubmittedAt = 0.0
        @ObservationIgnored var inputUpSubmittedAt = 0.0
        @ObservationIgnored var lastInputSubmissionMs = 0.0
        @ObservationIgnored var manualDownReceivedAt = 0.0
        @ObservationIgnored var manualDownStages: [String: Double] = [:]
        @ObservationIgnored var manualUpStages: [String: Double] = [:]
        @ObservationIgnored var manualDownEnqueuedAt = 0.0
        @ObservationIgnored var manualUpReceivedAt = 0.0
        @ObservationIgnored var manualUpEnqueuedAt = 0.0

        func markActivity() {
            lastActivity = .now
            displayIdleTask?.cancel()
            displayIdleTask = nil
        }

        init(
            handle: SimulatorDeviceHandle, owner: SimulatorOwner, sourcePane: PaneInfo, workspaceID: UUID, view: SimulatorMetalView,
            service: AgentSimulatorService
        ) {
            self.handle = handle
            self.owner = owner
            self.writer = owner
            self.sourcePane = sourcePane
            self.workspaceID = workspaceID
            self.view = view
            self.service = service
        }
    }

    struct SimulatorObservation: Sendable {
        let generation: Int
        let geometry: SimulatorGeometry
        let application: SimulatorOwner
        let references: [String: SimulatorElement]
    }
#endif
