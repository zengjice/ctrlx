#if os(macOS)
    import Foundation
    import Security
    import Testing
    @testable import CtrlxEncryption

    @Suite("Mac Keychain namespace migration", .serialized)
    struct MacKeychainServiceMigrationTests {
        private let oldService = MacKeychainServiceMigration.legacyService
        private let newService = MacKeychainServiceMigration.currentService

        private func withKeychain(_ operation: (SecKeychain) throws -> Void) throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            var keychain: SecKeychain?
            let password = "isolated-fixture-password"
            let status = password.withCString {
                SecKeychainCreate(
                    directory.appendingPathComponent("fixture.keychain").path,
                    UInt32(password.utf8.count),
                    $0,
                    false,
                    nil,
                    &keychain
                )
            }
            #expect(status == errSecSuccess)
            let fixture = try #require(keychain)
            defer { SecKeychainDelete(fixture) }
            try operation(fixture)
        }

        private func query(_ keychain: SecKeychain, _ service: String, _ account: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecMatchSearchList as String: [keychain],
            ]
        }

        private func add(_ keychain: SecKeychain, _ service: String, _ account: String, _ data: Data) throws {
            let attributes: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecValueData as String: data,
                kSecUseKeychain as String: keychain,
            ]
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else { throw CryptoError.keychainError(status: status) }
        }

        private func read(_ keychain: SecKeychain, _ service: String, _ account: String) throws -> Data? {
            var query = query(keychain, service, account)
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                return nil
            }
            guard status == errSecSuccess else { throw CryptoError.keychainError(status: status) }
            return result as? Data
        }

        @Test("Copies binary keys, session keys and API credentials while retaining the source")
        func copiesAllAccounts() throws {
            try withKeychain { fixture in
                let values = [
                    "private-key": Data([0, 255, 128, 65]),
                    "key-id": Data("identity".utf8),
                    "session-key-pair": Data([0, 0, 255]),
                    "provider-key": Data("fixture-api-key".utf8),
                ]
                for (account, data) in values {
                    try add(fixture, oldService, account, data)
                }
                #expect(try MacKeychainServiceMigration.copyIfNeeded(keychain: fixture) == values.count)
                for (account, data) in values {
                    #expect(try read(fixture, newService, account) == data)
                    #expect(try read(fixture, oldService, account) == data)
                }
                #expect(try MacKeychainServiceMigration.copyIfNeeded(keychain: fixture) == 0)
            }
        }

        @Test("Conflicts stop the migration before any credential is copied or overwritten")
        func rejectsConflicts() throws {
            try withKeychain { fixture in
                try add(fixture, oldService, "private-key", Data([1]))
                try add(fixture, oldService, "key-id", Data([2]))
                try add(fixture, newService, "key-id", Data([3]))
                #expect(throws: MacKeychainServiceMigration.MigrationError.self) {
                    try MacKeychainServiceMigration.copyIfNeeded(keychain: fixture)
                }
                #expect(try read(fixture, newService, "private-key") == nil)
                #expect(try read(fixture, newService, "key-id") == Data([3]))
                #expect(try read(fixture, oldService, "key-id") == Data([2]))
            }
        }

        @Test("An interrupted copy resumes when existing destination items match")
        func resumesMatchingPartialCopy() throws {
            try withKeychain { fixture in
                try add(fixture, oldService, "private-key", Data([1]))
                try add(fixture, newService, "private-key", Data([1]))
                try add(fixture, oldService, "key-id", Data([2]))
                #expect(try MacKeychainServiceMigration.copyIfNeeded(keychain: fixture) == 1)
                #expect(try read(fixture, newService, "key-id") == Data([2]))
            }
        }

        @Test("Later deletion of a migrated secret does not resurrect its old copy")
        func completedMigrationDoesNotRestoreDeletedSecrets() throws {
            try withKeychain { fixture in
                try add(fixture, oldService, "provider-key", Data([1]))
                try MacKeychainServiceMigration.copyIfNeeded(keychain: fixture)
                #expect(SecItemDelete(query(fixture, newService, "provider-key") as CFDictionary) == errSecSuccess)
                #expect(try MacKeychainServiceMigration.copyIfNeeded(keychain: fixture) == 0)
                #expect(try read(fixture, newService, "provider-key") == nil)
                #expect(try read(fixture, oldService, "provider-key") == Data([1]))
            }
        }

        @Test("A fresh installation with no legacy credentials completes without generating keys")
        func freshInstall() throws {
            try withKeychain { fixture in
                let copied = try MacKeychainServiceMigration.copyIfNeeded(keychain: fixture)
                let privateKey = try read(fixture, newService, "private-key")
                #expect(copied == 0)
                #expect(privateKey == nil)
            }
        }
    }
#endif
