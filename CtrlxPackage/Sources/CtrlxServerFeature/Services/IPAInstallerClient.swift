#if os(macOS)
    import CryptoKit
    import CtrlxCommon
    import Dependencies
    import DependenciesMacros
    import Foundation
    import ZIPFoundation

    struct IPAInstallationError: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? {
            message
        }
    }

    struct IPAInstallationDevice: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let systemVersion: String?
    }

    struct IPAInstallationPackage: Equatable, Sendable {
        let name: String
        let bundleID: String
        let version: String
        let bytes: Int
        let sha256: String
    }

    typealias IPAInstallationOutput = @MainActor @Sendable (String) -> Void

    @DependencyClient
    struct IPAInstallerClient: Sendable {
        var inspect: @Sendable (URL) async throws -> IPAInstallationPackage
        var devices: @Sendable () async throws -> [IPAInstallationDevice]
        var install: @Sendable (URL, IPAInstallationPackage, String, @escaping IPAInstallationOutput) async throws -> Void
    }

    extension IPAInstallerClient: DependencyKey {
        static let liveValue = Self(
            inspect: { try await IPAInstaller.shared.inspect($0) },
            devices: { try await IPAInstaller.shared.devices() },
            install: { try await IPAInstaller.shared.install($0, expected: $1, deviceID: $2, output: $3) }
        )
    }

    actor IPAInstaller {
        static let shared = IPAInstaller()
        private var installation: Task<Void, Error>?
        private let directory: URL

        init(directory: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/DeviceInstaller")) {
            self.directory = directory
        }

        static func validDeviceID(_ id: String) -> Bool {
            (16...64).contains(id.utf8.count) && id.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 45
            }
        }

        private func bundledTool(_ name: String) throws -> URL {
            let tool = directory.appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: tool.path) else {
                throw IPAInstallationError(message: "The bundled iPhone installer is missing. Rebuild or update CtrlX.")
            }
            return tool
        }

        func inspect(_ url: URL) throws -> IPAInstallationPackage {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            guard url.isFileURL, url.pathExtension.lowercased() == "ipa" else {
                throw IPAInstallationError(message: "Choose a local .ipa file.")
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 2 * 1_024 * 1_024 * 1_024 else {
                throw IPAInstallationError(message: "Choose a regular IPA file up to 2 GiB.")
            }
            let archive: Archive
            do {
                archive = try Archive(url: url, accessMode: .read)
            } catch {
                throw IPAInstallationError(message: "The IPA archive is damaged or unreadable. Choose a valid signed IPA file.")
            }
            var candidates: [Entry] = []
            var count = 0
            for entry in archive {
                count += 1
                guard count <= 200_000 else { throw IPAInstallationError(message: "The IPA contains too many files.") }
                let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
                if parts.count == 3, parts[0] == "Payload", parts[1].hasSuffix(".app"), parts[2] == "Info.plist" {
                    candidates.append(entry)
                }
            }
            guard
                candidates.count == 1, let entry = candidates.first, entry.type == .file,
                entry.uncompressedSize <= 1_024 * 1_024 else {
                throw IPAInstallationError(message: "The IPA must contain exactly one iPhone app in Payload.")
            }
            var data = Data()
            let crc = try archive.extract(entry) { chunk in
                guard data.count + chunk.count <= 1_024 * 1_024 else { throw IPAInstallationError(message: "The app metadata is too large.") }
                data.append(chunk)
            }
            guard
                crc == entry.checksum,
                let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty,
                (info["CFBundleSupportedPlatforms"] as? [String])?.contains("iPhoneOS") == true else {
                throw IPAInstallationError(message: "The IPA does not contain valid iPhone app metadata. Simulator apps are not supported.")
            }
            let app = String(entry.path.dropLast("Info.plist".count))
            guard
                archive[app + "_CodeSignature/CodeResources"]?.type == .file,
                archive[app + "embedded.mobileprovision"]?.type == .file else {
                throw IPAInstallationError(message: "Use a signed Development, Ad Hoc or Enterprise IPA with an embedded provisioning profile.")
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256()
            while let chunk = try file.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
                try Task.checkCancellation()
                hash.update(data: chunk)
            }
            return .init(
                name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? bundleID,
                bundleID: bundleID,
                version: info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "—",
                bytes: size, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined()
            )
        }

        func devices() async throws -> [IPAInstallationDevice] {
            @Dependency(ProcessRunner.self) var process
            let tool = try bundledTool("idevice_id")
            let result = try await process.runBoundedCancellable(tool.path, ["--list"], ["PATH": "/usr/bin:/bin"], 10, 64 * 1_024)
            guard result.isSuccess else { throw IPAInstallationError(message: result.stderrString) }
            let ids = result.stdoutString.split(whereSeparator: \.isWhitespace).map(String.init)
            guard ids.count <= 32, ids.allSatisfy(Self.validDeviceID) else {
                throw IPAInstallationError(message: "The iPhone installer returned invalid device identifiers.")
            }
            let infoTool = try bundledTool("ideviceinfo")
            var devices: [IPAInstallationDevice] = []
            for id in ids {
                try Task.checkCancellation()
                // A simple query does not pair automatically. Pairing remains
                // an explicit confirmation on the phone when installing.
                let details = try await process.runBoundedCancellable(infoTool.path, ["--udid", id, "--simple", "--xml"], ["PATH": "/usr/bin:/bin"], 5, 256 * 1_024)
                let info = details.isSuccess ? (try? PropertyListSerialization.propertyList(from: details.stdout, format: nil)) as? [String: Any] : nil
                devices.append(.init(id: id, name: info?["DeviceName"] as? String ?? "iPhone · \(id.suffix(6))", systemVersion: info?["ProductVersion"] as? String))
            }
            return devices
        }

        func install(_ url: URL, expected: IPAInstallationPackage, deviceID: String, output: @escaping IPAInstallationOutput) async throws {
            guard installation == nil else { throw IPAInstallationError(message: "Another IPA installation is running on this Mac.") }
            guard Self.validDeviceID(deviceID) else { throw IPAInstallationError(message: "Select a valid USB device.") }
            try Task.checkCancellation()
            let task = Task { try await performInstall(url, expected: expected, deviceID: deviceID, output: output) }
            installation = task
            defer { installation = nil }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }

        func shutdown() async {
            guard let installation else { return }
            installation.cancel()
            // The caller receives the result; shutdown waits for process and file cleanup.
            _ = await installation.result
        }

        private func performInstall(_ url: URL, expected: IPAInstallationPackage, deviceID: String, output: @escaping IPAInstallationOutput) async throws {
            try Task.checkCancellation()
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-ipa-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            await output("Preparing a private copy of the IPA…\n")
            let package = directory.appendingPathComponent("App.ipa")
            try FileManager.default.copyItem(at: url, to: package)
            guard try inspect(package) == expected else {
                throw IPAInstallationError(message: "The IPA changed after selection. Choose it again before installing.")
            }
            try Task.checkCancellation()
            guard try await devices().contains(where: { $0.id == deviceID }) else {
                throw IPAInstallationError(message: "The selected iPhone is no longer connected by USB. Reconnect it and refresh devices.")
            }
            try await ensurePairing(deviceID, output: output)
            try Task.checkCancellation()
            await output("Transferring and installing on the selected USB device…\n")
            let capture = IPAInstallationLog()
            @Dependency(AgentCLIProcessClient.self) var process
            let status = try await process.run(
                bundledTool("ideviceinstaller").path,
                ["--udid", deviceID, "install", package.path],
                ["PATH": "/usr/bin:/bin"],
                600
            ) { text in
                await capture.append(text)
                await output(text)
            }
            let log = await capture.text
            guard status == 0, log.contains("Install: Complete") else {
                throw IPAInstallationError(message: "The iPhone did not confirm installation. See the installation log and check device trust, the signature/provisioning profile and Developer Mode. Installation was not retried.")
            }
        }

        private func ensurePairing(_ deviceID: String, output: @escaping IPAInstallationOutput) async throws {
            @Dependency(ProcessRunner.self) var process
            let tool = try bundledTool("idevicepair")
            await output("Checking device pairing…\n")
            let validation = try await process.runBoundedCancellable(tool.path, ["--udid", deviceID, "validate"], ["PATH": "/usr/bin:/bin"], 10, 64 * 1_024)
            try Task.checkCancellation()
            guard !validation.isSuccess else { return }
            await output("Unlock your iPhone and tap Trust if requested…\n")
            try Task.checkCancellation()
            let pairing = try await process.runBoundedCancellable(tool.path, ["--udid", deviceID, "pair"], ["PATH": "/usr/bin:/bin"], 30, 64 * 1_024)
            await output(pairing.stdoutString + pairing.stderrString)
            guard pairing.isSuccess else {
                throw IPAInstallationError(message: "Could not pair with the iPhone. Unlock it, tap Trust if asked, then click Install again. The IPA has not been sent.")
            }
        }
    }

    private actor IPAInstallationLog {
        private(set) var text = ""
        func append(_ value: String) {
            text = String((text + value).suffix(64 * 1_024))
        }
    }
#endif
