#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite("Mac quick phrase device settings integration")
    struct QuickPhraseDeviceSettingsTests {
        private let key = Data(repeating: 7, count: 32).base64EncodedString()

        private func settings(_ prefs: PreferencesService) -> AppSettings {
            withDependencies { $0[PreferencesService.self] = prefs } operation: { AppSettings() }
        }

        private func viewer(_ name: String = "Home") -> PairedViewer {
            .init(id: "incoming", deviceName: name, partnerPublicKey: key, partnerPublicKeyId: "key-id")
        }

        private func host() -> PairedHost {
            .init(id: "outgoing", hostName: "Home", username: "user", partnerPublicKey: key, partnerPublicKeyId: "key-id")
        }

        @Test("Both lists load before migration, preserving all four local legacy states", arguments: 0..<4)
        func loadBothLists(mask: Int) throws {
            let prefs = PreferencesService.inMemory()
            prefs.setData(try JSONEncoder().encode([viewer()]), AppSettings.Keys.pairedViewers.rawValue)
            prefs.setData(try JSONEncoder().encode([host()]), AppSettings.Keys.pairedHosts.rawValue)
            prefs.setBool(mask & 1 != 0, "terminalQuickPhrases.sync.incoming")
            prefs.setBool(mask & 2 != 0, "terminalQuickPhrases.sync.outgoing")
            let app = settings(prefs)
            #expect(app.quickPhrases.syncDevices.count == 1)
            #expect(app.quickPhrases.isSyncEnabled(for: "incoming") == (mask & 1 != 0))
            #expect(app.quickPhrases.isSyncEnabled(for: "outgoing") == (mask & 2 != 0))
        }

        @Test("Updating a viewer never transiently unpairs it; clearing roles preserves remaining device consent")
        func pairingLifecycle() {
            let prefs = PreferencesService.inMemory()
            let app = settings(prefs)
            app.addPairing(viewer())
            app.quickPhrases.setSyncEnabled(true, for: "incoming")
            app.addPairing(viewer("Renamed"))
            #expect(app.quickPhrases.isSyncEnabled(for: "incoming"))
            app.addHostPairing(host())
            #expect(app.quickPhrases.syncDevices.count == 1)
            #expect(app.quickPhrases.isSyncEnabled(for: "outgoing"))
            app.clearAllPairings()
            #expect(app.quickPhrases.isSyncEnabled(for: "outgoing"))
            #expect(!app.quickPhrases.isSyncEnabled(for: "incoming"))
            app.clearAllHostPairings()
            #expect(app.quickPhrases.syncDevices.isEmpty)
            app.addPairing(viewer())
            #expect(!app.quickPhrases.isSyncEnabled(for: "incoming"))
        }
    }
#endif
