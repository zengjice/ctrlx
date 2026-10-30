#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    @preconcurrency import CtrlxSimulatorBridge
    import CtrlxSimulatorProtocol
    import Darwin
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Logging

    struct SimulatorProcess: Sendable {
        let owner: SimulatorOwner
        let parentPID: Int32
        /// Absolute path, or an exact kernel executable name after its file is removed.
        let executable: String
    }

    struct SimulatorDiagnosticFile: Sendable {
        let url: URL
        let modifiedAt: Date
    }

    @DependencyClient
    struct SimulatorSystemClient: Sendable {
        var inspect: @Sendable (Int32) throws -> SimulatorProcess
        var createDirectory: @Sendable (URL) throws -> Void
        var read: @Sendable (URL) throws -> Data
        var readPrefix: @Sendable (URL, Int) throws -> Data = { _, _ in throw SimulatorFailure("Bounded file reads are not configured") }
        var diagnosticFiles: @Sendable (URL) throws -> [SimulatorDiagnosticFile] = { _ in throw SimulatorFailure("Crash report listing is not configured") }
        var write: @Sendable (Data, URL) throws -> Void
        var remove: @Sendable (URL) throws -> Void
        var isExecutable: @Sendable (URL) -> Bool = { _ in false }
        var connect: @Sendable (String, @escaping @Sendable (CXSimulatorFrame) -> Void,
            @escaping @Sendable (String) -> Void) throws -> SimulatorTransport
    }

    extension SimulatorSystemClient: DependencyKey {
        func ancestors(of processID: Int32) throws -> Set<Int32> {
            var result = Set<Int32>()
            var pid = processID
            while pid > 1, result.count < 64, !result.contains(pid) {
                let process = try inspect(pid)
                guard process.owner.uid == getuid() else { break }
                result.insert(pid)
                pid = process.parentPID
            }
            return result
        }

        static let liveValue = Self(
            inspect: { pid in
                func info() throws -> proc_bsdinfo {
                    var value = proc_bsdinfo()
                    guard
                        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, Int32(MemoryLayout.size(ofValue: value)))
                            == MemoryLayout.size(ofValue: value)
                    else {
                        throw SimulatorFailure("Cannot inspect process \(pid)")
                    }
                    return value
                }
                let before = try info()
                var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                let count = proc_pidpath(pid, &path, UInt32(path.count))
                let pathError = count > 0 ? 0 : errno
                let kernelName = withUnsafeBytes(of: before.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                let after = try info()
                guard
                    before.pbi_uid == after.pbi_uid, before.pbi_start_tvsec == after.pbi_start_tvsec,
                    before.pbi_start_tvusec == after.pbi_start_tvusec, before.pbi_ppid == after.pbi_ppid,
                    before.pbi_status != SZOMB, after.pbi_status != SZOMB,
                    withUnsafeBytes(of: after.pbi_name, { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }) == kernelName
                else {
                    throw SimulatorFailure("Process identity changed during inspection")
                }
                let executablePath = count > 0 ? String(bytes: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) : nil
                guard let executable = AgentExecutableIdentity.resolve(path: executablePath, errorCode: pathError, kernelName: kernelName) else {
                    throw SimulatorFailure("Cannot read process \(pid) executable (errno \(pathError))")
                }
                return SimulatorProcess(
                    owner: SimulatorOwner(
                        pid: pid, uid: after.pbi_uid, startSeconds: after.pbi_start_tvsec, startMicros: after.pbi_start_tvusec
                    ),
                    parentPID: Int32(after.pbi_ppid),
                    executable: executable
                )
            },
            createDirectory: {
                try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            },
            read: { try Data(contentsOf: $0) },
            readPrefix: { url, limit in
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                return try file.read(upToCount: limit) ?? Data()
            },
            diagnosticFiles: { directory in
                guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
                let files = try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard files.count <= 4096 else { throw SimulatorFailure("Too many crash reports; narrow the device's report collection") }
                return try files.filter { $0.pathExtension == "ips" }.compactMap { url in
                    let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                    guard values.isRegularFile == true, let date = values.contentModificationDate else { return nil }
                    return SimulatorDiagnosticFile(url: url, modifiedAt: date)
                }
            },
            write: { data, url in
                try data.write(to: url, options: .atomic)
                guard chmod(url.path, 0o600) == 0 else { throw SimulatorFailure("Cannot protect simulator state file") }
            },
            remove: { try FileManager.default.removeItem(at: $0) },
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0.path) },
            connect: { SimulatorTransport(serviceName: $0, frames: $1, errors: $2) }
        )
    }

    actor SimulatorTransport {
        private let connection: CXSimulatorConnection
        init(connection: CXSimulatorConnection) {
            self.connection = connection
        }

        init(
            serviceName: String, frames: @escaping @Sendable (CXSimulatorFrame) -> Void,
            errors: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            connection = CXSimulatorConnection(serviceName: serviceName, frameHandler: frames, errorHandler: errors)
        }

        func request(_ command: [String: JSONValue]) async throws -> [String: JSONValue] {
            try Task.checkCancellation()
            let inputDiagnostics = CommandLine.arguments.contains("--e2e-test") && command["command"] == .string("touch")
            let activationDiagnostics = CommandLine.arguments.contains("--e2e-test")
                && CommandLine.arguments.contains("--e2e-simulator-activation-trace")
                && command["command"] == .string("application-active")
            let screenshotDiagnostics = CommandLine.arguments.contains("--e2e-test") && command["command"] == .string("screenshot")
            let enteredAt = inputDiagnostics || activationDiagnostics || screenshotDiagnostics ? ProcessInfo.processInfo.systemUptime : 0
            let activationPID = command["applicationPID"]?.intValue ?? 0
            var payload = command
            if inputDiagnostics { payload["inputDiagnostics"] = .bool(true) }
            if activationDiagnostics { payload["activationDiagnostics"] = .bool(true) }
            if screenshotDiagnostics { payload["screenshotDiagnostics"] = .bool(true) }
            let data = try JSONEncoder().encode(payload)
            return try await withCheckedThrowingContinuation { continuation in
                connection.request(data) { result, error in
                    if let error {
                        if activationDiagnostics {
                            FileHandle.standardError.write(Data(String(format:
                                "SimulatorActivation stage=transport pid=%ld begin=%.9f end=%.9f error=%@\n",
                                activationPID, enteredAt, ProcessInfo.processInfo.systemUptime, error.localizedDescription).utf8))
                        }
                        continuation.resume(throwing: SimulatorFailure(error.localizedDescription))
                        return
                    }
                    guard let result else {
                        continuation.resume(throwing: SimulatorFailure("Empty simulator helper response"))
                        return
                    }
                    do {
                        var decoded = try JSONDecoder().decode([String: JSONValue].self, from: result)
                        if inputDiagnostics { decoded["transportEnteredAt"] = .double(enteredAt) }
                        if screenshotDiagnostics, var geometry = decoded["geometry"]?.objectValue,
                           var timing = geometry["screenshotTiming"]?.objectValue {
                            timing["transportEnteredAt"] = .double(enteredAt)
                            timing["transportDecodedAt"] = .double(ProcessInfo.processInfo.systemUptime)
                            geometry["screenshotTiming"] = .object(timing)
                            decoded["geometry"] = .object(geometry)
                        }
                        if activationDiagnostics {
                            let helperBegan = try decoded["activationBeganAt"]?.decode(Double.self) ?? 0
                            let helperEnded = try decoded["activationEndedAt"]?.decode(Double.self) ?? 0
                            let receivedAt = ProcessInfo.processInfo.systemUptime
                            FileHandle.standardError.write(Data(String(format:
                                "SimulatorActivation stage=transport pid=%ld begin=%.9f end=%.9f helperBegin=%.9f helperEnd=%.9f active=%d\n",
                                activationPID, enteredAt, receivedAt,
                                helperBegan, helperEnded,
                                decoded["active"]?.boolValue == true ? 1 : 0).utf8))
                            decoded["activationTransportReceivedAt"] = .double(receivedAt)
                            decoded["activationTraceWriteEndedAt"] = .double(ProcessInfo.processInfo.systemUptime)
                        }
                        continuation.resume(returning: decoded)
                    } catch {
                        continuation.resume(throwing: SimulatorFailure("Invalid simulator helper JSON: \(error.localizedDescription)"))
                    }
                }
            }
        }
        func invalidate() { connection.invalidate() }
    }

    struct SimulatorDeviceHandle: Sendable {
        let id: UUID
        let udid: String
        let name: String
        let runtime: String
        let deviceType: String
        let worker: SimulatorTransport
        let profile: SimulatorProfile
        let requiredFeatures: [String]

        init(id: UUID, udid: String, name: String, runtime: String, deviceType: String, worker: SimulatorTransport,
            profile: SimulatorProfile = .standard, requiredFeatures: [String] = []) {
            self.id = id
            self.udid = udid
            self.name = name
            self.runtime = runtime
            self.deviceType = deviceType
            self.worker = worker
            self.profile = profile
            self.requiredFeatures = requiredFeatures
        }
    }

    actor SimulatorCoordinator {
        private let runner: ProcessRunner
        private let system: SimulatorSystemClient
        private let root: URL
        private let helper: URL
        private let hostDiagnostics: URL
        private let resources: SimulatorResourceClient
        private let recordingClient: SimulatorRecordingClient
        private var recordings: [UUID: SimulatorRecorder] = [:]
        private var recordingStarts = Set<UUID>()
        private var savedConfiguration: SimulatorConfiguration?
        private var slimCatalogue: (categories: [SimulatorSlimCategory], features: [SimulatorSlimFeature])?
        static let simslimCommit = "e752a72898ca69f703c74dc79b7b047a4f2093a3"
        private let logger = Logger(label: "com.jicezeng.ctrlx.simulator")
        private var jobs: [String: URL] = [:]
        private var handles: [UUID: SimulatorDeviceHandle] = [:]
        private var inspectors: [UUID: (service: String, transport: SimulatorTransport)] = [:]
        private var workerServices: [UUID: String] = [:]
        private var booting = false
        private var bootTasks: [UUID: Task<SimulatorDeviceHandle, Error>] = [:]
        private var storageTasks: [UUID: Task<[String: JSONValue], Error>] = [:]
        private var shuttingDown = false
        private var pendingDevices = Set<String>()
        private var failedShutdownDevices = Set<String>()
        private var bootWaiters: [CheckedContinuation<Void, Never>] = []
        private var inspectorBusy = Set<UUID>()
        private var inspectorExpiry: [UUID: Task<Void, Never>] = [:]

        var deviceSet: URL { root.appendingPathComponent("devices", isDirectory: true) }

        init(root: URL, helper: URL, runner: ProcessRunner, system: SimulatorSystemClient,
            resources: SimulatorResourceClient = .liveValue,
            hostDiagnostics: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")) {
            self.root = root
            self.helper = helper
            self.runner = runner
            self.system = system
            self.resources = resources
            self.hostDiagnostics = hostDiagnostics
            @Dependency(SimulatorRecordingClient.self) var recordingClient
            self.recordingClient = recordingClient
        }

        func configuration(maximumDevices: Int? = nil, memoryReserveMiB: Int? = nil, diskReserveMiB: Int? = nil) throws
            -> SimulatorConfiguration {
            try system.createDirectory(root)
            let file = root.appendingPathComponent("configuration.json")
            var value: SimulatorConfiguration
            if let savedConfiguration { value = savedConfiguration } else {
                do { value = try JSONDecoder().decode(SimulatorConfiguration.self, from: system.read(file)) } catch {
                    guard let error = error as? CocoaError, error.code == .fileReadNoSuchFile else { throw error }
                    value = SimulatorConfiguration()
                }
            }
            if let maximumDevices { value.maximumDevices = maximumDevices }
            if let memoryReserveMiB { value.memoryReserveMiB = memoryReserveMiB }
            if let diskReserveMiB { value.diskReserveMiB = diskReserveMiB }
            try value.validate()
            if maximumDevices != nil || memoryReserveMiB != nil || diskReserveMiB != nil {
                try system.write(JSONEncoder().encode(value), file)
            }
            savedConfiguration = value
            return value
        }

        func resourceSnapshot() throws -> SimulatorResources {
            try system.createDirectory(root)
            return try resources.read(root)
        }

        private func slim(_ arguments: [String], timeout: Double = 30) async throws -> ProcessResult {
            let binary = helper.deletingLastPathComponent().appendingPathComponent("simslim")
            guard system.isExecutable(binary) else { throw SimulatorFailure("The bundled simslim helper is missing") }
            return try await execute(binary.path, arguments + ["--set", deviceSet.path], timeout: timeout)
        }

        private func prepare(_ udid: String, profile: SimulatorProfile, requires: [String], id: UUID) async throws {
            if slimCatalogue == nil {
                let binary = helper.deletingLastPathComponent().appendingPathComponent("simslim")
                guard system.isExecutable(binary) else { throw SimulatorFailure("The bundled simslim helper is missing") }
                let version = try await execute(binary.path, ["version"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard version == "simslim \(Self.simslimCommit)" else { throw SimulatorFailure("The bundled simslim version is unsupported") }
                let categories = try JSONDecoder().decode([SimulatorSlimCategory].self, from: await slim(["profiles", "--json"]).stdout)
                let features = try JSONDecoder().decode([SimulatorSlimFeature].self, from: await slim(["doctor", "--list", "--json"]).stdout)
                slimCatalogue = (categories, features)
            }
            guard let slimCatalogue else { throw SimulatorFailure("The simslim service catalogue is unavailable") }
            let selection = try SimulatorSlimProfile(
                selection: profile, requires: requires, categories: slimCatalogue.categories, features: slimCatalogue.features)
            guard !shuttingDown else { throw SimulatorFailure("Simulator host is shutting down") }
            let directory = root.appendingPathComponent("profiles", isDirectory: true)
            try system.createDirectory(directory)
            let file = directory.appendingPathComponent(id.uuidString + ".json")
            try system.write(JSONEncoder().encode(selection), file)
            defer {
                do { try system.remove(file) } catch { logger.warning("Could not remove a simulator preparation profile: \(error)") }
            }
            // The pinned `on` checks the live managed overrides after boot, including extras.
            _ = try await slim(["on", udid, "--profile", file.path, "--boot-timeout", "3m"], timeout: 185)
            guard !shuttingDown else { throw SimulatorFailure("Simulator host is shutting down") }
            if !requires.isEmpty {
                _ = try await slim(["doctor", udid, "--requires", requires.joined(separator: ","), "--json"])
            }
        }

        func metrics(_ handle: SimulatorDeviceHandle) async throws -> [String: JSONValue] {
            let value = try await slim(["measure", handle.udid, "--json"])
            return ["simulator": .object(try JSONDecoder().decode([String: JSONValue].self, from: value.stdout)),
                "system": try JSONValue(encoding: resourceSnapshot())]
        }

        private func execute(_ executable: String, _ arguments: [String], timeout: Double = 30) async throws -> ProcessResult {
            let result = try await runner.runCancellable(executable, arguments, nil, timeout)
            guard result.isSuccess else { throw SimulatorFailure(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return result
        }

        func simctl(_ arguments: [String], timeout: Double = 30) async throws -> ProcessResult {
            try await execute("/usr/bin/xcrun", ["simctl", "--set", deviceSet.path] + arguments, timeout: timeout)
        }

        static func launchedProcessID(_ output: Data, bundle: String) throws -> Int32 {
            let prefix = "\(bundle): "
            guard let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  text.hasPrefix(prefix), let pid = Int32(text.dropFirst(prefix.count)), pid > 1 else {
                throw SimulatorFailure("Application launched but simctl did not return its process identifier")
            }
            return pid
        }

        func push(_ handle: SimulatorDeviceHandle, notification: SimulatorPushNotification) async throws {
            let directory = root.appendingPathComponent("artifacts", isDirectory: true)
            try system.createDirectory(directory)
            let file = directory.appendingPathComponent(UUID().uuidString + ".json")
            defer {
                do { try system.remove(file) } catch { logger.warning("Could not remove simulator push payload: \(error)") }
            }
            try system.write(notification.payload, file)
            _ = try await simctl(["push", handle.udid, notification.bundle, file.path])
        }

        func logs(_ handle: SimulatorDeviceHandle, request: SimulatorLogRequest) async throws -> [String: JSONValue] {
            let binary = try await applicationBinary(handle, bundle: request.bundle)
            let image = try await runner.runBounded("/usr/bin/dwarfdump", ["--uuid", binary.path], nil, 5, 16384)
            guard image.isSuccess, !image.outputTruncated else { throw SimulatorFailure("Cannot read the application's image identity") }
            let identities = Set(image.stdoutString.split(separator: "\n").compactMap { line -> String? in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 2, fields[0] == "UUID:", let uuid = UUID(uuidString: String(fields[1])) else { return nil }
                return uuid.uuidString
            })
            guard !identities.isEmpty, identities.count <= 32 else { throw SimulatorFailure("The application has no usable Mach-O image identity") }
            // Unified logging can retain an earlier container path for the same image after reinstall.
            guard let component = binary.path.range(of: "/\(handle.udid)/", options: .backwards) else {
                throw SimulatorFailure("The application path has no owned device component")
            }
            let directory = String(binary.path[..<component.upperBound])
            let suffix = "/\(binary.deletingLastPathComponent().lastPathComponent)/\(binary.lastPathComponent)"
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "processImagePath BEGINSWITH %@", directory),
                NSPredicate(format: "processImagePath ENDSWITH %@", suffix),
            ]).predicateFormat
            let result = try await runner.runBounded("/usr/bin/xcrun",
                ["simctl", "--set", deviceSet.path, "spawn", handle.udid, "log", "show", "--style", "ndjson",
                 "--info", "--debug", "--last", "\(request.lastSeconds)s", "--predicate", predicate], nil, 15, request.maximumBytes)
            guard result.isSuccess else { throw SimulatorFailure(result.stderrString) }
            var text = ""
            for line in result.stdout.split(separator: 10) {
                guard let record = try? JSONDecoder().decode([String: JSONValue].self, from: Data(line)),
                    let imageID = record["processImageUUID"]?.stringValue, identities.contains(imageID.uppercased()),
                    let path = record["processImagePath"]?.stringValue, path.hasPrefix(directory), path.hasSuffix(suffix),
                    let message = record["eventMessage"]?.stringValue else { continue }
                let timestamp = record["timestamp"]?.stringValue ?? ""
                let pid = record["processID"]?.intValue ?? 0
                text += "\(timestamp) [\(pid)] \(message)\n"
            }
            return ["bundle": .string(request.bundle), "text": .string(text),
                    "lastSeconds": .int(request.lastSeconds), "truncated": .bool(result.outputTruncated)]
        }

        func crashes(_ handle: SimulatorDeviceHandle, request: SimulatorCrashRequest) throws -> [String: JSONValue] {
            let directory = deviceSet.appendingPathComponent(handle.udid)
                .appendingPathComponent("data/Library/Logs/CrashReporter", isDirectory: true)
            let cutoff = Date().addingTimeInterval(-Double(request.lastSeconds))
            let local = try system.diagnosticFiles(directory).map { (file: $0, host: false) }
            let host = try system.diagnosticFiles(hostDiagnostics).map { (file: $0, host: true) }
            let files = (local + host).filter { $0.file.modifiedAt >= cutoff }.sorted { $0.file.modifiedAt > $1.file.modifiedAt }
            var reports: [JSONValue] = []
            var remaining = request.maximumBytes
            var inspectionRemaining = 1024 * 1024
            var truncated = files.count > 128
            for candidate in files.prefix(128) {
                let file = candidate.file
                let header = try system.readPrefix(file.url, 16384)
                guard let first = header.split(separator: 10).first,
                    let metadata = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
                    metadata["bundleID"] as? String == request.bundle else { continue }
                var inspected: Data?
                if candidate.host {
                    guard metadata["platform"] as? Int == 7 else { continue }
                    guard inspectionRemaining > 0 else { truncated = true; continue }
                    let data = try system.readPrefix(file.url, inspectionRemaining + 1)
                    let exceeded = data.count > inspectionRemaining
                    inspectionRemaining -= min(data.count, inspectionRemaining)
                    guard !exceeded, let newline = data.firstIndex(of: 10),
                        let details = try? JSONSerialization.jsonObject(with: Data(data.suffix(from: data.index(after: newline)))) as? [String: Any]
                    else { truncated = true; continue }
                    guard details["coalitionName"] as? String == "com.apple.CoreSimulator.SimDevice.\(handle.udid)" else { continue }
                    inspected = data
                }
                guard reports.count < request.limit, remaining > 0 else { truncated = true; break }
                let data = try inspected ?? system.readPrefix(file.url, remaining + 1)
                let clipped = data.count > remaining
                let retained = data.prefix(remaining)
                reports.append(.object(["file": .string(file.url.lastPathComponent),
                    "modifiedAt": .double(file.modifiedAt.timeIntervalSince1970),
                    "text": .string(String(decoding: retained, as: UTF8.self)), "truncated": .bool(clipped)]))
                remaining -= retained.count
                truncated = truncated || clipped
            }
            return ["bundle": .string(request.bundle), "reports": .array(reports), "truncated": .bool(truncated)]
        }

        private func applicationBinary(_ handle: SimulatorDeviceHandle, bundle: String) async throws -> URL {
            let result = try await simctl(["get_app_container", handle.udid, bundle, "app"])
            let app = URL(fileURLWithPath: result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
            let directory = deviceSet.appendingPathComponent(handle.udid).resolvingSymlinksInPath().path + "/"
            guard app.resolvingSymlinksInPath().path.hasPrefix(directory) else {
                throw SimulatorFailure("The application container is outside the owned simulator")
            }
            let data = try system.readPrefix(app.appendingPathComponent("Info.plist"), 128 * 1024)
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                plist["CFBundleIdentifier"] as? String == bundle,
                let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty,
                URL(fileURLWithPath: executable).lastPathComponent == executable else {
                throw SimulatorFailure("Cannot resolve the installed application's executable")
            }
            return app.appendingPathComponent(executable)
        }

        func inventory() async throws -> [String: JSONValue] {
            try system.createDirectory(deviceSet)
            let result = try await simctl(["list", "-j"])
            return try JSONDecoder().decode([String: JSONValue].self, from: result.stdout)
        }

        private var reservedDevices: Set<String> {
            Set(handles.values.map(\.udid)).union(pendingDevices).union(failedShutdownDevices)
        }

        private func storedDevices(in inventory: [String: JSONValue]) throws -> [[String: JSONValue]] {
            guard let groups = inventory["devices"]?.objectValue else {
                throw SimulatorFailure("The private simulator device list is unavailable")
            }
            return try groups.keys.sorted().flatMap { runtime -> [[String: JSONValue]] in
                guard case let .array(values)? = groups[runtime] else { throw SimulatorFailure("Invalid private simulator device list") }
                return try values.map { value in
                    guard var row = value.objectValue, let udid = row["udid"]?.stringValue, UUID(uuidString: udid) != nil else {
                        throw SimulatorFailure("Invalid private simulator UDID")
                    }
                    row["runtime"] = .string(runtime)
                    return row
                }
            }
        }

        func storage() async throws -> [String: JSONValue] {
            let devices = try storedDevices(in: await inventory())
            var sizes: [String: Int] = [:]
            var usageError: String?
            if !devices.isEmpty {
                let paths = devices.compactMap { $0["udid"]?.stringValue }.map { deviceSet.appendingPathComponent($0).path }
                do {
                    let usage = try await runner.runBounded("/usr/bin/du", ["-sk"] + paths, nil, 15, 65536)
                    guard usage.isSuccess, !usage.outputTruncated else {
                        throw SimulatorFailure("Private device disk usage is incomplete: \(usage.stderrString)")
                    }
                    for line in usage.stdoutString.split(separator: "\n") {
                        let fields = line.split(separator: "\t", maxSplits: 1)
                        guard fields.count == 2, let kib = Int(fields[0]), kib >= 0, kib <= Int.max / 1024 else { continue }
                        sizes[String(fields[1])] = kib * 1024
                    }
                } catch { usageError = error.localizedDescription }
            }
            let reserved = reservedDevices
            let rows = devices.map { device -> JSONValue in
                var row = device
                let udid = device["udid"]!.stringValue!
                row["inUse"] = .bool(reserved.contains(udid))
                row["canModify"] = .bool(!reserved.contains(udid) && device["state"]?.stringValue == "Shutdown")
                row["allocatedBytes"] = sizes[deviceSet.appendingPathComponent(udid).path].map(JSONValue.int) ?? .null
                return .object(row)
            }
            var result: [String: JSONValue] = ["devices": .array(rows), "deviceSet": .string(deviceSet.path)]
            if let usageError { result["diskUsageError"] = .string(usageError) }
            return result
        }

        func modifyStorage(_ operation: SimulatorOperation, udid: String, owner: SimulatorOwner) async throws -> [String: JSONValue] {
            guard operation == .erase || operation == .delete, let uuid = UUID(uuidString: udid) else {
                throw SimulatorFailure("Storage changes require erase or delete and one private device UUID")
            }
            try Task.checkCancellation()
            guard !shuttingDown else { throw SimulatorFailure("Simulator host is shutting down") }
            let id = UUID()
            let task = Task { try await changeStorage(operation, uuid: uuid, owner: owner) }
            storageTasks[id] = task
            defer { storageTasks.removeValue(forKey: id) }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }

        private func changeStorage(_ operation: SimulatorOperation, uuid: UUID, owner: SimulatorOwner) async throws -> [String: JSONValue] {
            // Share boot admission so a shutdown device cannot be reused during erase/delete.
            await acquireBoot()
            defer { releaseBoot() }
            try Task.checkCancellation()
            guard !shuttingDown else { throw SimulatorFailure("Simulator host is shutting down") }
            let devices = try storedDevices(in: await inventory())
            guard let device = devices.first(where: { $0["udid"]?.stringValue.flatMap(UUID.init(uuidString:)) == uuid }),
                  let target = device["udid"]?.stringValue else {
                throw SimulatorFailure("The requested device is not in CtrlX's private device set")
            }
            guard device["state"]?.stringValue == "Shutdown", !reservedDevices.contains(target) else {
                throw SimulatorFailure("The device is in use or not shut down; close it before \(operation.rawValue)")
            }
            guard !shuttingDown, try system.inspect(owner.pid).owner == owner else {
                throw SimulatorFailure("The simulator host or calling agent closed before the storage change")
            }
            pendingDevices.insert(target)
            defer { pendingDevices.remove(target) }
            _ = try await simctl([operation.rawValue, target], timeout: 120)
            return ["udid": .string(target), operation == .erase ? "erased" : "deleted": .bool(true)]
        }

        private func acquireBoot() async {
            if !booting {
                booting = true
                return
            }
            await withCheckedContinuation { bootWaiters.append($0) }
        }
        private func releaseBoot() {
            if bootWaiters.isEmpty { booting = false } else { bootWaiters.removeFirst().resume() }
        }

        func open(
            runtime requestedRuntime: String?, deviceType requestedType: String?, udid requestedUDID: String? = nil,
            profile: SimulatorProfile = .standard,
            requires: [String] = [], frames: @escaping @Sendable (CXSimulatorFrame) -> Void,
            errors: @escaping @Sendable (String) -> Void
        ) async throws -> SimulatorDeviceHandle {
            try Task.checkCancellation()
            guard !shuttingDown else { throw SimulatorFailure("Simulator host is shutting down") }
            let id = UUID()
            let task = Task {
                try await boot(runtime: requestedRuntime, deviceType: requestedType, udid: requestedUDID, profile: profile,
                               requires: requires, frames: frames, errors: errors)
            }
            bootTasks[id] = task
            defer { bootTasks.removeValue(forKey: id) }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }

        private func boot(
            runtime requestedRuntime: String?, deviceType requestedType: String?, udid requestedUDID: String?, profile: SimulatorProfile,
            requires: [String], frames: @escaping @Sendable (CXSimulatorFrame) -> Void,
            errors: @escaping @Sendable (String) -> Void
        ) async throws -> SimulatorDeviceHandle {
            await acquireBoot()
            defer { releaseBoot() }
            try Task.checkCancellation()
            guard !shuttingDown else { throw SimulatorFailure("Simulator host is shutting down") }
            try await recoverFailedShutdowns()
            let configuration = try configuration()
            guard handles.count + pendingDevices.count < configuration.maximumDevices else {
                throw SimulatorFailure("The configured simulator device limit has been reached")
            }
            try configuration.admit(resourceSnapshot())
            guard system.isExecutable(helper) else {
                throw SimulatorFailure("Simulator helper is missing. Build and embed CtrlxSimulatorHost first")
            }
            let inventory = try await inventory()
            let selected: [String: JSONValue]?
            if let requestedUDID {
                guard let uuid = UUID(uuidString: requestedUDID), requestedRuntime == nil, requestedType == nil else {
                    throw SimulatorFailure("Choose one private device UUID or runtime/device type")
                }
                guard let device = try storedDevices(in: inventory).first(where: { $0["udid"]?.stringValue.flatMap(UUID.init(uuidString:)) == uuid }),
                      let udid = device["udid"]?.stringValue, device["state"]?.stringValue == "Shutdown",
                      device["isAvailable"]?.boolValue == true, !reservedDevices.contains(udid) else {
                    throw SimulatorFailure("The requested private simulator is unavailable, in use or not shut down")
                }
                selected = device
            } else { selected = nil }
            let runtimeSelection = selected?["runtime"]?.stringValue ?? requestedRuntime
            let typeSelection = selected?["deviceTypeIdentifier"]?.stringValue ?? requestedType
            guard case .array(let rawRuntimes) = inventory["runtimes"] else {
                throw SimulatorFailure("No simulator runtimes are installed")
            }
            let runtimes = rawRuntimes.compactMap(\.objectValue).filter {
                $0["isAvailable"]?.boolValue == true && $0["platform"]?.stringValue == "iOS"
            }
            .sorted {
                ($0["version"]?.stringValue ?? "").compare($1["version"]?.stringValue ?? "", options: .numeric) == .orderedDescending
            }
            guard !runtimes.isEmpty else {
                throw SimulatorFailure("No available iOS Simulator runtime is installed. Install a runtime in Xcode Settings → Platforms")
            }
            guard let runtime = runtimes.first(where: { runtimeSelection == nil || $0["identifier"]?.stringValue == runtimeSelection }),
                let runtimeID = runtime["identifier"]?.stringValue
            else { throw SimulatorFailure("The requested iOS runtime is unavailable") }
            guard case .array(let types) = runtime["supportedDeviceTypes"] else {
                throw SimulatorFailure("Runtime does not report supported device types")
            }
            guard
                let type = types.compactMap(\.objectValue).first(where: {
                    $0["productFamily"]?.stringValue == "iPhone" && (typeSelection == nil || $0["identifier"]?.stringValue == typeSelection)
                }),
                let typeID = type["identifier"]?.stringValue
            else { throw SimulatorFailure("The requested iPhone device type is unsupported by this runtime") }
            let id = UUID()
            let name = "CtrlX · \(type["name"]?.stringValue ?? "iPhone")"
            let reserved = reservedDevices
            let devices: [JSONValue]
            if case .array(let values) = inventory["devices"]?.objectValue?[runtimeID] { devices = values } else { devices = [] }
            let existing = selected?["udid"]?.stringValue ?? devices.compactMap(\.objectValue).first {
                    $0["isAvailable"]?.boolValue == true && $0["state"]?.stringValue == "Shutdown"
                        && $0["deviceTypeIdentifier"]?.stringValue == typeID && $0["name"]?.stringValue == name
                        && $0["udid"]?.stringValue.map { !reserved.contains($0) } == true
                }?["udid"]?.stringValue
            let udid: String
            if let existing {
                udid = existing
            } else {
                udid = try await simctl(["create", name, typeID, runtimeID]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard UUID(uuidString: udid) != nil else { throw SimulatorFailure("simctl did not return a device identifier") }
            pendingDevices.insert(udid)
            defer { pendingDevices.remove(udid) }
            do {
                guard !shuttingDown else { throw SimulatorFailure("Simulator host is shutting down") }
                try await prepare(udid, profile: profile, requires: requires, id: id)
                try Task.checkCancellation()
                guard !shuttingDown else { throw SimulatorFailure("Simulator host is shutting down") }
                try configuration.admit(resourceSnapshot())
                let service = try await startHelper(udid: udid, role: "worker", id: id)
                let worker = try system.connect(service, frames, errors)
                do {
                    // Cold CoreSimulator initialization must finish before the input connection deadline starts.
                    _ = try await worker.request([
                        "command": .string("status"), "timeoutSeconds": .int(30), "readOnly": .bool(true),
                    ])
                    try Task.checkCancellation()
                    guard !shuttingDown else { throw SimulatorFailure("Simulator host is shutting down") }
                    _ = try await worker.request(["command": .string("connect"), "timeoutSeconds": .int(30)])
                    guard !shuttingDown else { throw SimulatorFailure("Simulator host is shutting down") }
                } catch {
                    await worker.invalidate()
                    await stopHelper(service)
                    throw error
                }
                let handle = SimulatorDeviceHandle(id: id, udid: udid, name: name, runtime: runtimeID, deviceType: typeID,
                    worker: worker, profile: profile, requiredFeatures: requires)
                handles[id] = handle
                workerServices[id] = service
                return handle
            } catch {
                // Cleanup must outlive cancellation of the startup task.
                do { try await Task { try await self.shutdownDevice(udid) }.value } catch {
                    logger.warning("Could not shut down the failed simulator: \(error)")
                }
                throw error
            }
        }

        private func startHelper(udid: String, role: String, id: UUID) async throws -> String {
            guard system.isExecutable(helper) else {
                throw SimulatorFailure("Simulator helper is missing. Build and embed CtrlxSimulatorHost first")
            }
            let tool = try await execute("/usr/bin/xcrun", ["--find", "xcodebuild"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard tool.hasPrefix("/"), tool.hasSuffix("/usr/bin/xcodebuild") else {
                throw SimulatorFailure("xcrun did not resolve xcodebuild inside an Xcode developer directory")
            }
            let developer = URL(fileURLWithPath: tool).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
            let parent = try system.inspect(getpid()).owner
            let service = "com.jicezeng.ctrlx.simulator.\(id.uuidString).\(role).\(UUID().uuidString)"
            let directory = root.appendingPathComponent("jobs", isDirectory: true)
            try system.createDirectory(directory)
            let file = directory.appendingPathComponent(service + ".plist")
            var job: [String: Any] = [
                "Label": service, "MachServices": [service: true], "RunAtLoad": true, "ProcessType": "Interactive",
                "ProgramArguments": [
                    helper.path, service, developer, deviceSet.path, udid, role, String(parent.pid), String(parent.startSeconds),
                    String(parent.startMicros),
                ],
                "StandardErrorPath": directory.appendingPathComponent(service + ".log").path,
            ]
            if role == "worker", CommandLine.arguments.contains("--e2e-test") {
                var environment: [String: String] = [:]
                if CommandLine.arguments.contains("--e2e-simulator-frame-trace") {
                    environment["CTRLX_SIMULATOR_FRAME_TRACE"] = "1"
                }
                if CommandLine.arguments.contains("--e2e-simulator-single-write-surfaces") {
                    environment["CTRLX_SIMULATOR_SINGLE_WRITE_SURFACES"] = "1"
                }
                if !environment.isEmpty { job["EnvironmentVariables"] = environment }
            }
            try system.write(PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0), file)
            do { _ = try await execute("/bin/launchctl", ["bootstrap", "gui/\(getuid())", file.path]) } catch {
                do { try system.remove(file) } catch { logger.warning("Could not remove failed simulator job: \(error)") }
                throw error
            }
            jobs[service] = file
            return service
        }

        func snapshot(_ handle: SimulatorDeviceHandle, limit: Int = 200, timeoutSeconds: Double = 5,
                      deadline: ContinuousClock.Instant? = nil) async throws -> [String: JSONValue] {
            guard (1...1000).contains(limit) else { throw SimulatorFailure("Snapshot limit must be 1...1000") }
            return try await inspect(handle, request: ["command": .string("snapshot"), "limit": .int(limit)],
                timeoutSeconds: timeoutSeconds, deadline: deadline)
        }

        func prepareInspector(_ handle: SimulatorDeviceHandle) async throws {
            _ = try await inspect(handle, request: ["command": .string("status"), "readOnly": .bool(true)],
                timeoutSeconds: 30, deadline: nil)
        }

        func applicationActive(_ handle: SimulatorDeviceHandle, processID: Int32,
            deadline: ContinuousClock.Instant) async throws -> Bool {
            let result = try await inspect(handle,
                request: ["command": .string("application-active"), "applicationPID": .int(Int(processID)), "readOnly": .bool(true)],
                timeoutSeconds: 2, deadline: deadline)
            guard result["applicationPID"]?.intValue == Int(processID), let active = result["active"]?.boolValue else {
                throw SimulatorFailure("Invalid application activation response")
            }
            if CommandLine.arguments.contains("--e2e-test"), CommandLine.arguments.contains("--e2e-simulator-activation-trace") {
                let receivedAt = try result["activationTransportReceivedAt"]?.decode(Double.self) ?? 0
                let writeEndedAt = try result["activationTraceWriteEndedAt"]?.decode(Double.self) ?? 0
                FileHandle.standardError.write(Data(String(format:
                    "SimulatorActivation stage=coordinator pid=%d at=%.9f callback=%.9f traceWriteEnd=%.9f active=%d\n",
                    processID, ProcessInfo.processInfo.systemUptime, receivedAt, writeEndedAt, active ? 1 : 0).utf8))
            }
            return active
        }

        func waitForApplicationActive(_ handle: SimulatorDeviceHandle, processID: Int32, owner: SimulatorOwner,
            deadline: ContinuousClock.Instant) async throws {
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw SimulatorFailure("Application launched but its Scene did not become active before the deadline")
                }
                guard try system.inspect(owner.pid).owner == owner else {
                    throw SimulatorFailure("The owning agent process exited or changed identity")
                }
                let active: Bool
                do {
                    active = try await applicationActive(handle, processID: processID, deadline: deadline)
                } catch {
                    throw SimulatorFailure("Application launched; activation could not be confirmed: \(error.localizedDescription)")
                }
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else {
                    throw SimulatorFailure("Application launched but its Scene did not become active before the deadline")
                }
                if active { return }
                try await Task.sleep(for: min(.milliseconds(20), remaining))
            }
        }

        private func inspect(_ handle: SimulatorDeviceHandle, request: [String: JSONValue], timeoutSeconds: Double,
            deadline: ContinuousClock.Instant?) async throws -> [String: JSONValue] {
            func budget(_ maximum: Double) throws -> Double {
                guard let deadline else { return maximum }
                let parts = ContinuousClock.now.duration(to: deadline).components
                let remaining = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                guard remaining >= 0.001 else { throw SimulatorFailure("Observation deadline expired") }
                return min(maximum, remaining)
            }
            guard handles[handle.id] != nil, inspectorBusy.insert(handle.id).inserted else {
                throw SimulatorFailure("The simulator is closed or another accessibility observation is in progress")
            }
            defer { inspectorBusy.remove(handle.id) }
            inspectorExpiry.removeValue(forKey: handle.id)?.cancel()
            let inspector: SimulatorTransport
            var initializing = false
            if let cached = inspectors[handle.id] {
                inspector = cached.transport
            } else {
                let service = try await startHelper(udid: handle.udid, role: "inspector", id: handle.id)
                inspector = try system.connect(service, { $0.finish() }, { _ in })
                guard handles[handle.id] != nil else {
                    await inspector.invalidate()
                    await stopHelper(service)
                    throw SimulatorFailure("The simulator closed while its inspector was starting")
                }
                inspectors[handle.id] = (service, inspector)
                initializing = true
            }
            do {
                if initializing {
                    _ = try await inspector.request([
                        "command": .string("status"), "timeoutSeconds": .double(try budget(30)), "readOnly": .bool(true),
                    ])
                }
                try Task.checkCancellation()
                guard handles[handle.id] != nil, !shuttingDown else {
                    throw SimulatorFailure("The simulator closed while its inspector was starting")
                }
                var boundedRequest = request
                boundedRequest["timeoutSeconds"] = .double(try budget(timeoutSeconds))
                let result = try await inspector.request(boundedRequest)
                inspectorExpiry[handle.id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    await self?.expireInspector(handle.id)
                }
                return result
            } catch {
                if let removed = inspectors.removeValue(forKey: handle.id) {
                    await removed.transport.invalidate()
                    await stopHelper(removed.service)
                }
                throw error
            }
        }

        private func expireInspector(_ id: UUID) async {
            inspectorExpiry.removeValue(forKey: id)
            if let removed = inspectors.removeValue(forKey: id) {
                await removed.transport.invalidate()
                await stopHelper(removed.service)
            }
        }

        func paste(_ handle: SimulatorDeviceHandle, text: String) async throws {
            let directory = root.appendingPathComponent("artifacts", isDirectory: true)
            try system.createDirectory(directory)
            let file = directory.appendingPathComponent(UUID().uuidString + ".txt")
            try system.write(Data(text.utf8), file)
            defer {
                do { try system.remove(file) } catch { logger.warning("Could not remove simulator paste input: \(error)") }
            }
            _ = try await execute(
                "/bin/sh",
                [
                    "-c", "exec /usr/bin/xcrun simctl --set \"$1\" pbcopy \"$2\" < \"$3\"", "ctrlx-simulator-paste", deviceSet.path,
                    handle.udid, file.path,
                ])
        }

        func geometry(_ handle: SimulatorDeviceHandle, timeoutSeconds: Double = 10) async throws -> SimulatorGeometry {
            let result = try await handle.worker.request([
                "command": .string("geometry"), "timeoutSeconds": .double(timeoutSeconds), "readOnly": .bool(true),
            ])
            let geometry = try JSONDecoder().decode(SimulatorGeometry.self, from: JSONEncoder().encode(result))
            guard geometry.isValid else { throw SimulatorFailure("Invalid simulator geometry") }
            return geometry
        }

        func screenshot(_ handle: SimulatorDeviceHandle) async throws -> [String: JSONValue] {
            try await handle.worker.request(["command": .string("screenshot"), "timeoutSeconds": .int(10)])
        }

        func install(_ handle: SimulatorDeviceHandle, app: String) async throws {
            let url = URL(fileURLWithPath: app)
            guard url.path == app, url.pathExtension == "app" else {
                throw SimulatorFailure("Install requires an absolute simulator .app path")
            }
            let plist =
                try PropertyListSerialization.propertyList(from: system.read(url.appendingPathComponent("Info.plist")), format: nil)
                as? [String: Any]
            guard (plist?["CFBundleSupportedPlatforms"] as? [String])?.contains("iPhoneSimulator") == true else {
                throw SimulatorFailure("App is not built for the iOS Simulator")
            }
            _ = try await simctl(["install", handle.udid, app], timeout: 120)
        }

        func uninstall(_ handle: SimulatorDeviceHandle, bundle: String) async throws {
            try validateSimulatorBundle(bundle)
            _ = try await simctl(["uninstall", handle.udid, bundle], timeout: 120)
        }

        func startRecording(_ handle: SimulatorDeviceHandle, options: SimulatorRecordingOptions) async throws -> [String: JSONValue] {
            guard !recordingStarts.contains(handle.id) else { throw SimulatorFailure("Recording is already starting on this device") }
            recordingStarts.insert(handle.id)
            defer { recordingStarts.remove(handle.id) }
            if let recorder = recordings[handle.id] {
                let state = await recorder.status()["state"]?.stringValue
                guard state == "completed" || state == "failed" else { throw SimulatorFailure("This device already has an active recording") }
            }
            try Task.checkCancellation()
            guard !shuttingDown, handles[handle.id] != nil else { throw SimulatorFailure("Simulator closed before recording could start") }
            let reserve = try configuration().diskReserveMiB
            let available = try resources.read(options.output.deletingLastPathComponent()).freeDiskBytes
            guard available >= UInt64(reserve) * 1024 * 1024 + UInt64(SimulatorRecordingOptions.maximumBytes) else {
                throw SimulatorFailure("Not enough recording disk space above the configured reserve")
            }
            let recorder = try recordingClient.make(deviceSet, handle.udid, options)
            recordings[handle.id] = recorder
            return try await recorder.start()
        }

        func recordingStatus(_ handle: SimulatorDeviceHandle) async -> [String: JSONValue] {
            guard let recorder = recordings[handle.id] else { return ["state": .string("idle")] }
            return await recorder.status()
        }

        func stopRecording(_ handle: SimulatorDeviceHandle) async -> [String: JSONValue] {
            guard let recorder = recordings[handle.id] else { return ["state": .string("idle")] }
            return await recorder.stop()
        }

        func close(_ handle: SimulatorDeviceHandle, shutdown: Bool) async throws {
            guard handles.removeValue(forKey: handle.id) != nil else { return }
            pendingDevices.insert(handle.udid)
            defer { pendingDevices.remove(handle.udid) }
            if let recorder = recordings.removeValue(forKey: handle.id) {
                let result = await recorder.stop(closing: true)
                if let error = result["error"]?.stringValue { logger.warning("Simulator recording cleanup: \(error)") }
            }
            do { _ = try await handle.worker.request(["command": .string("cancel")]) } catch {
                logger.warning("Simulator input cleanup failed: \(error)")
            }
            await handle.worker.invalidate()
            if let service = workerServices.removeValue(forKey: handle.id) { await stopHelper(service) }
            if let inspector = inspectors.removeValue(forKey: handle.id) {
                await inspector.transport.invalidate()
                await stopHelper(inspector.service)
            }
            inspectorExpiry.removeValue(forKey: handle.id)?.cancel()
            if shutdown { try await shutdownDevice(handle.udid) }
        }

        private func shutdownDevice(_ udid: String) async throws {
            do {
                _ = try await simctl(["shutdown", udid])
                failedShutdownDevices.remove(udid)
            } catch {
                failedShutdownDevices.insert(udid)
                throw error
            }
        }

        private func recoverFailedShutdowns() async throws {
            guard !failedShutdownDevices.isEmpty else { return }
            let inventory = try await inventory()
            let devices = inventory["devices"]?.objectValue?.values.flatMap { value -> [JSONValue] in
                guard case .array(let devices) = value else { return [] }
                return devices
            }.compactMap(\.objectValue) ?? []
            for udid in failedShutdownDevices.sorted() {
                let state = devices.first { $0["udid"]?.stringValue == udid }?["state"]?.stringValue
                switch state {
                case "Shutdown": failedShutdownDevices.remove(udid)
                case "Booted": try await shutdownDevice(udid)
                default: throw SimulatorFailure("Simulator \(udid) has unfinished shutdown (\(state ?? "unknown state")); try again after it finishes")
                }
            }
            guard failedShutdownDevices.isEmpty else { throw SimulatorFailure("Simulator shutdown recovery is incomplete") }
        }

        func prepareForShutdown() async {
            shuttingDown = true
            for task in bootTasks.values { task.cancel() }
            for task in storageTasks.values { task.cancel() }
            // Cancel both groups before waiting: either can be holding the shared admission lock.
            await withTaskGroup(of: Void.self) { group in
                for recorder in recordings.values { group.addTask { _ = await recorder.stop(closing: true) } }
            }
        }

        func shutdown() async {
            let starting = Array(bootTasks.values)
            let changingStorage = Array(storageTasks.values)
            await prepareForShutdown()
            for task in changingStorage { _ = await task.result }
            for task in starting { _ = await task.result }
            await acquireBoot()
            defer { releaseBoot() }
            let active = Array(handles.values)
            await withTaskGroup(of: Void.self) { group in
                for handle in active {
                    group.addTask {
                        do { try await self.close(handle, shutdown: true) } catch {
                            self.logger.warning("Could not close a simulator during shutdown: \(error)")
                        }
                    }
                }
            }
            do { try await recoverFailedShutdowns() } catch {
                logger.warning("Could not recover a simulator shutdown: \(error)")
            }
        }

        private func stopHelper(_ service: String) async {
            guard let file = jobs.removeValue(forKey: service) else { return }
            do {
                let result = try await runner.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(service)"], nil, 10)
                if !result.isSuccess { logger.debug("Simulator helper already stopped: \(service)") }
                try system.remove(file)
            } catch { logger.warning("Simulator helper cleanup failed: \(error)") }
        }
    }
#endif
