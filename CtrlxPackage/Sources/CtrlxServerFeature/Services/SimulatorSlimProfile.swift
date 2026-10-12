#if os(macOS)
    import CtrlxSimulatorProtocol
    import Foundation

    struct SimulatorSlimCategory: Decodable, Sendable {
        let id: String
        let labels: [String]
    }

    struct SimulatorSlimFeature: Decodable, Sendable {
        let id: String
        let labels: [String]
    }

    struct SimulatorSlimProfile: Encodable, Sendable {
        let name: String
        let keep: [String]

        // Retain speech, language input, accounts, purchases, WebKit and system pickers.
        static let balancedDisabled: Set<String> = [
            "com.apple.PosterBoard", "com.apple.chronod", "com.apple.liveactivitiesd",
            "com.apple.siriinferenced", "com.apple.siriknowledged", "com.apple.siri.context.service",
            "com.apple.siri.acousticsignature", "com.apple.speechmodeltrainingd",
            "com.apple.intelligenceplatformd", "com.apple.intelligencecontextd", "com.apple.intelligenceflowd",
            "com.apple.intelligencetasksd", "com.apple.generativeexperiencesd", "com.apple.knowledgeconstructiond",
            "com.apple.modelcatalogd", "com.apple.modelmanagerd", "com.apple.mlhostd", "com.apple.mlruntimed",
            "com.apple.proactiveeventtrackerd", "com.apple.newsd", "com.apple.weatherd",
            "com.apple.Maps.mapssyncd", "com.apple.gamed",
        ]

        init(selection: SimulatorProfile, requires: [String], categories: [SimulatorSlimCategory], features: [SimulatorSlimFeature]) throws {
            let allLabels = Set(categories.flatMap(\.labels))
            let knownFeatures = Dictionary(uniqueKeysWithValues: features.map { ($0.id, $0.labels) })
            var disabled = selection == .balanced ? Self.balancedDisabled : []
            guard disabled.isSubset(of: allLabels) else {
                throw SimulatorFailure("The bundled simslim does not match the CtrlX service allowlist")
            }
            for feature in requires {
                guard let labels = knownFeatures[feature] else {
                    throw SimulatorFailure("Unknown required simulator feature: \(feature)")
                }
                disabled.subtract(labels)
                if feature == "siri", let category = categories.first(where: { $0.id == "siri" }) {
                    disabled.subtract(category.labels)
                }
                if feature == "widgets", let category = categories.first(where: { $0.id == "widgets" }) {
                    disabled.subtract(category.labels)
                }
            }
            name = "ctrlx-\(selection.rawValue)-v1"
            keep = allLabels.subtracting(disabled).sorted()
        }
    }
#endif
