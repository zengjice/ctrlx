#if os(macOS)
    import CtrlxCommon
    import Dependencies
    import Foundation
    import Logging
    import Observation

    /// Owns the current user's CLI installation and explicit uninstall preference.
    @Observable @MainActor
    final public class CLIInstaller {
        static let automaticInstallationDisabledKey = "cliAutomaticInstallationDisabled"
        public private(set) var isInstalled = false
        public private(set) var isWorking = false
        public private(set) var errorMessage: String?
        @ObservationIgnored private var hasStarted = false
        @ObservationIgnored @Dependency(CLIInstallationClient.self) private var client
        @ObservationIgnored @Dependency(PreferencesService.self) private var preferences
        private let logger = Logger(label: "com.gravtice.ctrlx.cliinstaller")

        public init() { }

        public var userShellIsZsh: Bool {
            client.userShellIsZsh()
        }

        public func setupAutomatically() async {
            guard !hasStarted else { return }
            hasStarted = true
            isInstalled = await client.isInstalled()
            guard client.canInstallAutomatically(), preferences.optionalBool(Self.automaticInstallationDisabledKey) != true else { return }
            _ = await install()
        }

        @discardableResult
        public func install(installZshCompletion: Bool = false) async -> CLIInstallResult? {
            guard !isWorking else { return nil }
            isWorking = true
            errorMessage = nil
            defer { isWorking = false }
            do {
                let result = try await client.install(installZshCompletion)
                isInstalled = true
                preferences.setBool(false, Self.automaticInstallationDisabledKey)
                return result
            } catch {
                isInstalled = await client.isInstalled()
                errorMessage = error.localizedDescription
                logger.warning("CLI installation failed: \(error)")
                return nil
            }
        }

        @discardableResult
        public func uninstall() async -> Bool {
            guard !isWorking else { return false }
            isWorking = true
            errorMessage = nil
            // A failed removal must not cause a fresh installation next launch.
            preferences.setBool(true, Self.automaticInstallationDisabledKey)
            defer { isWorking = false }
            do {
                try await client.uninstall()
                isInstalled = false
                return true
            } catch {
                isInstalled = await client.isInstalled()
                errorMessage = error.localizedDescription
                logger.warning("CLI removal failed: \(error)")
                return false
            }
        }
    }
#endif
