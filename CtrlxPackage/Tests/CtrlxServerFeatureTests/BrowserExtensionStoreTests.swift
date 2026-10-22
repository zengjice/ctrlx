#if os(macOS)
    import CryptoKit
    import Foundation
    import Testing
    import ZIPFoundation
    @testable import CtrlxServerFeature

    struct BrowserExtensionStoreTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_EXTENSION_FIXTURE_EXPORT"] != nil))
        func exportNativeUpdateFixture() async throws {
            let output = try URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["CTRLX_EXTENSION_FIXTURE_EXPORT"]))
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("experiments/cef-browser-probe/extension-fixture")
            let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            func archive(version: String) throws -> Data {
                let archive = try Archive(accessMode: .create)
                for file in files {
                    var data = try Data(contentsOf: file)
                    if file.lastPathComponent == "manifest.json" {
                        var manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                        manifest["version"] = version
                        manifest.removeValue(forKey: "key")
                        data = try JSONSerialization.data(withJSONObject: manifest)
                    }
                    try archive.addEntry(with: file.lastPathComponent, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                        data.subdata(in: Int(position)..<(Int(position) + size))
                    }
                }
                return try #require(archive.data)
            }
            let store = BrowserExtensionStore(profile: output)
            let first = try await store.prepare(data: archive(version: "1.0.0"), source: .zip)
            let firstPath = try await store.beginInstall(first.id, installed: [])
            let previous = try item(first, path: firstPath)
            let second = try await store.prepare(data: archive(version: "2.0.0"), source: .zip, replacing: previous)
            let secondPath = try await store.beginInstall(second.id, installed: [previous])
            #expect(first.preview.extensionID == second.preview.extensionID)
            try JSONSerialization.data(withJSONObject: [
                "first": firstPath.path,
                "second": secondPath.path,
                "id": #require(first.preview.extensionID),
            ], options: [.prettyPrinted])
                .write(to: output.appendingPathComponent("fixture-packages.json"))
        }

        @Test
        func unsignedZIPIdentitySurvivesUpdateAndStoreRestart() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = BrowserExtensionStore(profile: root)
            let first = try await store.prepare(data: package(version: "1"), source: .zip)
            let path = try await store.beginInstall(first.id, installed: [])
            let initial = try item(first, path: path)
            #expect(try await store.confirmInstall(first.id, installed: [initial]) == initial)
            let restarted = BrowserExtensionStore(profile: root)
            #expect(await restarted.isManaged(initial))
            let second = try await restarted.prepare(data: package(version: "2"), source: .zip, replacing: initial)
            #expect(second.preview.extensionID == first.preview.extensionID)
            let updatedPath = try await restarted.beginInstall(second.id, installed: [initial])
            #expect(updatedPath != path)
            #expect(FileManager.default.fileExists(atPath: path.path))
            let updated = try item(second, path: updatedPath)
            _ = try await restarted.confirmInstall(second.id, installed: [updated])
            #expect(FileManager.default.fileExists(atPath: path.path))
            try await restarted.retirePrevious(second.id, installed: [updated])
            #expect(!FileManager.default.fileExists(atPath: path.path))
            #expect(await restarted.isManaged(updated))
        }

        @Test
        func failedOrUnknownInstallRetainsBothPackages() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = BrowserExtensionStore(profile: root)
            let first = try await store.prepare(data: package(version: "1"), source: .zip)
            let oldPath = try await store.beginInstall(first.id, installed: [])
            let old = try item(first, path: oldPath)
            let second = try await store.prepare(data: package(version: "2"), source: .zip, replacing: old)
            let newPath = try await store.beginInstall(second.id, installed: [old])
            await #expect(throws: (any Error).self) { try await store.confirmInstall(second.id, installed: [old]) }
            await #expect(throws: (any Error).self) { try await store.cancel(second.id) }
            try await store.abandon(second.id)
            await #expect(throws: (any Error).self) { try await store.beginInstall(second.id, installed: [old]) }
            #expect(FileManager.default.fileExists(atPath: oldPath.path))
            #expect(FileManager.default.fileExists(atPath: newPath.path))
            #expect(await BrowserExtensionStore(profile: root).isManaged(old))
        }

        @Test
        func rejectsIdentityChangeAndUnreviewedReplacement() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = BrowserExtensionStore(profile: root)
            let key = P256.Signing.PrivateKey().publicKey.derRepresentation.base64EncodedString()
            let first = try await store.prepare(data: package(version: "1", key: key), source: .zip)
            let oldPath = try await store.beginInstall(first.id, installed: [])
            let old = try item(first, path: oldPath)
            let duplicate = try await store.prepare(data: package(version: "2", key: key), source: .zip)
            await #expect(throws: (any Error).self) { try await store.beginInstall(duplicate.id, installed: [old]) }
            try await store.cancel(duplicate.id)
            let otherKey = P256.Signing.PrivateKey().publicKey.derRepresentation.base64EncodedString()
            await #expect(throws: (any Error).self) {
                try await store.prepare(data: package(version: "2", key: otherKey), source: .zip, replacing: old)
            }
            let update = try await store.prepare(data: package(version: "2"), source: .zip, replacing: old)
            await #expect(throws: (any Error).self) { try await store.beginInstall(update.id, installed: []) }
            try await store.cancel(update.id)
            #expect(FileManager.default.fileExists(atPath: oldPath.path))
        }

        @Test
        func cannotClaimForeignRuntimePathsOrConfirmWrongVersion() async throws {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = BrowserExtensionStore(profile: root)
            let prepared = try await store.prepare(data: package(version: "1"), source: .zip)
            let path = try await store.beginInstall(prepared.id, installed: [])
            let wrong = try BrowserExtensionRuntimeItem(id: #require(prepared.preview.extensionID), name: "Fixture", version: "2", state: "ENABLED", path: path.path)
            await #expect(throws: (any Error).self) { try await store.confirmInstall(prepared.id, installed: [wrong]) }
            let foreign = BrowserExtensionRuntimeItem(id: wrong.id, name: wrong.name, version: "1", state: "ENABLED", path: root.appendingPathComponent(prepared.id.uuidString).path)
            #expect(await !store.isManaged(foreign))
            await #expect(throws: (any Error).self) { try await store.prepare(data: package(version: "2"), source: .zip, replacing: foreign) }
        }

        private func temporaryDirectory() throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            return root.resolvingSymlinksInPath()
        }

        private func item(_ prepared: PreparedBrowserExtension, path: URL) throws -> BrowserExtensionRuntimeItem {
            try BrowserExtensionRuntimeItem(id: #require(prepared.preview.extensionID), name: prepared.preview.name, version: prepared.preview.version, state: "ENABLED", path: path.path)
        }

        private func package(version: String, key: String? = nil) throws -> Data {
            var manifest: [String: Any] = ["manifest_version": 3, "name": "Fixture", "version": version]
            manifest["key"] = key
            let data = try JSONSerialization.data(withJSONObject: manifest)
            let archive = try Archive(accessMode: .create)
            try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
            return try #require(archive.data)
        }
    }
#endif
