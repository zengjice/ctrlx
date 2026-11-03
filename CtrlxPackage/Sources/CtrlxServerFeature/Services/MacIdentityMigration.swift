#if os(macOS)
    import AppKit
    import CtrlxEncryption
    import Foundation
    import OSLog

    @MainActor
    public enum MacIdentityMigration {
        public static let legacyBundleID = "com.jicezeng.ctrlx.macos"
        public static let currentBundleID = "com.gravtice.ctrlx.macos"
        private static let marker = "identityMigration.gravtice.v1"
        private static let logger = Logger(subsystem: currentBundleID, category: "identity-migration")

        /// Runs before app settings, encryption or the browser runtime are initialized.
        public static func prepareForLaunch() -> Bool {
            guard
                Bundle.main.bundleIdentifier == currentBundleID,
                !CommandLine.arguments.contains("--e2e-test")
            else { return true }
            do {
                logger.notice("Starting Keychain namespace migration")
                let copied = try MacKeychainServiceMigration.copyIfNeeded()
                logger.notice("Keychain copy verified: \(copied) entries copied")
                migratePreferences(defaults: .standard, from: legacyBundleID, to: currentBundleID)
                logger.notice("Preferences identity migration completed")
                return true
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "CtrlX could not migrate its Keychain data"
                alert.informativeText = error.localizedDescription + "\nExisting Keychain items and preferences were retained. Quit and reopen CtrlX to retry."
                alert.addButton(withTitle: "Quit")
                alert.runModal()
                return false
            }
        }

        static func migratePreferences(defaults: UserDefaults, from oldDomain: String, to newDomain: String) {
            let current = defaults.persistentDomain(forName: newDomain) ?? [:]
            guard current[marker] as? Bool != true else { return }
            let previous = defaults.persistentDomain(forName: oldDomain) ?? [:]
            var merged = previous.merging(current) { _, current in current }
            merged[marker] = true
            defaults.setPersistentDomain(merged, forName: newDomain)
        }
    }
#endif
