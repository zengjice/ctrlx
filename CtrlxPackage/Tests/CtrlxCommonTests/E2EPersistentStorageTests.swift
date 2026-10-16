import Foundation
import Testing
@testable import CtrlxCommon

@Suite("Isolated E2E restart storage")
struct E2EPersistentStorageTests {
    @Test("Preference types and pairing keys survive reconstruction without crossing roots")
    func reconstruction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-e2e-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try E2EPersistentStorage(root: root.appendingPathComponent("one"))
        let two = try E2EPersistentStorage(root: root.appendingPathComponent("two"))
        let prefs = one.preferences
        prefs.setString("fixture", "text")
        prefs.setBool(false, "bool")
        prefs.setInt(42, "integer")
        prefs.setDouble(0.35, "double")
        prefs.setData(Data([1, 2, 3]), "data")
        let pair = try await one.secrets.generateKeyPair()
        try await one.secrets.storeSessionKey(Data([4, 5]), "pair")
        try await one.secrets.storeSecret("test-only", "secret")
        two.preferences.setString("independent", "text")
        let reopened = try E2EPersistentStorage(root: root.appendingPathComponent("one"))
        #expect(reopened.preferences.string("text") == "fixture")
        #expect(reopened.preferences.optionalBool("bool") == false)
        #expect(reopened.preferences.optionalBool("absent") == nil)
        #expect(reopened.preferences.optionalInt("integer") == 42)
        #expect(reopened.preferences.optionalDouble("double") == 0.35)
        #expect(reopened.preferences.data("data") == Data([1, 2, 3]))
        #expect(try reopened.secrets.loadKeyPair()?.privateKeyData == pair.privateKeyData)
        #expect(try reopened.secrets.loadKeyPair()?.keyId == pair.keyId)
        #expect(try await reopened.secrets.loadSessionKey("pair") == Data([4, 5]))
        #expect(try await reopened.secrets.loadSecret("secret") == "test-only")
        #expect(try two.secrets.loadKeyPair() == nil)
        #expect(try await two.secrets.loadSessionKey("pair") == nil)
        try await reopened.secrets.deleteKeys()
        reopened.preferences.setData(nil, "data")
        reopened.preferences.setString(nil, "text")
        let deleted = try E2EPersistentStorage(root: root.appendingPathComponent("one"))
        #expect(try deleted.secrets.loadKeyPair() == nil)
        #expect(try await deleted.secrets.loadSessionKey("pair") == nil)
        #expect(deleted.preferences.data("data") == nil)
        #expect(deleted.preferences.string("text") == nil)
        #expect(try await deleted.secrets.loadSecret("secret") == "test-only")
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("one/e2e-storage.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("Corrupt fixture storage fails without replacing its contents; default launches stay in memory")
    func corrupt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-e2e-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try E2EPersistentStorage(root: root)
        let file = root.appendingPathComponent("e2e-storage.json")
        let invalid = Data("invalid fixture".utf8)
        try invalid.write(to: file)
        #expect(throws: (any Error).self) { try E2EPersistentStorage(root: root) }
        #expect(try Data(contentsOf: file) == invalid)
        #expect(E2EPersistentStorage.fromArguments(["--e2e-test"]) == nil)
        #expect(E2EPersistentStorage.fromArguments(["--e2e-persistent-storage"]) == nil)
    }
}
