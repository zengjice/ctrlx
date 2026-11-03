#if os(macOS)
    import Foundation
    import Security

    /// Copies the previous service into the new namespace; never removes source items.
    public enum MacKeychainServiceMigration {
        public static let legacyService = "com.jicezeng.ctrlx.e2ee"
        public static let currentService = "com.gravtice.ctrlx.e2ee"
        private static let markerAccount = "namespace-migration-v1"

        public enum MigrationError: LocalizedError {
            case invalidItem
            case conflictingItem
            case verificationFailed

            public var errorDescription: String? {
                switch self {
                case .invalidItem: "An existing CtrlX Keychain item could not be copied."
                case .conflictingItem: "The old and new CtrlX Keychain services contain different data. Neither was overwritten."
                case .verificationFailed: "The copied CtrlX Keychain data failed verification. Existing data was retained."
                }
            }
        }

        /// An explicit keychain is used by tests so they never touch login credentials.
        @discardableResult
        public static func copyIfNeeded(keychain: SecKeychain? = nil) throws -> Int {
            var keychain = keychain
            if keychain == nil {
                let status = SecKeychainCopyDefault(&keychain)
                guard status == errSecSuccess else { throw CryptoError.keychainError(status: status) }
            }
            guard let keychain else { throw MigrationError.invalidItem }

            func query(service: String, account: String? = nil) -> [String: Any] {
                var result: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecMatchSearchList as String: [keychain],
                ]
                if let account {
                    result[kSecAttrAccount as String] = account
                }
                return result
            }

            func read(service: String = currentService, account: String) throws -> Data? {
                var query = query(service: service, account: account)
                query[kSecReturnData as String] = true
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                if status == errSecItemNotFound {
                    return nil
                }
                guard status == errSecSuccess else { throw CryptoError.keychainError(status: status) }
                guard let data = result as? Data else { throw MigrationError.invalidItem }
                return data
            }

            let marker = Data("copied-and-verified".utf8)
            if let existing = try read(account: markerAccount) {
                guard existing == marker else { throw MigrationError.conflictingItem }
                return 0
            }
            var sourceQuery = query(service: legacyService)
            sourceQuery[kSecMatchLimit as String] = kSecMatchLimitAll
            sourceQuery[kSecReturnAttributes as String] = true
            var result: CFTypeRef?
            let status = SecItemCopyMatching(sourceQuery as CFDictionary, &result)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CryptoError.keychainError(status: status)
            }
            let source: [[String: Any]]
            if status == errSecItemNotFound {
                source = []
            } else if let items = result as? [[String: Any]] {
                source = items
            } else {
                throw MigrationError.invalidItem
            }
            // Check conflicts before writing any item. An interrupted copy can be retried.
            let items = try source.map { item -> (String, Data) in
                guard
                    let account = item[kSecAttrAccount as String] as? String,
                    account != markerAccount,
                    let data = try read(service: legacyService, account: account)
                else { throw MigrationError.invalidItem }
                if let existing = try read(account: account), existing != data {
                    throw MigrationError.conflictingItem
                }
                return (account, data)
            }

            var copied = 0
            for (account, data) in items + [(markerAccount, marker)] {
                if try read(account: account) == nil {
                    let attributes: [String: Any] = [
                        kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: currentService,
                        kSecAttrAccount as String: account,
                        kSecValueData as String: data,
                        kSecUseKeychain as String: keychain,
                    ]
                    let status = SecItemAdd(attributes as CFDictionary, nil)
                    guard status == errSecSuccess else { throw CryptoError.keychainError(status: status) }
                    if account != markerAccount {
                        copied += 1
                    }
                }
                guard try read(account: account) == data else { throw MigrationError.verificationFailed }
            }
            return copied
        }
    }
#endif
