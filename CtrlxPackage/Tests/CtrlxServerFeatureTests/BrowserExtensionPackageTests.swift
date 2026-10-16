#if os(macOS)
    import CryptoKit
    import Foundation
    import Security
    import Testing
    import ZIPFoundation
    @testable import CtrlxServerFeature

    struct BrowserExtensionPackageTests {
        private let manifest = Data(#"{"manifest_version":3,"name":"Fixture","version":"1.2","permissions":["tabs","storage"],"host_permissions":["https://example.com/*"],"optional_permissions":["debugger"],"optional_host_permissions":["https://optional.example/*"],"content_scripts":[{"matches":["https://injected.example/*"],"js":["content.js"]}]}"#.utf8)

        @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_EXTENSION_ENV_SAMPLE"] != nil))
        func suppliedENVSample() throws {
            let path = try #require(ProcessInfo.processInfo.environment["CTRLX_EXTENSION_ENV_SAMPLE"])
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            try inTemporaryDirectory { root in
                let preview = try BrowserExtensionPackage.prepare(data, source: .crx, directory: root.appendingPathComponent("env"))
                #expect(preview.extensionID == "imebogohheacbbmhfiiddakclhifpbde")
                #expect(preview.name == "ENV-Plugin")
                #expect(preview.permissions.contains("debugger"))
                #expect(preview.permissions.contains("nativeMessaging"))
                print("ENV package verified: version=\(preview.version), sha256=\(preview.sha256)")
            }
            if let path = ProcessInfo.processInfo.environment["CTRLX_EXTENSION_ENV_RUNTIME_DESTINATION"] {
                // Explicit opt-in prepares a new disposable native-test package
                // through the product verifier. Never reuse or overwrite a path.
                _ = try BrowserExtensionPackage.prepare(data, source: .crx, directory: URL(fileURLWithPath: path))
                print("Verified ENV runtime fixture: \(path)")
            }
        }

        @Test(arguments: ["", "bundle/"])
        func preparesZIPAndPreviewsAllAccess(prefix: String) throws {
            try inTemporaryDirectory { root in
                let zip = try archive([(prefix + "manifest.json", manifest), (prefix + "content.js", Data("// fixture".utf8))])
                let destination = root.appendingPathComponent("prepared")
                let preview = try BrowserExtensionPackage.prepare(zip, source: .zip, directory: destination)
                #expect(preview.name == "Fixture")
                #expect(preview.version == "1.2")
                #expect(preview.extensionID == nil)
                #expect(preview.permissions == ["storage", "tabs"])
                #expect(preview.hostPermissions == ["https://example.com/*"])
                #expect(preview.contentScriptMatches == ["https://injected.example/*"])
                #expect(preview.optionalPermissions == ["debugger"])
                #expect(preview.optionalHostPermissions == ["https://optional.example/*"])
                #expect(try Data(contentsOf: destination.appendingPathComponent("content.js")) == Data("// fixture".utf8))
            }
        }

        @Test
        func storePackageMustMatchTheRequestedVerifiedIdentity() async throws {
            let signer = try CRXSigner(rsa: false)
            let data = try signer.package(archive([("manifest.json", manifest)]))
            let identifier = BrowserExtensionCRX.extensionID(publicKey: signer.publicKey)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = BrowserExtensionStore(profile: root)
            await #expect(throws: (any Error).self) { try await store.prepare(data: data, source: .webStore) }
            await #expect(throws: (any Error).self) {
                try await store.prepare(data: data, source: .webStore, expectedStoreID: "imebogohheacbbmhfiiddakclhifpbde")
            }
            let prepared = try await store.prepare(data: data, source: .webStore, expectedStoreID: identifier)
            #expect(prepared.preview.extensionID == identifier)
            #expect(prepared.preview.source == .webStore)
            try await store.cancel(prepared.id)
        }

        @Test
        func localizedPreviewAndUnsignedKey() throws {
            try inTemporaryDirectory { root in
                let key = Data([1, 2, 3])
                let manifest = Data(#"{"manifest_version":3,"name":"__MSG_title__","version":"1","default_locale":"zh_CN","key":"AQID"}"#.utf8)
                let zip = try archive([
                    ("manifest.json", manifest),
                    ("_locales/zh_CN/messages.json", Data(#"{"title":{"message":"测试扩展"}}"#.utf8)),
                ])
                let preview = try BrowserExtensionPackage.prepare(zip, source: .zip, directory: root.appendingPathComponent("prepared"))
                #expect(preview.name == "测试扩展")
                #expect(preview.source == .zip)
                #expect(preview.extensionID == BrowserExtensionCRX.extensionID(publicKey: key))
            }
        }

        @Test(arguments: ["../outside", "/absolute", "folder/../../outside", "folder\\outside", "a//b", "a/./b", "a\0b", "a:b"])
        func rejectsUnsafePaths(path: String) throws {
            try rejects(archive([("manifest.json", manifest), (path, Data())]))
        }

        @Test(arguments: ["manifest.json", "MANIFEST.JSON", "folder", "FOLDER/a"])
        func rejectsPathCollisions(path: String) throws {
            try rejects(archive([("manifest.json", manifest), ("folder/a", Data()), (path, Data())]))
        }

        @Test
        func rejectsSymlinkAndPreservesExistingDestination() throws {
            let zip = try Archive(accessMode: .create)
            try add(zip, "manifest.json", manifest)
            try add(zip, "escape", Data("/tmp".utf8), type: .symlink)
            try rejects(#require(zip.data))
            try inTemporaryDirectory { root in
                let sentinel = root.appendingPathComponent("existing")
                try Data("keep".utf8).write(to: sentinel)
                #expect(throws: (any Error).self) {
                    try BrowserExtensionPackage.prepare(archive([("manifest.json", manifest)]), source: .zip, directory: root)
                }
                #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
            }
        }

        @Test(arguments: ["compressed", "expanded", "file", "manifest", "count"])
        func enforcesLimits(limit: String) throws {
            var limits = BrowserExtensionPackage.Limits()
            switch limit {
            case "compressed": limits.archiveBytes = 10
            case "expanded": limits.expandedBytes = 100
            case "file": limits.fileBytes = 100
            case "manifest": limits.manifestBytes = 100
            default: limits.entryCount = 1
            }
            try rejects(archive([("manifest.json", manifest), ("large", Data(repeating: 0, count: 2_000))]), limits: limits)
        }

        @Test
        func catchesFalseDeclaredSizeAndChecksum() throws {
            let original = try archive([("manifest.json", manifest), ("payload", Data(repeating: 1, count: 8_192))])
            var wrongSize = original
            let central = try #require(wrongSize.range(of: Data([0x50, 0x4B, 0x01, 0x02]), options: .backwards))
            wrongSize.replaceSubrange((central.lowerBound + 24)..<(central.lowerBound + 28), with: [8, 0, 0, 0])
            var limits = BrowserExtensionPackage.Limits()
            limits.fileBytes = 1_000
            try rejects(wrongSize, limits: limits)

            var wrongCRC = original
            wrongCRC[central.lowerBound + 16] ^= 1
            try rejects(wrongCRC)
        }

        @Test
        func rejectsEncryptedOrTruncatedEntriesInsteadOfAcceptingPrefix() throws {
            let original = try archive([("manifest.json", manifest), ("payload", Data([1]))])
            var encrypted = original
            let central = try #require(encrypted.range(of: Data([0x50, 0x4B, 0x01, 0x02]), options: .backwards))
            encrypted[central.lowerBound + 8] |= 1
            try rejects(encrypted)
            try rejects(Data(original.dropLast()))
        }

        @Test(arguments: ["2", "3.1", "true"])
        func rejectsUnsupportedManifests(version: String) throws {
            try rejects(archive([("manifest.json", Data("{\"manifest_version\":\(version),\"name\":\"Bad\",\"version\":\"1\"}".utf8))]))
        }

        @Test(arguments: [true, false])
        func verifiesCRXAndRetainsIdentity(rsa: Bool) throws {
            let signer = try CRXSigner(rsa: rsa)
            let zip = try archive([("manifest.json", manifest)])
            let crx = try signer.package(zip)
            let verified = try BrowserExtensionCRX.verify(crx)
            #expect(verified.archive == zip)
            #expect(verified.publicKey == signer.publicKey)
            try inTemporaryDirectory { root in
                let preview = try BrowserExtensionPackage.prepare(crx, source: .crx, directory: root.appendingPathComponent("v1"))
                let second = try BrowserExtensionPackage.prepare(crx, source: .crx, directory: root.appendingPathComponent("v2"))
                #expect(preview.extensionID == second.extensionID)
                #expect(preview.extensionID == verified.extensionID)
                let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("v1/manifest.json"))) as? [String: Any]
                #expect(saved?["key"] as? String == signer.publicKey.base64EncodedString())
            }
        }

        @Test
        func rejectsTamperedCRXAndIdentityMismatch() throws {
            let signer = try CRXSigner(rsa: true)
            let zip = try archive([("manifest.json", manifest)])
            var crx = try signer.package(zip)
            crx[crx.count - 1] ^= 1
            #expect(throws: BrowserExtensionPackageError.self) { try BrowserExtensionCRX.verify(crx) }
            #expect(throws: BrowserExtensionPackageError.self) {
                try BrowserExtensionCRX.verify(signer.package(zip, identity: Data(repeating: 0, count: 16)))
            }
            let badManifest = Data(#"{"manifest_version":3,"name":"Bad","version":"1","key":"AQID"}"#.utf8)
            try rejects(signer.package(archive([("manifest.json", badManifest)])), source: .crx)
        }

        @Test
        func verifiesEveryProofAndRejectsBrokenHeaders() throws {
            let rsa = try CRXSigner(rsa: true)
            let ec = try CRXSigner(rsa: false)
            let zip = try archive([("manifest.json", manifest)])
            let signed = CRXSigner.field(1, Data(SHA256.hash(data: rsa.publicKey).prefix(16)))
            var input = Data("CRX3 SignedData\0".utf8) + CRXSigner.le32(signed.count) + signed + zip
            let proof1 = try rsa.proof(input)
            let proof2 = try ec.proof(input)
            let header = proof1 + proof2 + CRXSigner.field(10_000, signed)
            let good = Data("Cr24".utf8) + CRXSigner.le32(3) + CRXSigner.le32(header.count) + header + zip
            #expect(try BrowserExtensionCRX.verify(good).publicKey == rsa.publicKey)
            input.append(0)
            let badHeader = try proof1 + ec.proof(input) + CRXSigner.field(10_000, signed)
            let bad = Data("Cr24".utf8) + CRXSigner.le32(3) + CRXSigner.le32(badHeader.count) + badHeader + zip
            #expect(throws: BrowserExtensionPackageError.self) { try BrowserExtensionCRX.verify(bad) }
            for data in [Data(), Data(good.prefix(11)), Data("Cr24".utf8) + CRXSigner.le32(2) + Data(count: 50), Data(good.prefix(15))] {
                #expect(throws: BrowserExtensionPackageError.self) { try BrowserExtensionCRX.verify(data) }
            }
        }

        private func rejects(_ data: Data, source: BrowserExtensionPackagePreview.Source = .zip, limits: BrowserExtensionPackage.Limits = .init()) throws {
            try inTemporaryDirectory { root in
                let destination = root.appendingPathComponent("candidate")
                #expect(throws: (any Error).self) {
                    try BrowserExtensionPackage.prepare(data, source: source, directory: destination, limits: limits)
                }
                #expect(!FileManager.default.fileExists(atPath: destination.path))
            }
        }

        private func inTemporaryDirectory(_ body: (URL) throws -> Void) throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CtrlX-extension-tests-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            try body(root)
        }

        private func archive(_ entries: [(String, Data)]) throws -> Data {
            let archive = try Archive(accessMode: .create)
            for (path, data) in entries {
                try add(archive, path, data)
            }
            return try #require(archive.data)
        }

        private func add(_ archive: Archive, _ path: String, _ data: Data, type: Entry.EntryType = .file) throws {
            try archive.addEntry(with: path, type: type, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { offset, size in
                Data(data[Int(offset)..<min(Int(offset) + size, data.count)])
            }
        }
    }

    private struct CRXSigner {
        let privateKey: SecKey
        let publicKey: Data
        let rsa: Bool

        init(rsa: Bool) throws {
            self.rsa = rsa
            self.privateKey = try #require(SecKeyCreateRandomKey([
                kSecAttrKeyType: rsa ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits: rsa ? 2_048 : 256,
            ] as CFDictionary, nil))
            let key = try #require(SecKeyCopyPublicKey(privateKey))
            let raw = try #require(SecKeyCopyExternalRepresentation(key, nil)) as Data
            let algorithm = rsa ? Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 1, 1, 1, 5, 0]) :
                Data([0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 2, 1, 6, 8, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 3, 1, 7])
            self.publicKey = Self.der(0x30, algorithm + Self.der(3, Data([0]) + raw))
        }

        func package(_ zip: Data, identity: Data? = nil) throws -> Data {
            let signed = Self.field(1, identity ?? Data(SHA256.hash(data: publicKey).prefix(16)))
            let input = Data("CRX3 SignedData\0".utf8) + Self.le32(signed.count) + signed + zip
            let header = try proof(input) + Self.field(10_000, signed)
            return Data("Cr24".utf8) + Self.le32(3) + Self.le32(header.count) + header + zip
        }

        func proof(_ input: Data) throws -> Data {
            let signature = try #require(SecKeyCreateSignature(privateKey, rsa ? .rsaSignatureMessagePKCS1v15SHA256 : .ecdsaSignatureMessageX962SHA256, input as CFData, nil)) as Data
            return Self.field(rsa ? 2 : 3, Self.field(1, publicKey) + Self.field(2, signature))
        }

        static func le32(_ value: Int) -> Data {
            Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
        }

        static func field(_ key: Int, _ value: Data) -> Data {
            varint(key * 8 + 2) + varint(value.count) + value
        }

        static func varint(_ value: Int) -> Data {
            var value = value
            var bytes: [UInt8] = []
            repeat {
                bytes.append(UInt8(value & 0x7F) | (value > 127 ? 0x80 : 0))
                value >>= 7
            } while value > 0
            return Data(bytes)
        }

        static func der(_ tag: UInt8, _ content: Data) -> Data {
            var length = content.count
            var bytes: [UInt8] = []
            repeat {
                bytes.insert(UInt8(length & 255), at: 0)
                length >>= 8
            } while length > 0
            return Data([tag] + (content.count < 128 ? bytes : [0x80 | UInt8(bytes.count)] + bytes)) + content
        }
    }
#endif
