#if os(macOS)
    import AppKit
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
        func reportsActualInstallerDownloadBytes() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ctrlx-app-progress-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let downloadDirectory = root.appendingPathComponent("ctrlx-install.fixture", isDirectory: true)
            try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
            try Data(repeating: 0x61, count: 250).write(
                to: downloadDirectory.appendingPathComponent("CtrlX-3.0.99.dmg")
            )

            #expect(CtrlXAppUpdateService.downloadedBytes(
                in: root,
                dmgName: "CtrlX-3.0.99.dmg"
            ) == 250)
            #expect(CtrlXAppUpdateService.downloadedBytes(in: root, dmgName: "missing.dmg") == nil)

            let partial = CtrlXAppUpdateService.DownloadProgress(downloadedBytes: 250, totalBytes: 500)
            #expect(partial.fraction == 0.5)
            #expect(partial.percent == 50)
            #expect(!partial.isComplete)

            let complete = CtrlXAppUpdateService.DownloadProgress(downloadedBytes: 500, totalBytes: 500)
            #expect(complete.fraction == 1)
            #expect(complete.percent == 100)
            #expect(complete.isComplete)
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
                launchInstaller: { _, _, _ in launches += 1
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
                launchInstaller: { _, _, _ in Issue.record("An unavailable installation must not launch")
                    return nil
                }
            )
            await service.refresh()
            reason.setValue("Administrator permission is required")
            await service.installAvailableUpdate()
            #expect(!service.state.canInstall)
            #expect(service.state.error == reason.value)
        }

        @Test(arguments: [false, true])
        func openDialogPreventsInstallAndAllowsRetryAfterClosing(opensDuringVerification: Bool) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-app-dialog-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let key = Curve25519.Signing.PrivateKey()
            let script = manifest(version: "3.0.99", build: "32")
            var loads = 0
            var launches = 0
            var dialogIsOpen = false
            let reason = "Close the dialog on the Host Mac, then check for updates again."
            let service = CtrlXAppUpdateService(
                buildInfo: buildInfo(version: "3.0.98", build: "31"), signingKey: key.publicKey,
                loadScript: { _ in
                    loads += 1
                    if opensDuringVerification, loads == 2 {
                        dialogIsOpen = true
                    }
                    return try signedInstaller(script, using: key)
                },
                installationPreflight: { dialogIsOpen ? reason : nil },
                launchInstaller: { _, _, _ in launches += 1
                    return nil
                },
                updateDirectory: root.appendingPathComponent("Updates"), logDirectory: root.appendingPathComponent("Logs")
            )
            await service.refresh()
            #expect(service.state.canInstall)
            if !opensDuringVerification {
                dialogIsOpen = true
            }
            await #expect(throws: CtrlXAppUpdateError.installationUnavailable(reason)) {
                try await service.install(version: "3.0.99", build: "32")
            }
            #expect(launches == 0)
            #expect(!service.state.canInstall)
            #expect(service.state.error == reason)
            #expect(!FileManager.default.fileExists(atPath: root.path))

            dialogIsOpen = false
            await service.refresh()
            #expect(service.state.canInstall)
            #expect(service.state.error == nil)
            try await service.install(version: "3.0.99", build: "32")
            #expect(launches == 1)
        }

        @Test(arguments: ["Choose IPA", ""])
        func detectsModalDialogWithoutClosingIt(title: String) throws {
            _ = NSApplication.shared
            let dialog = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            dialog.isReleasedWhenClosed = false
            defer { dialog.close() }
            dialog.title = title
            let reason = try #require(CtrlXAppUpdateService.blockingDialogReason(modalWindow: dialog, windows: []))
            #expect(reason.contains("Host Mac"))
            #expect(reason.contains("Close it"))
            if !title.isEmpty {
                #expect(reason.contains(title))
            }
        }

        @Test(arguments: ["New Agent", ""])
        func detectsAttachedSheetWithoutModalWindow(title: String) throws {
            _ = NSApplication.shared
            let parent = UpdateDialogTestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            parent.isReleasedWhenClosed = false
            sheet.isReleasedWhenClosed = false
            defer { parent.close()
                sheet.close()
            }
            parent.title = "Sessions"
            sheet.title = title
            parent.testSheet = sheet
            let reason = try #require(CtrlXAppUpdateService.blockingDialogReason(modalWindow: nil, windows: [parent]))
            #expect(reason.contains(title.isEmpty ? "Sessions" : title))
            #expect(parent.attachedSheet === sheet)

            parent.testSheet = nil
            #expect(CtrlXAppUpdateService.blockingDialogReason(modalWindow: nil, windows: [parent]) == nil)
        }

        @Test(arguments: [
            ("Downloading...\nError: DMG checksum mismatch\nInstallation details:\n+ cleanup\n", "DMG checksum mismatch"),
            ("curl: (6) Could not resolve host: updates.example.com\n", "Could not resolve host"),
            ("Error: CtrlX did not finish its cleanup; existing app was not replaced\nInstallation details:\n46:50: execution error: 用户已取消。 (-128)\n+ cleanup\n", "macOS cancelled CtrlX's quit request"),
            ("46:50: execution error: Not authorized. (-1743)\n", "Not authorized"),
            ("Downloading...\n+ cleanup\n", "installer stopped before completing"),
            ("", "installer stopped before completing"),
        ])
        func installerFailureIncludesCauseAndLogPath(log: String, expected: String) throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-installer-log-\(UUID()).log")
            defer { try? FileManager.default.removeItem(at: url) }
            try log.write(to: url, atomically: true, encoding: .utf8)
            let message = CtrlXAppUpdateService.installerFailureMessage(logURL: url, preflight: nil)
            #expect(message.contains(expected))
            #expect(message.contains(url.path))
            #expect(!message.contains("+ cleanup"))
        }

        @Test
        func installerFailureBoundsLogReadingAndHandlesMissingLog() throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-installer-log-\(UUID()).log")
            let missing = CtrlXAppUpdateService.installerFailureMessage(logURL: url, preflight: nil)
            #expect(missing.contains("installer stopped before completing"))
            #expect(missing.contains(url.path))

            defer { try? FileManager.default.removeItem(at: url) }
            let log = "46:50: execution error: old cancellation (-128)\n"
                + String(repeating: "old output\n", count: 10_000)
                + "Error: " + String(repeating: "x", count: 4_096)
            try log.write(to: url, atomically: true, encoding: .utf8)
            let reason = "Close the New Agent dialog on the Host Mac."
            let message = CtrlXAppUpdateService.installerFailureMessage(logURL: url, preflight: reason)
            #expect(message.contains(reason))
            #expect(message.contains("CtrlX update failed: " + String(repeating: "x", count: 1_024)))
            #expect(!message.contains(String(repeating: "x", count: 1_025)))
            #expect(!message.contains("cancelled"))
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
                launchInstaller: { _, _, _ in nil },
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
                launchInstaller: { _, _, _ in
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
                launchInstaller: { _, _, _ in nil },
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
                launchInstaller: { scriptURL, logURL, _ in
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

        @Test(arguments: [false, true])
        func installerExitPublishesActualErrorAndChecksRetryEligibility(dialogOpened: Bool) async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ctrlx-app-update-tests-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let privateKey = Curve25519.Signing.PrivateKey()
            var blocker: String?
            let service = try CtrlXAppUpdateService(
                buildInfo: buildInfo(version: "3.0.98", build: "31"),
                installerURL: #require(URL(string: "https://updates.example.com/mac.sh")),
                signingKey: privateKey.publicKey,
                loadScript: { _ in
                    try signedInstaller(manifest(version: "3.0.99", build: "32"), using: privateKey)
                },
                installationPreflight: { blocker },
                launchInstaller: { _, logURL, _ in
                    try "Error: CtrlX did not finish its cleanup; existing app was not replaced\n".write(to: logURL, atomically: true, encoding: .utf8)
                    if dialogOpened {
                        blocker = "Close the New Agent dialog on the Host Mac."
                    }
                    return Int32.max
                },
                loadDownloadSize: { _ in nil },
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
            #expect(service.state.canInstall == !dialogOpened)
            #expect(service.state.error?.contains("CtrlX did not finish its cleanup") == true)
            if let blocker {
                #expect(service.state.error?.contains(blocker) == true)
            }
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
                launchInstaller: { _, _, _ in nil },
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
                launchInstaller: { _, _, _ in nil },
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

    @MainActor
    final private class UpdateDialogTestWindow: NSWindow {
        var testSheet: NSWindow?
        override var attachedSheet: NSWindow? {
            testSheet
        }
    }
#endif
