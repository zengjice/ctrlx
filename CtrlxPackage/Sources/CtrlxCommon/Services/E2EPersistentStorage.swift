#if canImport(Security)
    import CtrlxEncryption
    import Foundation

    /// Opt-in restart-test storage. The production app continues to use
    /// UserDefaults and Keychain; these files contain only isolated test keys.
    final public class E2EPersistentStorage: @unchecked Sendable {
        private enum Preference: Codable {
            case string(String)
            case bool(Bool)
            case integer(Int)
            case double(Double)
            case data(Data)
        }

        private struct State: Codable {
            var preferences: [String: Preference] = [:]
            var keyPair: StoredKeyPair?
            var sessionKeys: [String: Data] = [:]
            var secrets: [String: String] = [:]
        }

        private let lock = NSLock()
        private let file: URL
        private var state: State

        public init(root: URL) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            self.file = root.appendingPathComponent("e2e-storage.json")
            self.state = try FileManager.default.fileExists(atPath: file.path)
                ? JSONDecoder().decode(State.self, from: Data(contentsOf: file))
                : State()
        }

        public static func fromArguments(_ arguments: [String] = CommandLine.arguments) -> E2EPersistentStorage? {
            guard arguments.contains("--e2e-test"), arguments.contains("--e2e-persistent-storage") else { return nil }
            guard let index = arguments.firstIndex(of: "--ctrlx-state-root"), index + 1 < arguments.count else {
                preconditionFailure("Persistent E2E storage requires an explicit isolated state root")
            }
            do {
                return try E2EPersistentStorage(root: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
            } catch {
                preconditionFailure("Could not load isolated E2E storage: \(error)")
            }
        }

        public var preferences: PreferencesService {
            PreferencesService(
                string: { key in self.read {
                    if case let .string(value) = $0.preferences[key] {
                        value
                    } else {
                        nil
                    }
                } },
                setString: { value, key in self.setPreference(value.map(Preference.string), key: key) },
                optionalBool: { key in self.read {
                    if case let .bool(value) = $0.preferences[key] {
                        value
                    } else {
                        nil
                    }
                } },
                setBool: { value, key in self.setPreference(.bool(value), key: key) },
                optionalInt: { key in self.read {
                    if case let .integer(value) = $0.preferences[key] {
                        value
                    } else {
                        nil
                    }
                } },
                setInt: { value, key in self.setPreference(.integer(value), key: key) },
                optionalDouble: { key in self.read {
                    if case let .double(value) = $0.preferences[key] {
                        value
                    } else {
                        nil
                    }
                } },
                setDouble: { value, key in self.setPreference(.double(value), key: key) },
                data: { key in self.read {
                    if case let .data(value) = $0.preferences[key] {
                        value
                    } else {
                        nil
                    }
                } },
                setData: { value, key in self.setPreference(value.map(Preference.data), key: key) }
            )
        }

        public var secrets: SecretsService {
            SecretsService(
                generateKeyPair: {
                    let pair = StoredKeyPair.generateNew()
                    try self.update { $0.keyPair = pair }
                    return pair
                },
                loadKeyPair: { self.read(\.keyPair) },
                hasStoredKeyPair: { self.read { $0.keyPair != nil } },
                deleteKeys: { try self.update { $0.keyPair = nil
                    $0.sessionKeys.removeAll()
                } },
                storeSessionKey: { value, key in try self.update { $0.sessionKeys[key] = value } },
                loadSessionKey: { key in self.read { $0.sessionKeys[key] } },
                deleteSessionKey: { key in try self.update { $0.sessionKeys[key] = nil } },
                hasStoredSessionKey: { key in self.read { $0.sessionKeys[key] != nil } },
                storeSecret: { value, key in try self.update { $0.secrets[key] = value } },
                loadSecret: { key in self.read { $0.secrets[key] } },
                deleteSecret: { key in try self.update { $0.secrets[key] = nil } }
            )
        }

        private func read<T>(_ body: (State) -> T) -> T {
            lock.withLock { body(state) }
        }

        private func update(_ body: (inout State) -> Void) throws {
            try lock.withLock {
                var next = state
                body(&next)
                try JSONEncoder().encode(next).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                state = next
            }
        }

        private func setPreference(_ value: Preference?, key: String) {
            do { try update { $0.preferences[key] = value } }
            catch { preconditionFailure("Could not save isolated E2E preferences: \(error)") }
        }
    }
#endif
