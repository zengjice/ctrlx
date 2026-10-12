import CtrlxCommon
import Testing
@testable import CtrlxFeature

@Suite("iOS new session name migration")
struct NewSessionNameTests {
    private let key = "newSessionName"
    private let migrationKey = "newSessionName.neutralDefaultMigrated"

    @Test("New installs use the neutral default and finish migration")
    func freshInstall() {
        let preferences = PreferencesService.inMemory()

        #expect(NewSessionName.load(from: preferences, forKey: key) == "session")
        #expect(preferences.optionalBool(migrationKey) == true)
        #expect(NewSessionName.load(from: preferences, forKey: key) == "session")
    }

    @Test("The persisted legacy default is migrated and survives relaunch")
    func legacyDefault() {
        let preferences = PreferencesService.inMemory()
        preferences.setString("claude", key)

        #expect(NewSessionName.load(from: preferences, forKey: key) == "session")
        #expect(preferences.string(key) == "session")
        #expect(preferences.optionalBool(migrationKey) == true)
        #expect(NewSessionName.load(from: preferences, forKey: key) == "session")
    }

    @Test("Other saved names are preserved exactly", arguments: ["session", "coding", "claude-code", "Claude", "claude "])
    func customName(name: String) {
        let preferences = PreferencesService.inMemory()
        preferences.setString(name, key)

        #expect(NewSessionName.load(from: preferences, forKey: key) == name)
        #expect(preferences.string(key) == name)
        #expect(preferences.optionalBool(migrationKey) == true)
    }

    @Test("An explicit name change after migration is not overwritten", arguments: ["claude", "work"])
    func changeAfterMigration(name: String) {
        let preferences = PreferencesService.inMemory()
        preferences.setString("claude", key)
        #expect(NewSessionName.load(from: preferences, forKey: key) == "session")
        preferences.setString(name, key)

        #expect(NewSessionName.load(from: preferences, forKey: key) == name)
        #expect(preferences.string(key) == name)
    }

    @Test("New installs and customized installs also preserve a later choice of claude", arguments: [nil, "coding"] as [String?])
    func laterLegacyName(initialName: String?) {
        let preferences = PreferencesService.inMemory()
        preferences.setString(initialName, key)
        #expect(NewSessionName.load(from: preferences, forKey: key) == (initialName ?? "session"))
        preferences.setString("claude", key)

        #expect(NewSessionName.load(from: preferences, forKey: key) == "claude")
        #expect(preferences.string(key) == "claude")
    }

    @Test("Migration leaves unrelated settings unchanged")
    func unrelatedPreferences() {
        let preferences = PreferencesService.inMemory()
        preferences.setString("claude", key)
        preferences.setString("device-id", "deviceId")
        preferences.setInt(80, "newSessionWidth")
        preferences.setInt(50, "newSessionHeight")
        preferences.setBool(false, "newSessionAutoFit")

        #expect(NewSessionName.load(from: preferences, forKey: key) == "session")
        #expect(preferences.string("deviceId") == "device-id")
        #expect(preferences.optionalInt("newSessionWidth") == 80)
        #expect(preferences.optionalInt("newSessionHeight") == 50)
        #expect(preferences.optionalBool("newSessionAutoFit") == false)
    }
}
