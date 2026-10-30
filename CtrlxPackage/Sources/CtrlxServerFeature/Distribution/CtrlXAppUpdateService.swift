#if os(macOS)
    import AppKit
    import CryptoKit
    import CtrlxCommon
    import CtrlxNetworking
    import Darwin
    import Foundation
    import Observation

    enum CtrlXAppUpdateError: LocalizedError, Equatable {
        case insecureURL
        case invalidResponse
        case responseTooLarge
        case malformedInstaller
        case invalidSignature
        case missingSigningKey
        case updateUnavailable
        case updateChanged
        case installationUnavailable(String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .insecureURL:
                "The CtrlX update endpoint must use HTTPS."
            case .invalidResponse:
                "The CtrlX update endpoint returned an invalid response."
            case .responseTooLarge:
                "The CtrlX update manifest exceeded the allowed size."
            case .malformedInstaller:
                "The CtrlX update manifest is malformed."
            case .invalidSignature:
                "The CtrlX installer signature is missing or invalid."
            case .missingSigningKey:
                "This CtrlX build has no installer signing key."
            case .updateUnavailable:
                "This CtrlX build has no verified update to install."
            case .updateChanged:
                "The available CtrlX update changed. Check again before installing."
            case let .installationUnavailable(reason):
                reason
            case let .launchFailed(message):
                "Could not start the CtrlX installer: \(message)"
            }
        }
    }

    /// Checks and applies desktop updates through the same verified installer
    /// used by `ctrlx-install`.
    ///
    /// The Host owns the fixed HTTPS endpoint. Viewers only observe the state
    /// and request the exact version/build that the Host already verified.
    @Observable
    @MainActor
    final class CtrlXAppUpdateService {
        struct InstallerRelease: Equatable {
            let version: String
            let build: String
            let buildStamp: String
            let sourceRevision: String
            let dmgName: String
            let dmgSHA256: String
            let downloadBase: String
        }

        struct InstallerScript: Equatable {
            let body: String
            let signature: Data
        }

        struct DownloadProgress: Equatable {
            let downloadedBytes: Int64
            let totalBytes: Int64

            var fraction: Double {
                guard totalBytes > 0 else { return 0 }
                return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
            }

            var percent: Int {
                if isComplete {
                    return 100
                }
                return min(99, max(0, Int(fraction * 100)))
            }

            var isComplete: Bool {
                totalBytes > 0 && downloadedBytes >= totalBytes
            }
        }

        typealias ScriptLoader = @MainActor (URL) async throws -> InstallerScript
        typealias InstallerLauncher = @MainActor (URL, URL, URL) throws -> Int32?
        typealias DownloadSizeLoader = @MainActor (URL) async -> Int64?

        static let installerURL = URL(
            string: "https://ctrlx-1256844776.cos.ap-guangzhou.myqcloud.com/macos/mac.sh"
        )!
        static let maximumManifestBytes = 256 * 1_024
        static let maximumSignatureBytes = 4 * 1_024
        static let installerRequestTimeout: TimeInterval = 20

        private static let manifestKeys = [
            "CTRLX_DOWNLOAD_BASE",
            "CTRLX_DMG_NAME",
            "CTRLX_DMG_SHA256",
            "CTRLX_VERSION",
            "CTRLX_BUILD",
            "CTRLX_BUILD_STAMP",
            "CTRLX_SOURCE_REVISION",
        ]

        private let buildInfo: AppBuildInfo
        private let installerURL: URL
        private let signingKey: Curve25519.Signing.PublicKey?
        private let loadScript: ScriptLoader
        private let installationPreflight: @MainActor () -> String?
        private let launchInstaller: InstallerLauncher
        private let loadDownloadSize: DownloadSizeLoader
        private let now: @MainActor () -> Date
        private let updateDirectory: URL
        private let logDirectory: URL

        @ObservationIgnored
        var onStateChange: (@MainActor () -> Void)?
        @ObservationIgnored
        private var installerMonitorTask: Task<Void, Never>?

        private(set) var isInstalling = false
        private(set) var installationError: String?
        private(set) var downloadProgress: DownloadProgress?

        var state: CtrlXAppUpdateState {
            didSet {
                guard state != oldValue else { return }
                onStateChange?()
            }
        }

        var isConfigured: Bool {
            installerURL.scheme?.lowercased() == "https" && signingKey != nil
        }

        init(
            buildInfo: AppBuildInfo = .current,
            installerURL: URL = CtrlXAppUpdateService.installerURL,
            signingKey: Curve25519.Signing.PublicKey? = CtrlXAppUpdateService.bundledSigningKey,
            loadScript: @escaping ScriptLoader = { url in
                try await CtrlXAppUpdateService.fetchInstallerScript(from: url)
            },
            installationPreflight: @escaping @MainActor () -> String? = {
                CtrlXAppUpdateService.defaultInstallationPreflight()
            },
            launchInstaller: @escaping InstallerLauncher = { scriptURL, logURL, downloadRoot in
                try CtrlXAppUpdateService.launchDetachedInstaller(
                    scriptURL: scriptURL,
                    logURL: logURL,
                    downloadRoot: downloadRoot
                )
            },
            loadDownloadSize: @escaping DownloadSizeLoader = { url in
                await CtrlXAppUpdateService.fetchDownloadSize(from: url)
            },
            now: @escaping @MainActor () -> Date = { Date() },
            updateDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/CtrlX/Updates", isDirectory: true),
            logDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/CtrlX/Installer", isDirectory: true)
        ) {
            self.buildInfo = buildInfo
            self.installerURL = installerURL
            self.signingKey = signingKey
            self.loadScript = loadScript
            self.installationPreflight = installationPreflight
            self.launchInstaller = launchInstaller
            self.loadDownloadSize = loadDownloadSize
            self.now = now
            self.updateDirectory = updateDirectory
            self.logDirectory = logDirectory
            self.state = CtrlXAppUpdateState(
                phase: .idle,
                currentVersion: buildInfo.version ?? "",
                currentBuild: buildInfo.buildNumber
            )
        }

        /// Fetch the installer manifest and update the Host-owned availability
        /// snapshot. A transient failure keeps a previously verified update
        /// visible instead of replacing it with an error-only state.
        func refresh() async {
            guard state.phase != .checking, state.phase != .installing, !isInstalling else { return }
            guard installerURL.scheme?.lowercased() == "https" else {
                setState(phase: .failed, error: CtrlXAppUpdateError.insecureURL.localizedDescription)
                return
            }
            guard signingKey != nil else {
                setState(phase: .failed, error: CtrlXAppUpdateError.missingSigningKey.localizedDescription)
                return
            }

            let previous = state
            setState(
                phase: .checking,
                latestVersion: previous.latestVersion,
                latestBuild: previous.latestBuild,
                latestBuildStamp: previous.latestBuildStamp,
                checkedAt: previous.checkedAt,
                canInstall: previous.canInstall,
                error: nil
            )

            do {
                let release = try await verifiedRelease(from: installerURL)
                let preflight = installationPreflight()
                if isNewer(release) {
                    state = CtrlXAppUpdateState(
                        phase: .available,
                        currentVersion: currentVersion,
                        currentBuild: buildInfo.buildNumber,
                        latestVersion: release.version,
                        latestBuild: release.build,
                        latestBuildStamp: release.buildStamp,
                        checkedAt: now(),
                        canInstall: preflight == nil,
                        error: preflight
                    )
                } else {
                    state = CtrlXAppUpdateState(
                        phase: .upToDate,
                        currentVersion: currentVersion,
                        currentBuild: buildInfo.buildNumber,
                        latestVersion: release.version,
                        latestBuild: release.build,
                        latestBuildStamp: release.buildStamp,
                        checkedAt: now(),
                        canInstall: false
                    )
                }
            } catch {
                if previous.phase == .available, previous.latestVersion != nil {
                    state = CtrlXAppUpdateState(
                        phase: .available,
                        currentVersion: previous.currentVersion,
                        currentBuild: previous.currentBuild,
                        latestVersion: previous.latestVersion,
                        latestBuild: previous.latestBuild,
                        latestBuildStamp: previous.latestBuildStamp,
                        checkedAt: previous.checkedAt,
                        canInstall: previous.canInstall,
                        error: Self.userFacingMessage(error)
                    )
                } else {
                    state = CtrlXAppUpdateState(
                        phase: .failed,
                        currentVersion: currentVersion,
                        currentBuild: buildInfo.buildNumber,
                        checkedAt: previous.checkedAt,
                        canInstall: false,
                        error: Self.userFacingMessage(error)
                    )
                }
            }
        }

        /// Install the update currently advertised by the Host.
        func installAvailableUpdate() async {
            guard
                let version = state.latestVersion,
                let build = state.latestBuild
            else { return }

            try? await install(version: version, build: build)
        }

        /// Re-fetch and verify the installer immediately before launching it.
        func install(version: String, build: String) async throws {
            guard !isInstalling, state.phase != .installing else {
                throw CtrlXAppUpdateError.updateUnavailable
            }
            guard state.phase == .available else {
                throw CtrlXAppUpdateError.updateUnavailable
            }
            isInstalling = true
            installationError = nil
            downloadProgress = nil
            defer { isInstalling = false }

            var downloadRoot: URL?
            do {
                if let reason = installationPreflight() {
                    throw CtrlXAppUpdateError.installationUnavailable(reason)
                }
                let installer = try await verifiedInstaller(from: installerURL)
                let release = installer.release
                guard release.version == version, release.build == build else {
                    throw CtrlXAppUpdateError.updateChanged
                }
                guard isNewer(release) else {
                    throw CtrlXAppUpdateError.updateUnavailable
                }
                if let reason = installationPreflight() {
                    throw CtrlXAppUpdateError.installationUnavailable(reason)
                }

                let scriptURL = try persistInstallerScript(installer.script.body, release: release)
                let logURL = try makeInstallerLogURL(release: release)
                let root = try makeDownloadRoot()
                downloadRoot = root
                let installerPID = try launchInstaller(scriptURL, logURL, root)

                state = CtrlXAppUpdateState(
                    phase: .installing,
                    currentVersion: currentVersion,
                    currentBuild: buildInfo.buildNumber,
                    latestVersion: release.version,
                    latestBuild: release.build,
                    latestBuildStamp: release.buildStamp,
                    checkedAt: state.checkedAt,
                    canInstall: true
                )
                if let installerPID {
                    monitorInstaller(pid: installerPID, logURL: logURL, release: release, downloadRoot: root)
                } else {
                    try? FileManager.default.removeItem(at: root)
                }
            } catch {
                downloadProgress = nil
                if let downloadRoot {
                    try? FileManager.default.removeItem(at: downloadRoot)
                }
                let message = Self.userFacingMessage(error)
                installationError = message
                setState(
                    phase: .available,
                    latestVersion: state.latestVersion,
                    latestBuild: state.latestBuild,
                    latestBuildStamp: state.latestBuildStamp,
                    checkedAt: state.checkedAt,
                    canInstall: installationPreflight() == nil,
                    error: message
                )
                throw error
            }
        }

        private func monitorInstaller(pid: Int32, logURL: URL, release: InstallerRelease, downloadRoot: URL) {
            installerMonitorTask?.cancel()
            installerMonitorTask = Task { @MainActor [weak self] in
                defer { try? FileManager.default.removeItem(at: downloadRoot) }
                var expectedBytes: Int64?
                if let self, let downloadURL = Self.downloadURL(for: release) {
                    expectedBytes = await self.loadDownloadSize(downloadURL)
                    guard !Task.isCancelled else { return }
                    if let expectedBytes {
                        self.downloadProgress = DownloadProgress(downloadedBytes: 0, totalBytes: expectedBytes)
                    }
                }

                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        return
                    }
                    guard let self, self.state.phase == .installing else { return }
                    if let expectedBytes {
                        let downloadedBytes = Self.downloadedBytes(
                            in: downloadRoot,
                            dmgName: release.dmgName
                        ) ?? 0
                        self.downloadProgress = DownloadProgress(
                            downloadedBytes: downloadedBytes,
                            totalBytes: expectedBytes
                        )
                    }
                    if Self.processIsRunning(pid) {
                        continue
                    }

                    self.installerMonitorTask = nil
                    self.downloadProgress = nil
                    let preflight = self.installationPreflight()
                    let message = Self.installerFailureMessage(logURL: logURL, preflight: preflight)
                    self.installationError = message
                    self.setState(
                        phase: .available,
                        latestVersion: self.state.latestVersion,
                        latestBuild: self.state.latestBuild,
                        latestBuildStamp: self.state.latestBuildStamp,
                        checkedAt: self.state.checkedAt,
                        canInstall: preflight == nil,
                        error: message
                    )
                    return
                }
            }
        }

        private func makeDownloadRoot() throws -> URL {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ctrlx-app-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            return root
        }

        private var currentVersion: String {
            buildInfo.version ?? ""
        }

        private func setState(
            phase: CtrlXAppUpdateState.Phase,
            latestVersion: String? = nil,
            latestBuild: String? = nil,
            latestBuildStamp: String? = nil,
            checkedAt: Date? = nil,
            canInstall: Bool = false,
            error: String? = nil
        ) {
            state = CtrlXAppUpdateState(
                phase: phase,
                currentVersion: currentVersion,
                currentBuild: buildInfo.buildNumber,
                latestVersion: latestVersion,
                latestBuild: latestBuild,
                latestBuildStamp: latestBuildStamp,
                checkedAt: checkedAt,
                canInstall: canInstall,
                error: error
            )
        }

        private func verifiedRelease(from url: URL) async throws -> InstallerRelease {
            try await verifiedInstaller(from: url).release
        }

        private func verifiedInstaller(
            from url: URL
        ) async throws -> (script: InstallerScript, release: InstallerRelease) {
            let script = try await loadScript(url)
            guard let signingKey else {
                throw CtrlXAppUpdateError.missingSigningKey
            }
            try Self.verifyInstallerSignature(
                script.body,
                signature: script.signature,
                publicKey: signingKey
            )
            return try (script, Self.parseInstallerRelease(script.body))
        }

        private func isNewer(_ release: InstallerRelease) -> Bool {
            let versionComparison = VersionCompatibility.compare(release.version, currentVersion)
            if versionComparison != .orderedSame {
                return versionComparison == .orderedDescending
            }
            guard
                let currentBuild = buildInfo.buildNumber.flatMap(Int.init),
                let latestBuild = Int(release.build)
            else { return false }
            return latestBuild > currentBuild
        }

        private func persistInstallerScript(_ script: String, release: InstallerRelease) throws -> URL {
            try FileManager.default.createDirectory(
                at: updateDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let scriptURL = updateDirectory.appendingPathComponent(
                "install-\(release.version)-\(release.build)-\(UUID().uuidString).sh"
            )
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return scriptURL
        }

        private func makeInstallerLogURL(release: InstallerRelease) throws -> URL {
            try FileManager.default.createDirectory(
                at: logDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let stamp = ISO8601DateFormatter().string(from: now())
                .replacingOccurrences(of: ":", with: "-")
            return logDirectory.appendingPathComponent(
                "app-update-\(release.version)-\(release.build)-\(stamp).log"
            )
        }

        static func parseInstallerRelease(_ script: String) throws -> InstallerRelease {
            var values: [String: String] = [:]
            for rawLine in script.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                for key in manifestKeys {
                    let prefix = "\(key)='"
                    guard line.hasPrefix(prefix), line.hasSuffix("'") else { continue }
                    guard values[key] == nil else { throw CtrlXAppUpdateError.malformedInstaller }
                    let value = String(line.dropFirst(prefix.count).dropLast())
                    guard !value.isEmpty else { throw CtrlXAppUpdateError.malformedInstaller }
                    values[key] = value
                }
            }

            guard
                let version = values["CTRLX_VERSION"],
                isValidDottedVersion(version),
                let build = values["CTRLX_BUILD"],
                Int(build) != nil,
                let buildStamp = values["CTRLX_BUILD_STAMP"],
                let sourceRevision = values["CTRLX_SOURCE_REVISION"],
                sourceRevision.allSatisfy(\.isHexDigit),
                sourceRevision.count == 40 || sourceRevision.count == 64,
                let dmgName = values["CTRLX_DMG_NAME"],
                dmgName.hasSuffix(".dmg"),
                !dmgName.contains("/"),
                let dmgSHA256 = values["CTRLX_DMG_SHA256"],
                dmgSHA256.count == 64,
                dmgSHA256.allSatisfy(\.isHexDigit),
                let downloadBase = values["CTRLX_DOWNLOAD_BASE"],
                URL(string: downloadBase)?.scheme?.lowercased() == "https"
            else {
                throw CtrlXAppUpdateError.malformedInstaller
            }

            return InstallerRelease(
                version: version,
                build: build,
                buildStamp: buildStamp,
                sourceRevision: sourceRevision,
                dmgName: dmgName,
                dmgSHA256: dmgSHA256,
                downloadBase: downloadBase
            )
        }

        private static func isValidDottedVersion(_ version: String) -> Bool {
            let components = version.split(separator: ".", omittingEmptySubsequences: false)
            return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        }

        private static func fetchInstallerScript(from url: URL) async throws -> InstallerScript {
            async let scriptData = fetchInstallerData(
                from: url,
                maximumBytes: maximumManifestBytes,
                tooLarge: .responseTooLarge
            )
            async let signatureData = fetchInstallerData(
                from: signatureURL(for: url),
                maximumBytes: maximumSignatureBytes,
                tooLarge: .invalidSignature
            )

            let (scriptBytes, signatureBytes) = try await (scriptData, signatureData)
            return try InstallerScript(
                body: decodeInstallerScript(scriptBytes),
                signature: decodeInstallerSignature(signatureBytes)
            )
        }

        private static func fetchInstallerData(
            from url: URL,
            maximumBytes: Int,
            tooLarge: CtrlXAppUpdateError
        ) async throws -> Data {
            try validateInstallerURL(url)

            var request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: installerRequestTimeout
            )
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard
                let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200,
                httpResponse.url?.scheme?.lowercased() == "https"
            else {
                throw CtrlXAppUpdateError.invalidResponse
            }
            if httpResponse.expectedContentLength > Int64(maximumBytes) {
                throw tooLarge
            }

            var data = Data()
            data.reserveCapacity(max(0, Int(httpResponse.expectedContentLength)))
            for try await byte in bytes {
                data.append(byte)
                if data.count > maximumBytes {
                    throw tooLarge
                }
            }
            return data
        }

        static func validateInstallerURL(_ url: URL) throws {
            guard url.scheme?.lowercased() == "https" else {
                throw CtrlXAppUpdateError.insecureURL
            }
        }

        private static func downloadURL(for release: InstallerRelease) -> URL? {
            guard
                let baseURL = URL(string: release.downloadBase),
                baseURL.scheme?.lowercased() == "https"
            else { return nil }
            return baseURL.appendingPathComponent(release.dmgName)
        }

        private static func fetchDownloadSize(from url: URL) async -> Int64? {
            guard url.scheme?.lowercased() == "https" else { return nil }
            var request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: installerRequestTimeout
            )
            request.httpMethod = "HEAD"
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            guard
                let (_, response) = try? await URLSession.shared.data(for: request),
                let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200,
                httpResponse.expectedContentLength > 0
            else { return nil }
            return httpResponse.expectedContentLength
        }

        static func downloadedBytes(in downloadRoot: URL, dmgName: String) -> Int64? {
            guard
                let directories = try? FileManager.default.contentsOfDirectory(
                    at: downloadRoot,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { return nil }

            return directories.compactMap { directory -> Int64? in
                guard directory.lastPathComponent.hasPrefix("ctrlx-install.") else { return nil }
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: directory.appendingPathComponent(dmgName).path
                )
                return (attributes?[.size] as? NSNumber)?.int64Value
            }.max()
        }

        static func decodeInstallerScript(_ data: Data) throws -> String {
            guard data.count <= maximumManifestBytes else {
                throw CtrlXAppUpdateError.responseTooLarge
            }
            guard let script = String(data: data, encoding: .utf8) else {
                throw CtrlXAppUpdateError.invalidResponse
            }
            return script
        }

        static func signatureURL(for installerURL: URL) -> URL {
            installerURL.appendingPathExtension("sig")
        }

        static func decodeInstallerSignature(_ data: Data) throws -> Data {
            guard
                data.count <= maximumSignatureBytes,
                let encoded = String(data: data, encoding: .utf8)
            else {
                throw CtrlXAppUpdateError.invalidSignature
            }
            let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                !trimmed.isEmpty,
                !trimmed.contains(where: { $0.isWhitespace }),
                let signature = Data(base64Encoded: trimmed),
                signature.count == 64
            else {
                throw CtrlXAppUpdateError.invalidSignature
            }
            return signature
        }

        static func verifyInstallerSignature(
            _ script: String,
            signature: Data,
            publicKey: Curve25519.Signing.PublicKey
        ) throws {
            guard publicKey.isValidSignature(signature, for: Data(script.utf8)) else {
                throw CtrlXAppUpdateError.invalidSignature
            }
        }

        static var bundledSigningKey: Curve25519.Signing.PublicKey? {
            guard
                let encoded = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
            else { return nil }
            let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                !trimmed.isEmpty,
                !trimmed.contains("$("),
                let keyData = Data(base64Encoded: trimmed),
                keyData.count == 32
            else { return nil }
            return try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        }

        private static func defaultInstallationPreflight() -> String? {
            let appPath = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard appPath == "/Applications/CtrlX.app" else {
                return "In-app updates require CtrlX to be installed at /Applications/CtrlX.app."
            }
            guard FileManager.default.isWritableFile(atPath: "/Applications") else {
                return "Administrator permission is required to update CtrlX in /Applications."
            }
            return blockingDialogReason(modalWindow: NSApp.modalWindow, windows: NSApp.windows)
        }

        static func blockingDialogReason(modalWindow: NSWindow?, windows: [NSWindow]) -> String? {
            let parent = windows.first { $0.attachedSheet != nil }
            guard let dialog = modalWindow ?? parent?.attachedSheet else { return nil }
            let title = dialog.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let dialogParent = modalWindow == nil ? parent : dialog.sheetParent
            let parentTitle = dialogParent?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let location = if !title.isEmpty {
                " “\(title)”"
            } else if !parentTitle.isEmpty {
                " in “\(parentTitle)”"
            } else {
                ""
            }
            return "CtrlX cannot quit because a dialog\(location) is open on the Host Mac. Close it, then check for updates again."
        }

        static func installerFailureMessage(logURL: URL, preflight: String?) -> String {
            let log = (try? installerLogTail(at: logURL)) ?? ""
            let lines = log.split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let reason: String? = if lines.contains(where: { $0.contains("execution error:") && $0.contains("(-128)") }) {
                "macOS cancelled CtrlX's quit request. Close any open dialogs on the Host Mac, then check for updates again."
            } else if let error = lines.last(where: { $0.hasPrefix("Error:") }) {
                String(error.dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces)
            } else {
                lines.last { $0.hasPrefix("curl:") || $0.contains("execution error:") }
            }
            var message = if let reason, !reason.isEmpty {
                "CtrlX update failed: \(String(reason.prefix(1_024)))"
            } else {
                "The CtrlX installer stopped before completing."
            }
            if let preflight {
                message += "\n\(preflight)"
            }
            return message + "\nReview the installer log at \(logURL.path)."
        }

        private static func installerLogTail(at url: URL) throws -> String {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let end = try file.seekToEnd()
            let limit: UInt64 = 64 * 1_024
            try file.seek(toOffset: end > limit ? end - limit : 0)
            return try String(decoding: file.read(upToCount: Int(limit)) ?? Data(), as: UTF8.self)
        }

        private static func processIsRunning(_ pid: Int32) -> Bool {
            if kill(pid, 0) == 0 {
                return true
            }
            return errno != ESRCH
        }

        private static func launchDetachedInstaller(
            scriptURL: URL,
            logURL: URL,
            downloadRoot: URL
        ) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c",
                "nohup /bin/bash \"$1\" >>\"$2\" 2>&1 </dev/null & printf '%s\\n' \"$!\"",
                "ctrlx-app-update",
                scriptURL.path,
                logURL.path,
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            environment["TMPDIR"] = downloadRoot.path
            process.environment = environment

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw CtrlXAppUpdateError.launchFailed(message?.isEmpty == false ? message! : "unknown error")
            }

            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let rawPID = String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rawPID, let pid = Int32(rawPID), pid > 0 else {
                throw CtrlXAppUpdateError.launchFailed("the installer did not report a process identifier")
            }
            return pid
        }

        private static func userFacingMessage(_ error: any Error) -> String {
            if let updateError = error as? CtrlXAppUpdateError {
                return updateError.localizedDescription
            }
            return (error as NSError).localizedDescription
        }
    }
#endif
