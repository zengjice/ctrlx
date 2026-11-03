#if os(macOS)
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Mac identity preferences migration")
    @MainActor
    struct MacIdentityMigrationTests {
        @Test("Copies pairing and binary preferences while retaining the old domain")
        func copiesPreferences() throws {
            let old = "migration.fixture.old." + UUID().uuidString
            let new = "migration.fixture.new." + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: new))
            defer {
                defaults.removePersistentDomain(forName: old)
                defaults.removePersistentDomain(forName: new)
            }
            let data = Data([0, 255, 1])
            defaults.setPersistentDomain(["deviceId": "existing-device", "pairedViewers": data], forName: old)
            MacIdentityMigration.migratePreferences(defaults: defaults, from: old, to: new)
            let migrated = try #require(defaults.persistentDomain(forName: new))
            #expect(migrated["deviceId"] as? String == "existing-device")
            #expect(migrated["pairedViewers"] as? Data == data)
            #expect(defaults.persistentDomain(forName: old)?["deviceId"] as? String == "existing-device")
        }

        @Test("Existing new-domain settings win and subsequent deletions are preserved")
        func retainsCurrentChoices() throws {
            let old = "migration.fixture.old." + UUID().uuidString
            let new = "migration.fixture.new." + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: new))
            defer {
                defaults.removePersistentDomain(forName: old)
                defaults.removePersistentDomain(forName: new)
            }
            defaults.setPersistentDomain(["relay": "old", "deleted-later": true], forName: old)
            defaults.setPersistentDomain(["relay": "current"], forName: new)
            MacIdentityMigration.migratePreferences(defaults: defaults, from: old, to: new)
            var migrated = try #require(defaults.persistentDomain(forName: new))
            #expect(migrated["relay"] as? String == "current")
            migrated.removeValue(forKey: "deleted-later")
            defaults.setPersistentDomain(migrated, forName: new)
            MacIdentityMigration.migratePreferences(defaults: defaults, from: old, to: new)
            #expect(defaults.persistentDomain(forName: new)?["deleted-later"] == nil)
        }
    }
#endif
