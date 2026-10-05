import CtrlxCommon

enum NewSessionName {
    static let defaultValue = "session"

    static func load(from preferences: PreferencesService, forKey key: String) -> String {
        var name = preferences.string(key) ?? defaultValue
        let migrationKey = "\(key).neutralDefaultMigrated"
        if preferences.optionalBool(migrationKey) != true {
            if name == "claude" {
                name = defaultValue
                preferences.setString(name, key)
            }
            // Mark every install, so a later explicit choice of "claude" is preserved.
            preferences.setBool(true, migrationKey)
        }
        return name
    }
}
