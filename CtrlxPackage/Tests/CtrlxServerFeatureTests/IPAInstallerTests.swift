#if os(macOS)
    import CtrlxCommon
    import Darwin
    import Dependencies
    import Foundation
    import Synchronization
    import Testing
    import ZIPFoundation
    @testable import CtrlxServerFeature

    struct IPAInstallerTests {
        private let id = "00008110-0011223344556677"

        private func directory() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ipa-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            for name in ["idevice_id", "ideviceinfo", "ideviceinstaller", "idevicepair"] {
                #expect(FileManager.default.createFile(atPath: url.appendingPathComponent(name).path, contents: Data(), attributes: [.posixPermissions: 0o700]))
            }
            return url
        }

        private func package(_ root: URL, platform: String = "iPhoneOS", provisioned: Bool = true, extraApp: Bool = false) throws -> URL {
            let url = root.appendingPathComponent("App.ipa")
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            let archive = try Archive(url: url, accessMode: .create)
            let info = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "com.ctrlx.ipa-fixture",
                "CFBundleDisplayName": "安装测试",
                "CFBundleShortVersionString": "1.0",
                "CFBundleSupportedPlatforms": [platform],
            ], format: .binary, options: 0)
            var entries = [
                "Payload/Fixture.app/Info.plist": info,
                "Payload/Fixture.app/_CodeSignature/CodeResources": Data("fixture, not a real signature".utf8),
                "Payload/Fixture.app/PlugIns/Extension.appex/Info.plist": info,
            ]
            if provisioned {
                entries["Payload/Fixture.app/embedded.mobileprovision"] = Data("fixture".utf8)
            }
            if extraApp {
                entries["Payload/Other.app/Info.plist"] = info
            }
            for (name, data) in entries {
                try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count)) { position, count in
                    data.subdata(in: Int(position)..<(Int(position) + count))
                }
            }
            return url
        }

        private func runner(devices: String? = nil) -> ProcessRunner {
            let ids = devices ?? id
            var process = ProcessRunner(run: { _, _, _, _ in .init(exitCode: 1, stdout: Data(), stderr: Data()) }, runBounded: { _, words, _, _, _ in
                if words == ["--list"] {
                    return .init(exitCode: 0, stdout: Data(ids.utf8), stderr: Data())
                }
                let info = try PropertyListSerialization.data(fromPropertyList: ["DeviceName": "Fixture iPhone", "ProductVersion": "18.0"], format: .xml, options: 0)
                return .init(exitCode: 0, stdout: info, stderr: Data())
            })
            process.runBoundedCancellable = process.runBounded
            return process
        }

        @Test
        func readsOnlyTheMainDeviceAppAndHashesTheIPA() async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = try package(root)
            let info = try await IPAInstaller(directory: root).inspect(url)
            #expect(info.name == "安装测试")
            #expect(info.bundleID == "com.ctrlx.ipa-fixture")
            #expect(info.version == "1.0")
            #expect(info.bytes > 0)
            #expect(info.sha256.count == 64)
        }

        @Test(arguments: ["simulator", "missing-profile", "multiple-apps", "not-a-zip"])
        func rejectsUnsupportedPackagesBeforeDeviceWrites(_ kind: String) async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = try package(
                root,
                platform: kind == "simulator" ? "iPhoneSimulator" : "iPhoneOS",
                provisioned: kind != "missing-profile",
                extraApp: kind == "multiple-apps"
            )
            if kind == "not-a-zip" {
                try Data("not an IPA".utf8).write(to: url)
            }
            await #expect(throws: (any Error).self) { try await IPAInstaller(directory: root).inspect(url) }
        }

        @Test
        func listsUSBDevicesThroughTheBundledTools() async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            try await withDependencies {
                $0[ProcessRunner.self] = runner()
            } operation: {
                let devices = try await IPAInstaller(directory: root).devices()
                #expect(devices == [.init(id: id, name: "Fixture iPhone", systemVersion: "18.0")])
            }
            #expect(!IPAInstaller.validDeviceID("--network"))
            #expect(!IPAInstaller.validDeviceID("../other"))
        }

        @Test(arguments: ["complete", "changed-file", "disconnected", "failed", "no-confirmation"])
        @MainActor
        func installationUsesAnImmutableCopyAndRequiresConfirmation(_ kind: String) async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = try package(root)
            let service = IPAInstaller(directory: root)
            let info = try await service.inspect(url)
            if kind == "changed-file" {
                try Data("changed after selection".utf8).write(to: url)
            }
            let calls = Mutex(0)
            let staged = Mutex<String?>(nil)
            try await withDependencies {
                $0[ProcessRunner.self] = runner(devices: kind == "disconnected" ? "" : nil)
                $0[AgentCLIProcessClient.self].run = { executable, words, _, _, output in
                    calls.withLock { $0 += 1 }
                    #expect(executable == root.appendingPathComponent("ideviceinstaller").path)
                    #expect(Array(words.prefix(3)) == ["--udid", id, "install"])
                    let path = try #require(words.last)
                    #expect(path != url.path)
                    #expect(FileManager.default.fileExists(atPath: path))
                    staged.withLock { $0 = path }
                    if kind == "complete" {
                        await output("Install: Com")
                        await output("plete\n")
                        return 0
                    }
                    await output("ERROR: invalid signature\n")
                    return kind == "no-confirmation" ? 0 : 1
                }
            } operation: {
                if kind == "complete" {
                    try await service.install(url, expected: info, deviceID: id, output: { _ in })
                } else {
                    await #expect(throws: (any Error).self) {
                        try await service.install(url, expected: info, deviceID: id, output: { _ in })
                    }
                }
            }
            #expect(calls.withLock { $0 } == (["changed-file", "disconnected"].contains(kind) ? 0 : 1))
            if let path = staged.withLock({ $0 }) {
                #expect(!FileManager.default.fileExists(atPath: path))
            }
        }

        @Test @MainActor
        func shutdownCancelsTheInstallerAndRejectsConcurrentWrites() async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = try package(root)
            let service = IPAInstaller(directory: root)
            let info = try await service.inspect(url)
            let ready = AsyncStream<Void>.makeStream()
            let staged = Mutex<String?>(nil)
            try await withDependencies {
                $0[ProcessRunner.self] = runner()
                $0[AgentCLIProcessClient.self].run = { _, words, _, _, _ in
                    staged.withLock { $0 = words.last }
                    ready.continuation.yield(())
                    try await Task.sleep(for: .seconds(30))
                    return 0
                }
            } operation: {
                let task = Task { try await service.install(url, expected: info, deviceID: id, output: { _ in }) }
                for await _ in ready.stream {
                    break
                }
                await #expect(throws: IPAInstallationError.self) {
                    try await service.install(url, expected: info, deviceID: id, output: { _ in })
                }
                await service.shutdown()
                await #expect(throws: CancellationError.self) { try await task.value }
            }
            let path = try #require(staged.withLock { $0 })
            #expect(!FileManager.default.fileExists(atPath: path))
        }

        @Test(arguments: ["paired", "repaired", "denied"])
        @MainActor
        func verifiesPairingAndStopsBeforeTransferIfTrustIsUnavailable(_ kind: String) async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = try package(root)
            let service = IPAInstaller(directory: root)
            let info = try await service.inspect(url)
            let pairingCommands = Mutex<[String]>([])
            let installs = Mutex(0)
            var process = runner()
            let base = process.runBoundedCancellable
            process.runBoundedCancellable = { executable, words, environment, timeout, limit in
                if executable.hasSuffix("/idevicepair") {
                    #expect(words.first == "--udid" && words[1] == id)
                    let command = try #require(words.last)
                    pairingCommands.withLock { $0.append(command) }
                    let succeeds = command == "validate" ? kind == "paired" : kind == "repaired"
                    return .init(exitCode: succeeds ? 0 : 1, stdout: Data(), stderr: Data("trust required".utf8))
                }
                return try await base(executable, words, environment, timeout, limit)
            }
            try await withDependencies {
                $0[ProcessRunner.self] = process
                $0[AgentCLIProcessClient.self].run = { _, _, _, _, output in
                    installs.withLock { $0 += 1 }
                    await output("Install: Complete\n")
                    return 0
                }
            } operation: {
                if kind == "denied" {
                    await #expect(throws: IPAInstallationError.self) {
                        try await service.install(url, expected: info, deviceID: id, output: { _ in })
                    }
                } else {
                    try await service.install(url, expected: info, deviceID: id, output: { _ in })
                }
            }
            #expect(pairingCommands.withLock { $0 } == (kind == "paired" ? ["validate"] : ["validate", "pair"]))
            #expect(installs.withLock { $0 } == (kind == "denied" ? 0 : 1))
        }

        @Test(.timeLimit(.minutes(1))) @MainActor
        func cancellationAfterFailedValidationDoesNotStartPairing() async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = try package(root)
            let service = IPAInstaller(directory: root)
            let info = try await service.inspect(url)
            let taskSlot = Mutex<Task<Void, Error>?>(nil)
            let commands = Mutex<[String]>([])
            var process = runner()
            let base = process.runBoundedCancellable
            process.runBoundedCancellable = { executable, words, environment, timeout, limit in
                if executable.hasSuffix("/idevicepair") {
                    let command = try #require(words.last)
                    commands.withLock { $0.append(command) }
                    if command == "validate" {
                        // Model a command that returns a failure even after cancellation.
                        taskSlot.withLock { $0?.cancel() }
                    }
                    return .init(exitCode: 1, stdout: Data(), stderr: Data())
                }
                return try await base(executable, words, environment, timeout, limit)
            }
            await withDependencies {
                $0[ProcessRunner.self] = process
            } operation: {
                let task = Task { try await service.install(url, expected: info, deviceID: id, output: { _ in }) }
                taskSlot.withLock { $0 = task }
                await #expect(throws: CancellationError.self) { try await task.value }
            }
            #expect(commands.withLock { $0 } == ["validate"])
        }

        @Test(.timeLimit(.minutes(1)), arguments: ["idevice_id", "ideviceinfo", "validate", "pair"])
        @MainActor
        func cancellationStopsPreparationProcessesWithoutStartingLaterCommands(_ stage: String) async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = try package(root)
            let infoData = try PropertyListSerialization.data(fromPropertyList: ["DeviceName": "Fixture iPhone"], format: .xml, options: 0)
            try infoData.write(to: root.appendingPathComponent("device.plist"))
            let script = """
            #!/bin/sh
            cd "${0%/*}" || exit 1
            step="${0##*/}"
            if [ "$step" = idevicepair ]; then step="$3"; fi
            printf '%s\\n' "$step" >> commands
            if [ "$step" = "\(stage)" ]; then
                trap '' TERM
                /bin/sleep 30 & child=$!
                printf '%s %s' "$$" "$child" > pids.tmp
                /bin/mv pids.tmp pids
                wait
                exit 1
            fi
            case "$step" in
                idevice_id) printf '%s\\n' '\(id)' ;;
                ideviceinfo) /bin/cat device.plist ;;
                validate) \(stage == "pair" ? "exit 1" : "exit 0") ;;
                pair) exit 0 ;;
                *) printf 'Install: Complete\\n' ;;
            esac
            """
            for name in ["idevice_id", "ideviceinfo", "idevicepair", "ideviceinstaller"] {
                try Data(script.utf8).write(to: root.appendingPathComponent(name))
            }
            let service = IPAInstaller(directory: root)
            let info = try await service.inspect(url)
            try await withDependencies {
                $0[ProcessRunner.self] = .liveValue
                $0[AgentCLIProcessClient.self] = .liveValue
                $0[LoginShellPath.self].resolve = { "/usr/bin:/bin" }
                $0.continuousClock = ContinuousClock()
            } operation: {
                let task = Task { try await service.install(url, expected: info, deviceID: id, output: { _ in }) }
                defer { task.cancel() }
                let ready = root.appendingPathComponent("pids")
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                let pids = try String(contentsOf: ready, encoding: .utf8).split(separator: " ").compactMap { Int32($0) }
                try #require(pids.count == 2)
                #expect(getpgid(pids[0]) == pids[0])
                #expect(getpgid(pids[1]) == pids[0])
                let cancelled = ContinuousClock.now
                task.cancel()
                await #expect(throws: CancellationError.self) { try await task.value }
                #expect(cancelled.duration(to: .now) < .seconds(2))
                for pid in pids {
                    let reapDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                    while kill(pid, 0) == 0, ContinuousClock.now < reapDeadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    #expect(kill(pid, 0) == -1 && errno == ESRCH)
                }
            }
            let commands = try String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8).split(separator: "\n").map(String.init)
            let stages = ["idevice_id", "ideviceinfo", "validate", "pair"]
            let index = try #require(stages.firstIndex(of: stage))
            #expect(commands == Array(stages.prefix(index + 1)))
        }
    }

#endif
