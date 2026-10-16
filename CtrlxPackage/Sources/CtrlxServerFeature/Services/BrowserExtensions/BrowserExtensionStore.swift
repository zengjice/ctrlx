#if os(macOS)
    import CryptoKit
    import Foundation

    struct BrowserExtensionRuntimeItem: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let name: String
        let version: String
        let state: String
        let path: String?
        var isEnabled: Bool {
            state == "ENABLED"
        }
    }

    struct PreparedBrowserExtension: Codable, Sendable, Equatable, Identifiable {
        let id: UUID
        let preview: BrowserExtensionPackagePreview
        let replacing: BrowserExtensionRuntimeItem?
        let previousSource: BrowserExtensionPackagePreview.Source?
    }

    /// Owns immutable package versions. Runtime state determines which version
    /// is installed; receipts only retain provenance and in-flight install data.
    actor BrowserExtensionStore {
        private struct Receipt: Codable {
            let package: PreparedBrowserExtension
            var submitted: Bool
        }

        private let root: URL
        private var packages: URL {
            root.appendingPathComponent("packages", isDirectory: true)
        }

        private var receipts: URL {
            root.appendingPathComponent("receipts", isDirectory: true)
        }

        init(profile: URL) {
            self.root = profile.resolvingSymlinksInPath().appendingPathComponent("CtrlXExtensions", isDirectory: true)
        }

        func prepare(
            data: Data, source: BrowserExtensionPackagePreview.Source,
            replacing: BrowserExtensionRuntimeItem? = nil, expectedStoreID: String? = nil
        ) throws -> PreparedBrowserExtension {
            try createDirectories()
            guard source != .webStore || expectedStoreID != nil else {
                throw BrowserExtensionPackageError("A store package must be bound to the requested extension ID.")
            }
            let previous = try replacing.map { try managedReceipt($0) }
            let previousKey: Data?
            if let replacing {
                previousKey = try manifestKey(at: URL(fileURLWithPath: replacing.path ?? ""))
                guard let previousKey, BrowserExtensionCRX.extensionID(publicKey: previousKey) == replacing.id else {
                    throw BrowserExtensionPackageError("The installed extension's identity could not be verified.")
                }
            } else {
                previousKey = nil
            }
            let token = UUID()
            let directory = packageURL(token)
            var preview = try BrowserExtensionPackage.prepare(data, source: source, directory: directory)
            do {
                if let expectedStoreID, preview.extensionID != expectedStoreID {
                    throw BrowserExtensionPackageError("The downloaded package's verified ID does not match the requested store extension.")
                }
                if preview.extensionID == nil {
                    // A generated public key gives unsigned ZIPs stable identity
                    // across versioned directories. It does not sign the package.
                    let key = previousKey ?? P256.Signing.PrivateKey().publicKey.derRepresentation
                    try writeKey(key, at: directory)
                    preview.extensionID = BrowserExtensionCRX.extensionID(publicKey: key)
                }
                if let replacing, preview.extensionID != replacing.id {
                    throw BrowserExtensionPackageError("This package has a different extension ID and cannot update the selected extension.")
                }
                let package = PreparedBrowserExtension(id: token, preview: preview, replacing: replacing, previousSource: previous?.package.preview.source)
                try save(Receipt(package: package, submitted: false))
                return package
            } catch {
                try FileManager.default.removeItem(at: directory)
                throw error
            }
        }

        func prepare(file: URL, replacing: BrowserExtensionRuntimeItem? = nil) throws -> PreparedBrowserExtension {
            guard let source = BrowserExtensionPackagePreview.Source(rawValue: file.pathExtension.lowercased()) else {
                throw BrowserExtensionPackageError("Choose a ZIP or CRX3 extension package.")
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: BrowserExtensionPackage.Limits().archiveBytes + 1) ?? Data()
            return try prepare(data: data, source: source, replacing: replacing)
        }

        func cancel(_ token: UUID) throws {
            let receipt = try read(token)
            guard !receipt.submitted else {
                throw BrowserExtensionPackageError("This package has been submitted to Chromium. Refresh its runtime state before removing it.")
            }
            try remove(token)
        }

        func abandon(_ token: UUID) throws {
            let receipt = try read(token)
            guard !receipt.submitted else { return }
            try remove(token)
        }

        func prepared(_ token: UUID) throws -> PreparedBrowserExtension {
            try read(token).package
        }

        /// Recheck the exact installed version immediately before submitting.
        /// Persist first: a deadline or process exit must not delete live files.
        func beginInstall(_ token: UUID, installed: [BrowserExtensionRuntimeItem]) throws -> URL {
            var receipt = try read(token)
            guard !receipt.submitted else {
                throw BrowserExtensionPackageError("This install was already submitted. Refresh the extension list to check its outcome.")
            }
            let package = receipt.package
            let existing = installed.first { $0.id == package.preview.extensionID }
            guard existing == package.replacing else {
                throw BrowserExtensionPackageError("The installed extension changed. Choose Update and review the package again.")
            }
            receipt.submitted = true
            try save(receipt)
            return packageURL(token)
        }

        func confirmInstall(_ token: UUID, installed: [BrowserExtensionRuntimeItem]) throws -> BrowserExtensionRuntimeItem {
            let receipt = try read(token)
            let package = receipt.package
            guard
                receipt.submitted, let active = installed.first(where: {
                    $0.id == package.preview.extensionID && $0.version == package.preview.version &&
                        $0.path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } == packageURL(token) &&
                        ($0.state == "ENABLED" || $0.state == "DISABLED")
                }) else {
                throw BrowserExtensionPackageError("Chromium has not confirmed this package as installed. Its files and the previous version have been kept.")
            }
            return active
        }

        func retirePrevious(_ token: UUID, installed: [BrowserExtensionRuntimeItem]) throws {
            _ = try confirmInstall(token, installed: installed)
            let package = try read(token).package
            // Only this transaction's prior version can be retired. Unrelated
            // or unresolved submissions are never swept by a list refresh.
            if
                let previous = package.replacing, let oldPath = previous.path,
                !installed.contains(where: { $0.path == oldPath }) {
                let old = try managedReceipt(previous)
                try remove(old.package.id)
            }
        }

        func isManaged(_ item: BrowserExtensionRuntimeItem) -> Bool {
            (try? managedReceipt(item)) != nil
        }

        func managedDirectory(_ item: BrowserExtensionRuntimeItem) throws -> URL {
            try packageURL(managedReceipt(item).package.id)
        }

        func removeUninstalled(_ item: BrowserExtensionRuntimeItem, installed: [BrowserExtensionRuntimeItem]) throws {
            guard !installed.contains(where: { $0.id == item.id }) else {
                throw BrowserExtensionPackageError("Chromium has not confirmed the extension was removed.")
            }
            let receipt = try managedReceipt(item)
            try remove(receipt.package.id)
        }

        private func managedReceipt(_ item: BrowserExtensionRuntimeItem) throws -> Receipt {
            guard
                let path = item.path, let token = UUID(uuidString: URL(fileURLWithPath: path).lastPathComponent),
                URL(fileURLWithPath: path).resolvingSymlinksInPath() == packageURL(token) else {
                throw BrowserExtensionPackageError("This extension was installed outside CtrlX. Manage it in the Chromium extension window.")
            }
            let receipt = try read(token)
            guard
                receipt.submitted, receipt.package.preview.extensionID == item.id,
                receipt.package.preview.version == item.version else {
                throw BrowserExtensionPackageError("The extension's package receipt does not match Chromium.")
            }
            return receipt
        }

        private func createDirectories() throws {
            for directory in [packages, receipts] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        }

        private func packageURL(_ token: UUID) -> URL {
            packages.appendingPathComponent(token.uuidString, isDirectory: true)
        }

        private func receiptURL(_ token: UUID) -> URL {
            receipts.appendingPathComponent(token.uuidString + ".json")
        }

        private func read(_ token: UUID) throws -> Receipt {
            let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL(token)))
            guard receipt.package.id == token else { throw BrowserExtensionPackageError("Invalid extension package receipt.") }
            return receipt
        }

        private func save(_ receipt: Receipt) throws {
            try JSONEncoder().encode(receipt).write(to: receiptURL(receipt.package.id), options: .atomic)
        }

        private func remove(_ token: UUID) throws {
            try FileManager.default.removeItem(at: packageURL(token))
            try FileManager.default.removeItem(at: receiptURL(token))
        }

        private func manifestKey(at directory: URL) throws -> Data? {
            let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (manifest?["key"] as? String).flatMap { Data(base64Encoded: $0.filter { !$0.isWhitespace }) }
        }

        private func writeKey(_ key: Data, at directory: URL) throws {
            let url = directory.appendingPathComponent("manifest.json")
            guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw BrowserExtensionPackageError("Invalid extension manifest.")
            }
            manifest["key"] = key.base64EncodedString()
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: url, options: .atomic)
        }
    }
#endif
