#if os(iOS) || os(macOS)
    import Dependencies
    import Foundation
    import Observation

    /// Device-local configuration shared by both clients. These keys deliberately
    /// match the original iOS settings; extracting the store must not reset them.
    @Observable
    @MainActor
    final public class VoiceCorrectionSettings {
        public var provider: VoiceCorrectionProvider = .volcengineArk {
            didSet { preferences.setString(provider.rawValue, "voiceCorrectionProvider") }
        }

        public var modelID = "" {
            didSet { preferences.setString(modelID, "voiceCorrectionModelID") }
        }

        @ObservationIgnored
        @Dependency(PreferencesService.self) private var preferences
        private var testedModelIDsByProvider: [String: [String]] = [:]

        public init() {
            self.provider = VoiceCorrectionProvider(
                rawValue: preferences.string("voiceCorrectionProvider") ?? ""
            ) ?? .volcengineArk
            self.modelID = preferences.string("voiceCorrectionModelID") ?? ""
            if
                let data = preferences.data("voiceCorrectionTestedModelIDsByProvider"),
                let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
                self.testedModelIDsByProvider = decoded
            }
        }

        public var selection: VoiceCorrectionSelection? {
            VoiceCorrectionSelection(provider: provider, modelID: modelID)
        }

        func modelIDs(for provider: VoiceCorrectionProvider) -> [String] {
            guard let tested = testedModelIDsByProvider[provider.rawValue], !tested.isEmpty else {
                return provider.recommendedModelIDs
            }
            return tested
        }

        func hasTestedModels(for provider: VoiceCorrectionProvider) -> Bool {
            testedModelIDsByProvider[provider.rawValue]?.isEmpty == false
        }

        func saveTestedModelIDs(_ modelIDs: [String], for provider: VoiceCorrectionProvider) {
            var seen = Set<String>()
            let normalized = modelIDs.compactMap { modelID -> String? in
                let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && seen.insert(trimmed).inserted ? trimmed : nil
            }
            if normalized.isEmpty {
                testedModelIDsByProvider.removeValue(forKey: provider.rawValue)
            } else {
                testedModelIDsByProvider[provider.rawValue] = normalized
            }
            persistTestedModels()
        }

        func resetTestedModels(for provider: VoiceCorrectionProvider) {
            testedModelIDsByProvider.removeValue(forKey: provider.rawValue)
            persistTestedModels()
        }

        private func persistTestedModels() {
            let data = try? JSONEncoder().encode(testedModelIDsByProvider)
            preferences.setData(data, "voiceCorrectionTestedModelIDsByProvider")
        }
    }
#endif
