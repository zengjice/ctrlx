#if os(iOS)
    import CtrlxCommon
    import CtrlxEncryption
    import Dependencies
    import Foundation
    import SwiftUI
    import UIKit

    // MARK: - PreferencesService + AppSettings.Keys

    extension PreferencesService {
        func string(_ key: IOSSettings.Keys) -> String? {
            string(key.rawValue)
        }

        func setString(_ value: String?, _ key: IOSSettings.Keys) {
            setString(value, key.rawValue)
        }

        func optionalBool(_ key: IOSSettings.Keys) -> Bool? {
            optionalBool(key.rawValue)
        }

        func setBool(_ value: Bool, _ key: IOSSettings.Keys) {
            setBool(value, key.rawValue)
        }

        func optionalInt(_ key: IOSSettings.Keys) -> Int? {
            optionalInt(key.rawValue)
        }

        func setInt(_ value: Int, _ key: IOSSettings.Keys) {
            setInt(value, key.rawValue)
        }

        func optionalDouble(_ key: IOSSettings.Keys) -> Double? {
            optionalDouble(key.rawValue)
        }

        func setDouble(_ value: Double, _ key: IOSSettings.Keys) {
            setDouble(value, key.rawValue)
        }

        func data(_ key: IOSSettings.Keys) -> Data? {
            data(key.rawValue)
        }

        func setData(_ value: Data?, _ key: IOSSettings.Keys) {
            setData(value, key.rawValue)
        }
    }

    /// Settings for the Ctrlx iOS app with UserDefaults persistence.
    @Observable
    @MainActor
    final public class IOSSettings {
        // MARK: - UserDefaults Keys

        public enum Keys: String {
            case deviceId
            case customDeviceName
            case pairedHosts
            case remoteSessionOrderByHost
            case externalServerURL
            case autoReconnect
            case appearanceMode
            case terminalFontName
            case terminalFontSize
            case terminalKeyboardControlPosition
            case showTerminalKeyboardOnEntry
            case agentQuickInputEnabled
            case agentBackgroundMonitoringEnabled
            case voiceCorrectionProvider
            case voiceCorrectionModelID
            case voiceCorrectionTestedModelIDsByProvider
            case newSessionName
            case newSessionWidth
            case newSessionHeight
        }

        // MARK: - Dependencies

        /// Preferences service for persistent storage
        @ObservationIgnored
        @Dependency(PreferencesService.self) private var preferences

        // MARK: - Properties

        /// Device-local phrase library, independent of sessions and agent plugins.
        let quickPhrases = QuickPhraseStore()

        /// Unique device identifier (generated once and persisted)
        public var deviceId = "" {
            didSet { preferences.setString(deviceId, Keys.deviceId) }
        }

        /// User-set device name override. When `nil` or empty after trimming,
        /// `deviceName` falls back to the system's `UIDevice.current.name`.
        public var customDeviceName: String? {
            didSet { preferences.setString(customDeviceName, Keys.customDeviceName) }
        }

        /// All paired host servers
        public private(set) var pairedHosts: [PairedHost] = [] {
            didSet { savePairedHosts() }
        }

        /// Viewer-local session order, isolated by remote host pair ID.
        public private(set) var remoteSessionOrderByHost: [String: [String]] = [:] {
            didSet { saveRemoteSessionOrder() }
        }

        /// External relay server URL
        public var externalServerURL = "" {
            didSet { preferences.setString(externalServerURL, Keys.externalServerURL) }
        }

        /// Whether to automatically reconnect on app launch
        public var autoReconnect = false {
            didSet { preferences.setBool(autoReconnect, Keys.autoReconnect) }
        }

        /// App appearance (System / Light / Dark). Drives
        /// `.preferredColorScheme(_:)` on the iOS root view.
        public var appearanceMode: AppearanceMode = .system {
            didSet { preferences.setString(appearanceMode.rawValue, Keys.appearanceMode) }
        }

        /// Font name for terminal snapshot display
        public var terminalFontName = "Menlo" {
            didSet { preferences.setString(terminalFontName, Keys.terminalFontName) }
        }

        /// Font size for terminal snapshot display
        public var terminalFontSize: Double = 10 {
            didSet { preferences.setDouble(terminalFontSize, Keys.terminalFontSize) }
        }

        /// Where the terminal keyboard show/hide control is displayed.
        public var terminalKeyboardControlPosition: TerminalKeyboardControlPosition = .topRight {
            didSet {
                preferences.setString(
                    terminalKeyboardControlPosition.rawValue,
                    Keys.terminalKeyboardControlPosition
                )
            }
        }

        /// Whether a newly opened terminal session starts with keyboard input active.
        public var showTerminalKeyboardOnEntry = false {
            didSet { preferences.setBool(showTerminalKeyboardOnEntry, Keys.showTerminalKeyboardOnEntry) }
        }

        /// Whether agent panes use the optional response field above the terminal.
        /// When disabled, the keyboard remains a separate, explicit user action.
        public var agentQuickInputEnabled = false {
            didSet { preferences.setBool(agentQuickInputEnabled, Keys.agentQuickInputEnabled) }
        }

        /// Whether the user wants Agent monitoring to resume on the next
        /// eligible foreground input. Runtime lease state is owned separately by
        /// `AgentBackgroundMonitoringService` and may be inactive while this is on.
        public var agentBackgroundMonitoringEnabled = false {
            didSet {
                preferences.setBool(
                    agentBackgroundMonitoringEnabled,
                    Keys.agentBackgroundMonitoringEnabled
                )
            }
        }

        /// BYOK provider used when on-device final transcript correction is unavailable.
        /// Only Ark is exposed today; keeping the provider explicit makes adding another
        /// fixed provider later a settings migration rather than an API-key migration.
        public var voiceCorrectionProvider: VoiceCorrectionProvider = .volcengineArk {
            didSet {
                preferences.setString(
                    voiceCorrectionProvider.rawValue,
                    Keys.voiceCorrectionProvider
                )
            }
        }

        /// Identifier selected from the provider's curated model list.
        /// There is deliberately no custom model field.
        public var voiceCorrectionModelID = "" {
            didSet {
                preferences.setString(voiceCorrectionModelID, Keys.voiceCorrectionModelID)
            }
        }

        /// User-saved benchmark winners keyed by provider. A missing provider
        /// entry means its built-in recommended models remain active.
        private var voiceCorrectionTestedModelIDsByProvider: [String: [String]] = [:]

        /// Base name for new tmux sessions created from iOS
        public var newSessionName = "claude" {
            didSet { preferences.setString(newSessionName, Keys.newSessionName) }
        }

        /// Width (columns) for new tmux sessions
        public var newSessionWidth = 120 {
            didSet { preferences.setInt(newSessionWidth, Keys.newSessionWidth) }
        }

        /// Height (rows) for new tmux sessions
        public var newSessionHeight = 40 {
            didSet { preferences.setInt(newSessionHeight, Keys.newSessionHeight) }
        }

        // MARK: - Computed Properties

        /// Whether at least one host is paired
        public var isPaired: Bool {
            !pairedHosts.isEmpty
        }

        /// The system device name (e.g. "iPhone"). Used as the default when the
        /// user has not provided a custom name.
        public var systemDeviceName: String {
            UIDevice.current.name
        }

        /// The display name for this iOS device. Returns the user's custom name
        /// when set, otherwise falls back to `systemDeviceName`.
        public var deviceName: String {
            let trimmed = customDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
            return systemDeviceName
        }

        var voiceCorrectionSelection: VoiceCorrectionSelection? {
            VoiceCorrectionSelection(
                provider: voiceCorrectionProvider,
                modelID: voiceCorrectionModelID
            )
        }

        func voiceCorrectionModelIDs(for provider: VoiceCorrectionProvider) -> [String] {
            guard let tested = voiceCorrectionTestedModelIDsByProvider[provider.rawValue],
                  !tested.isEmpty
            else {
                return provider.recommendedModelIDs
            }
            return tested
        }

        func hasTestedVoiceCorrectionModels(for provider: VoiceCorrectionProvider) -> Bool {
            voiceCorrectionTestedModelIDsByProvider[provider.rawValue]?.isEmpty == false
        }

        func saveTestedVoiceCorrectionModelIDs(
            _ modelIDs: [String],
            for provider: VoiceCorrectionProvider
        ) {
            var seen = Set<String>()
            let normalized = modelIDs.compactMap { modelID -> String? in
                let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
                return trimmed
            }
            guard !normalized.isEmpty else {
                resetTestedVoiceCorrectionModelIDs(for: provider)
                return
            }
            voiceCorrectionTestedModelIDsByProvider[provider.rawValue] = normalized
            persistTestedVoiceCorrectionModels()
        }

        func resetTestedVoiceCorrectionModelIDs(for provider: VoiceCorrectionProvider) {
            voiceCorrectionTestedModelIDsByProvider.removeValue(forKey: provider.rawValue)
            persistTestedVoiceCorrectionModels()
        }

        // MARK: - Initialization

        /// Create a single instance at the app root and propagate via `.environment()`.
        /// Multiple instances share the same UserDefaults backing store but maintain
        /// independent `@Observable` state — mutations on one instance will not
        /// trigger observation updates on another.
        public init() {
            // Load or generate device ID
            if let savedDeviceId = preferences.string(Keys.deviceId) {
                self.deviceId = savedDeviceId
            } else {
                let newDeviceId = UUID().uuidString
                preferences.setString(newDeviceId, Keys.deviceId)
                self.deviceId = newDeviceId
            }

            // Load custom device name (nil falls back to UIDevice.current.name)
            self.customDeviceName = preferences.string(Keys.customDeviceName)

            // Load settings
            self.externalServerURL = preferences.string(Keys.externalServerURL) ?? ""
            self.autoReconnect = preferences.optionalBool(Keys.autoReconnect) ?? false
            self.appearanceMode = AppearanceMode(rawValue: preferences.string(Keys.appearanceMode) ?? "") ?? .system

            // Terminal settings with iOS-appropriate defaults
            self.terminalFontName = preferences.string(Keys.terminalFontName) ?? "Menlo"
            self.terminalFontSize = preferences.optionalDouble(Keys.terminalFontSize) ?? 10
            self.terminalKeyboardControlPosition = TerminalKeyboardControlPosition(
                storedValue: preferences.string(Keys.terminalKeyboardControlPosition)
            )
            self.showTerminalKeyboardOnEntry = preferences.optionalBool(Keys.showTerminalKeyboardOnEntry) ?? false
            self.agentQuickInputEnabled = preferences.optionalBool(Keys.agentQuickInputEnabled) ?? false
            self.agentBackgroundMonitoringEnabled = preferences.optionalBool(
                Keys.agentBackgroundMonitoringEnabled
            ) ?? false
            self.voiceCorrectionProvider = VoiceCorrectionProvider(
                rawValue: preferences.string(Keys.voiceCorrectionProvider) ?? ""
            ) ?? .volcengineArk
            self.voiceCorrectionModelID = preferences.string(Keys.voiceCorrectionModelID) ?? ""
            if let data = preferences.data(Keys.voiceCorrectionTestedModelIDsByProvider),
               let decoded = try? JSONDecoder().decode(
                   [String: [String]].self,
                   from: data
               )
            {
                self.voiceCorrectionTestedModelIDsByProvider = decoded
            }

            // New session settings
            self.newSessionName = preferences.string(Keys.newSessionName) ?? "claude"
            self.newSessionWidth = preferences.optionalInt(Keys.newSessionWidth) ?? 120
            self.newSessionHeight = preferences.optionalInt(Keys.newSessionHeight) ?? 40

            // Load paired hosts
            self.pairedHosts = loadPairedHosts()
            self.remoteSessionOrderByHost = loadRemoteSessionOrder()

            // didSet doesn't fire during init, so refresh the App Group mirror
            // explicitly so the Notification Service Extension can label
            // notifications even if the user hasn't changed pairings since
            // upgrading.
            mirrorHostNamesToAppGroup()
        }

        private func persistTestedVoiceCorrectionModels() {
            let data = try? JSONEncoder().encode(voiceCorrectionTestedModelIDsByProvider)
            preferences.setData(data, Keys.voiceCorrectionTestedModelIDsByProvider)
        }

        // MARK: - Paired Hosts Storage

        private func loadPairedHosts() -> [PairedHost] {
            guard let data = preferences.data(Keys.pairedHosts) else {
                return []
            }

            do {
                return try JSONDecoder().decode([PairedHost].self, from: data)
            } catch {
                // Corrupted data, start fresh
                return []
            }
        }

        private func savePairedHosts() {
            guard let data = try? JSONEncoder().encode(pairedHosts) else {
                return
            }
            preferences.setData(data, Keys.pairedHosts)
            mirrorHostNamesToAppGroup()
        }

        private func loadRemoteSessionOrder() -> [String: [String]] {
            guard
                let data = preferences.data(Keys.remoteSessionOrderByHost),
                let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
            else {
                return [:]
            }
            return decoded.mapValues(RemoteSessionOrder.normalized)
        }

        private func saveRemoteSessionOrder() {
            guard let data = try? JSONEncoder().encode(remoteSessionOrderByHost) else {
                return
            }
            preferences.setData(data, Keys.remoteSessionOrderByHost)
        }

        /// Mirror pairId → display-name into the shared App Group container so the
        /// Notification Service Extension can label notifications by host.
        private func mirrorHostNamesToAppGroup() {
            let duplicateHostNames = Dictionary(grouping: pairedHosts, by: \.hostName)
                .filter { $0.value.count > 1 }
                .keys
            let mapping = Dictionary(uniqueKeysWithValues: pairedHosts.map { host in
                let showUsername = host.customName == nil
                    && duplicateHostNames.contains(host.hostName)
                return (host.id, host.displayName(showUsername: showUsername))
            })
            PairedHostNameStore.save(mapping)
        }

        // MARK: - Pairing Management

        /// Add a new paired host
        public func addPairing(_ host: PairedHost) {
            if let index = pairedHosts.firstIndex(where: { $0.id == host.id }) {
                pairedHosts[index] = host
            } else {
                pairedHosts.append(host)
            }
        }

        /// Remove a paired host by ID
        public func removePairing(id: String) {
            quickPhrases.setSyncEnabled(false, for: id)
            pairedHosts.removeAll { $0.id == id }
            remoteSessionOrderByHost.removeValue(forKey: id)
        }

        /// Get a paired host by ID
        public func getPairing(id: String) -> PairedHost? {
            pairedHosts.first { $0.id == id }
        }

        /// Update a paired host (e.g., custom name)
        public func updatePairing(_ host: PairedHost) {
            if let index = pairedHosts.firstIndex(where: { $0.id == host.id }) {
                pairedHosts[index] = host
            }
        }

        public func moveHostPairings(fromOffsets source: IndexSet, toOffset destination: Int) {
            pairedHosts = RemoteHostOrder.moving(
                pairedHosts,
                fromOffsets: source,
                toOffset: destination
            )
        }

        /// Clear all pairings
        public func clearAllPairings() {
            for host in pairedHosts { quickPhrases.setSyncEnabled(false, for: host.id) }
            pairedHosts = []
            remoteSessionOrderByHost = [:]
        }

        public func remoteSessionOrder(for hostId: String) -> [String] {
            remoteSessionOrderByHost[hostId] ?? []
        }

        public func setRemoteSessionOrder(_ sessionNames: [String], for hostId: String) {
            let normalized = RemoteSessionOrder.normalized(sessionNames)
            if normalized.isEmpty {
                remoteSessionOrderByHost.removeValue(forKey: hostId)
            } else {
                remoteSessionOrderByHost[hostId] = normalized
            }
        }

        public func replaceRemoteSessionName(_ oldName: String, with newName: String, for hostId: String) {
            guard let current = remoteSessionOrderByHost[hostId] else { return }
            setRemoteSessionOrder(
                RemoteSessionOrder.replacing(oldName, with: newName, in: current),
                for: hostId
            )
        }

        // MARK: - Display Helpers

        /// Check if a host's name is duplicated among paired hosts.
        ///
        /// Use this to determine whether to show the username for disambiguation.
        /// - Parameter host: The host to check
        /// - Returns: True if another paired host has the same hostName
        public func hasDuplicateHostName(for host: PairedHost) -> Bool {
            pairedHosts.contains { $0.id != host.id && $0.hostName == host.hostName }
        }
    }
#endif
