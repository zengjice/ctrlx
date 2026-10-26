#if os(macOS)
    import ConcurrencyExtras
    import CryptoKit
    import CtrlxCommon
    import CtrlxNetworking
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    struct CtrlXAppUpdateServiceTests {
        @Test
        func viewerWaitsForInstallerDownload() {
            #expect(InstallCtrlXAppUpdate.responseTimeout > CtrlXAppUpdateService.installerRequestTimeout)
        }

        @Test
        func parsesVerifiedInstallerManifest() throws {
            let release = try CtrlXAppUpdateService.parseInstallerRelease(
                manifest(version: "3.0.99", build: "32")
            )

            #expect(release.version == "3.0.99")
            #expect(release.build == "32")
            #expect(release.buildStamp == "20261024-150000")
            #expect(release.sourceRevision == String(repeating: "a", count: 40))
            #expect(release.dmgName == "CtrlX-3.0.99.dmg")
            #expect(release.dmgSHA256 == String(repeating: "b", count: 64))
            #expect(release.downloadBase == "https://updates.example.com/macos")
        }

        @Test
        func verifiesInstallerSignature() throws {
            let privateKey = Curve25519.Signing.PrivateKey()
            let installer = try signedInstaller(manifest(version: "3.0.99", build: "32"), using: privateKey)

            try CtrlXAppUpdateService.verifyInstallerSignature(
                installer.body,
                signature: installer.signature,
                publicKey: privateKey.publicKey
            )
            #expect(try CtrlXAppUpdateService.decodeInstallerSignature(
                Data(installer.signature.base64EncodedString().utf8)
            ) == installer.signature)
            #expect(throws: CtrlXAppUpdateError.invalidSignature) {
                try CtrlXAppUpdateService.verifyInstallerSignature(
                    installer.body + "\necho tampered\n",
                    signature: installer.signature,
                    publicKey: privateKey.publicKey
                )
            }
        }

        @Test
        func rejectsMissingOrMalformedSignature() throws {
            #expect(throws: CtrlXAppUpdateError.invalidSignature) {
                try CtrlXAppUpdateService.decodeInstallerSignature(Data())
            }
            #expect(throws: CtrlXAppUpdateError.invalidSignature) {
                try CtrlXAppUpdateService.decodeInstallerSignature(Data("not-a-signature".utf8))
            }
            #expect(try CtrlXAppUpdateService.signatureURL(
                for: #require(URL(string: "https://updates.example.com/mac.sh"))
            ).absoluteString == "https://updates.example.com/mac.sh.sig")
        }

        @Test
        func rejectsMalformedAndDuplicateManifestFields() throws {
            let missingBuild = manifest(version: "3.0.99", build: "32")
                .replacingOccurrences(of: "CTRLX_BUILD='32'\n", with: "")
            #expect(throws: CtrlXAppUpdateError.malformedInstaller) {
                try CtrlXAppUpdateService.parseInstallerRelease(missingBuild)
            }

            let duplicateBuild = manifest(version: "3.0.99", build: "32")
                + "CTRLX_BUILD='32'\n"
            #expect(throws: CtrlXAppUpdateError.malformedInstaller) {
                try CtrlXAppUpdateService.parseInstallerRelease(duplicateBuild)
            }
        }

        @Test
        func rejectsInsecureAndOversizedResponses() throws {
            let insecureURL = try #require(URL(string: "http://updates.example.com/mac.sh"))
            #expect(throws: CtrlXAppUpdateError.insecureURL) {
                try CtrlXAppUpdateService.validateInstallerURL(insecureURL)
            }
            #expect(throws: CtrlXAppUpdateError.responseTooLarge) {
                try CtrlXAppUpdateService.decodeInstallerScript(
                    Data(repeating: 0x61, count: CtrlXAppUpdateService.maximumManifestBytes + 1)
                )
            }
        }

        @Test
        func refreshPublishesOnlyNewerBuilds() async {
            let service = makeService(script: manifest(version: "3.0.99", build: "32"))
            await service.refresh()
            #expect(service.state.phase == .available)
            #expect(service.state.latestVersion == "3.0.99")
            #expect(service.state.latestBuild == "32")
            #expect(service.state.canInstall)

            let newerBuild = makeService(
                currentVersion: "3.0.98",
                currentBuild: "31",
                script: manifest(version: "3.0.98", build: "32")
            )
            await newerBuild.refresh()
            #expect(newerBuild.state.phase == .available)

            let older = makeService(
                currentVersion: "3.0.99",
                currentBuild: "32",
                script: manifest(version: "3.0.98", build: "31")
            )
            await older.refresh()
            #expect(older.state.phase == .upToDate)
            #expect(older.state.canInstall == false)
        }

        @Test
        func installRevalidatesTheAdvertisedRelease() async throws {
            let initialScript = manifest(version: "3.0.99", build: "32")
            let updatedScript = manifest(version: "3.0.100", build: "33")
            let script = LockIsolated(initialScript)
            let service = makeService(scriptProvider: { script.value })
            await service.refresh()
            #expect(service.state.phase == .available)

            script.withValue { $0 = updatedScript }
            await #expect(throws: CtrlXAppUpdateError.updateChanged) {
                try await service.install(version: "3.0.99", build: "32")
            }
            #expect(service.state.phase == .available)
            #expect(service.state.error != nil)
        }

        @Test
        func transientInstallFailureKeepsRemoteRetryAvailable() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-app-retry-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let key = Curve25519.Signing.PrivateKey()
            let script = manifest(version: "3.0.99", build: "32")
            let failNextLoad = LockIsolated(false)
            var launches = 0
            let service = CtrlXAppUpdateService(
                buildInfo: buildInfo(version: "3.0.98", build: "31"), signingKey: key.publicKey,
                loadScript: { _ in
                    if
                        failNextLoad.withValue({ value in
                            defer { value = false }
                            return value
                        }) {
                        throw URLError(.networkConnectionLost)
                    }
                    return try signedInstaller(script, using: key)
                },
                installationPreflight: { nil },
                launchInstaller: { _, _ in launches += 1
                    return nil
                },
                updateDirectory: root.appendingPathComponent("Updates"), logDirectory: root.appendingPathComponent("Logs")
            )
            await service.refresh()
            failNextLoad.setValue(true)
            await #expect(throws: URLError.self) { try await service.install(version: "3.0.99", build: "32") }
            #expect(service.state.phase == .available)
            #expect(service.state.canInstall, "A Viewer must be able to retry without a separate Host refresh")
            #expect(service.state.error != nil)
            #expect(service.installationError == service.state.error)
            #expect(launches == 0)
            try await service.install(version: "3.0.99", build: "32")
            #expect(launches == 1)
            #expect(service.state.phase == .installing)
            #expect(service.installationError == nil)
        }

        @Test
        func changedInstallationPreflightPublishesTheFailure() async {
            let reason = LockIsolated<String?>(nil)
            let key = Curve25519.Signing.PrivateKey()
            let script = manifest(version: "3.0.99", build: "32")
            let service = CtrlXAppUpdateService(
                buildInfo: buildInfo(version: "3.0.98", build: "31"), signingKey: key.publicKey,
                loadScript: { _ in try signedInstaller(script, using: key) },
                installationPreflight: { reason.value },
                launchInstaller: { _, _ in Issue.record("An unavailable installation must not launch")
                    return nil
                }
            )
            await service.refresh()
            reason.setValue("Administrator permission is required")
            await service.installAvailableUpdate()
            #expect(!service.state.canInstall)
            #expect(service.state.error == reason.value)
        }

        @Test
        func refreshRejectsTamperedInstaller() async throws {
            let privateKey = Curve25519.Signing.PrivateKey()
            let script = manifest(version: "3.0.99", build: "32")
            let signature = try privateKey.signature(for: Data(script.utf8))
            let service = try CtrlXAppUpdateService(
                buildInfo: buildInfo(version: "3.0.98", build: "31"),
                installerURL: #require(URL(string: "https://updates.example.com/mac.sh")),
                signingKey: privateKey.publicKey,
                loadScript: { _ in
                    CtrlXAppUpdateService.InstallerScript(
                        body: script + "\necho tampered\n",
                        signature: signature
                    )
                },
                installationPreflight: { nil },
                launchInstaller: { _, _ in nil },
                now: { Date() }
            )

            await service.refresh()
            #expect(service.state.phase == .failed)
            #expect(service.state.error == CtrlXAppUpdateError.invalidSignature.localizedDescription)
        }

        @Test
        func installRechecksSignatureBeforeLaunch() async throws {
            let privateKey = Curve25519.Signing.PrivateKey()
            let script = manifest(version: "3.0.99", build: "32")
            let signature = try privateKey.signature(for: Data(script.utf8))
            let current = LockIsolated(CtrlXAppUpdateService.InstallerScript(body: script, signature: signature))
            let launched = LockIsolated(false)
            let service = try CtrlXAppUpdateService(
                buildInfo: buildInfo(version: "3.0.98", build: "31"),
                installerURL: #require(URL(string: "https://updates.example.com/mac.sh")),
                signingKey: privateKey.publicKey,
                loadScript: { _ in current.value },
                installationPreflight: { nil },
                launchInstaller: { _, _ in
                    launched.withValue { $0 = true }
                    return nil
                },
                now: { Date() }
            )

            await service.refresh()
            #expect(service.state.phase == .available)

            current.withValue {
                $0 = CtrlXAppUpdateService.InstallerScript(
                    body: script + "\necho tampered\n",
                    signature: signature
                )
            }
            await #expect(throws: CtrlXAppUpdateError.invalidSignature) {
                try await service.install(version: "3.0.99", build: "32")
            }
            #expect(launched.value == false)
            #expect(service.state.phase == .available)
        }

        @Test
        func refreshRequiresSigningKey() async throws {
            let service = try CtrlXAppUpdateService(
                buildInfo: buildInfo(version: "3.0.98", build: "31"),
                installerURL: #require(URL(string: "https://updates.example.com/mac.sh")),
                signingKey: nil,
                loadScript: { _ in
                    CtrlXAppUpdateService.InstallerScript(body: "", signature: Data())
                },
                installationPreflight: { nil },
                launchInstaller: { _, _ in nil },
                now: { Date() }
            )

            #expect(service.isConfigured == false)
            await service.refresh()
            #expect(service.state.phase == .failed)
            #expect(service.state.error == CtrlXAppUpdateError.missingSigningKey.localizedDescription)
        }

        @Test
        func installWritesScriptAndLaunchesDetachedInstaller() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ctrlx-app-update-tests-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            var launched: (script: URL, log: URL)?
            let expectedScript = manifest(version: "3.0.99", build: "32")
            let privateKey = Curve25519.Signing.PrivateKey()
            let service = try CtrlXAppUpdateService(
                buildInfo: buildInfo(version: "3.0.98", build: "31"),
                installerURL: #require(URL(string: "https://updates.example.com/mac.sh")),
                signingKey: privateKey.publicKey,
                loadScript: { _ in try signedInstaller(expectedScript, using: privateKey) },
                installationPreflight: { nil },
                launchInstaller: { scriptURL, logURL in
                    launched = (scriptURL, logURL)
                    return nil
                },
                now: { Date(timeIntervalSince1970: 1_000_000) },
                updateDirectory: root.appendingPathComponent("Updates", isDirectory: true),
                logDirectory: root.appendingPathComponent("Logs", isDirectory: true)
            )

            await service.refresh()
            try await service.install(version: "3.0.99", build: "32")

            let launchedURLs = try #require(launched)
            #expect(try String(contentsOf: launchedURLs.script, encoding: .utf8) == expectedScript)
            #expect(launchedURLs.log.path.hasSuffix(".log"))
            #expect(service.state.phase == .installing)
        }

        @Test
        func installerExitRestoresRetryableState() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ctrlx-app-update-tests-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let privateKey = Curve25519.Signing.PrivateKey()
            let service = try CtrlXAppUpdateService(
                buildInfo: buildInfo(version: "3.0.98", build: "31"),
                installerURL: #require(URL(string: "https://updates.example.com/mac.sh")),
                signingKey: privateKey.publicKey,
                loadScript: { _ in
                    try signedInstaller(manifest(version: "3.0.99", build: "32"), using: privateKey)
                },
                installationPreflight: { nil },
                launchInstaller: { _, _ in Int32.max },
                now: { Date(timeIntervalSince1970: 1_000_000) },
                updateDirectory: root.appendingPathComponent("Updates", isDirectory: true),
                logDirectory: root.appendingPathComponent("Logs", isDirectory: true)
            )

            await service.refresh()
            try await service.install(version: "3.0.99", build: "32")
            #expect(service.state.phase == .installing)

            for _ in 0..<40 where service.state.phase == .installing {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(service.state.phase == .available)
            #expect(service.state.canInstall)
            #expect(service.state.error?.contains("installer log") == true)
            #expect(service.installationError == service.state.error)
        }

        @Test
        func insecureFeedIsNotConfigured() async throws {
            let privateKey = Curve25519.Signing.PrivateKey()
            let service = try CtrlXAppUpdateService(
                buildInfo: buildInfo(version: "3.0.98", build: "31"),
                installerURL: #require(URL(string: "http://updates.example.com/mac.sh")),
                signingKey: privateKey.publicKey,
                loadScript: { _ in
                    try signedInstaller(manifest(version: "3.0.99", build: "32"), using: privateKey)
                },
                installationPreflight: { nil },
                launchInstaller: { _, _ in nil },
                now: { Date() }
            )
            #expect(service.isConfigured == false)
            await service.refresh()
            #expect(service.state.phase == .failed)
        }

        private func makeService(
            currentVersion: String = "3.0.98",
            currentBuild: String = "31",
            script: String
        ) -> CtrlXAppUpdateService {
            makeService(currentVersion: currentVersion, currentBuild: currentBuild, scriptProvider: { script })
        }

        private func makeService(
            currentVersion: String = "3.0.98",
            currentBuild: String = "31",
            scriptProvider: @escaping @MainActor () -> String
        ) -> CtrlXAppUpdateService {
            let privateKey = Curve25519.Signing.PrivateKey()
            return CtrlXAppUpdateService(
                buildInfo: buildInfo(version: currentVersion, build: currentBuild),
                installerURL: URL(string: "https://updates.example.com/mac.sh")!,
                signingKey: privateKey.publicKey,
                loadScript: { _ in try signedInstaller(scriptProvider(), using: privateKey) },
                installationPreflight: { nil },
                launchInstaller: { _, _ in nil },
                now: { Date(timeIntervalSince1970: 1_000_000) }
            )
        }

        private func signedInstaller(
            _ script: String,
            using privateKey: Curve25519.Signing.PrivateKey
        ) throws -> CtrlXAppUpdateService.InstallerScript {
            try CtrlXAppUpdateService.InstallerScript(
                body: script,
                signature: privateKey.signature(for: Data(script.utf8))
            )
        }

        private func buildInfo(version: String, build: String) -> AppBuildInfo {
            AppBuildInfo(infoDictionary: [
                "CFBundleShortVersionString": version,
                "CFBundleVersion": build,
            ])
        }

        private func manifest(version: String, build: String) -> String {
            """
            #!/bin/bash
            set -euo pipefail
            CTRLX_DOWNLOAD_BASE='https://updates.example.com/macos'
            CTRLX_DMG_NAME='CtrlX-\(version).dmg'
            CTRLX_DMG_SHA256='\(String(repeating: "b", count: 64))'
            CTRLX_VERSION='\(version)'
            CTRLX_BUILD='\(build)'
            CTRLX_BUILD_STAMP='20261024-150000'
            CTRLX_SOURCE_REVISION='\(String(repeating: "a", count: 40))'
            """
        }
    }
#endif
