#if os(macOS)
    import CryptoKit
    import Foundation
    import ZIPFoundation

    struct BrowserExtensionPackagePreview: Sendable, Equatable, Codable {
        enum Source: String, Sendable, Codable { case zip, crx, webStore }

        let source: Source
        let name: String
        let version: String
        var extensionID: String?
        let sha256: String
        let permissions: [String]
        let hostPermissions: [String]
        let contentScriptMatches: [String]
        let optionalPermissions: [String]
        let optionalHostPermissions: [String]
    }

    /// Run on the package store actor, never on the main actor. The destination
    /// must be a new directory owned by the Host, not a Viewer-supplied path.
    enum BrowserExtensionPackage {
        struct Limits: Sendable {
            var archiveBytes = 64 * 1_024 * 1_024
            var expandedBytes = 256 * 1_024 * 1_024
            var fileBytes = 64 * 1_024 * 1_024
            var manifestBytes = 1_024 * 1_024
            var entryCount = 10_000
        }

        static func prepare(
            _ data: Data, source: BrowserExtensionPackagePreview.Source,
            directory: URL, limits: Limits = Limits()
        ) throws -> BrowserExtensionPackagePreview {
            guard !data.isEmpty, data.count <= limits.archiveBytes else {
                throw BrowserExtensionPackageError("The extension package exceeds the compressed size limit.")
            }
            let crx = source == .zip ? nil : try BrowserExtensionCRX.verify(data)
            let zip = crx?.archive ?? data
            let expectedCount = try entryCount(in: zip)
            guard expectedCount > 0, expectedCount <= limits.entryCount else {
                throw BrowserExtensionPackageError("The extension package is empty or contains too many files.")
            }
            let archive = try Archive(data: zip, accessMode: .read)
            let entries = Array(archive.prefix(expectedCount + 1))
            guard entries.count == expectedCount else {
                throw BrowserExtensionPackageError("The ZIP archive is damaged or contains encrypted entries.")
            }
            try validate(entries, limits: limits)
            let root = try manifestRoot(entries)
            let manager = FileManager.default
            // Do not remove or replace an existing directory, including on failure.
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do {
                var expanded = 0
                for entry in entries {
                    try Task.checkCancellation()
                    let path = String(entry.path.dropFirst(root.count))
                    if path.isEmpty {
                        continue
                    }
                    let target = directory.appendingPathComponent(path)
                    if entry.type == .directory {
                        try manager.createDirectory(at: target, withIntermediateDirectories: true)
                        continue
                    }
                    try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data().write(to: target, options: .withoutOverwriting)
                    let handle = try FileHandle(forWritingTo: target)
                    do {
                        var size = 0
                        let limit = path == "manifest.json" ? min(limits.fileBytes, limits.manifestBytes) : limits.fileBytes
                        let checksum = try archive.extract(entry, bufferSize: 64 * 1_024) { chunk in
                            try Task.checkCancellation()
                            guard chunk.count <= limit - size, chunk.count <= limits.expandedBytes - expanded else {
                                throw BrowserExtensionPackageError("The extracted extension exceeds the size limit.")
                            }
                            size += chunk.count
                            expanded += chunk.count
                            try handle.write(contentsOf: chunk)
                        }
                        guard size == entry.uncompressedSize, checksum == entry.checksum else {
                            throw BrowserExtensionPackageError("An extension file failed its size or checksum check.")
                        }
                        try handle.close()
                    } catch {
                        try handle.close()
                        throw error
                    }
                }
                return try preview(data: data, source: source, directory: directory, crx: crx, manifestLimit: limits.manifestBytes)
            } catch {
                do { try manager.removeItem(at: directory) }
                catch let cleanupError {
                    throw BrowserExtensionPackageError("\(error.localizedDescription) Temporary package cleanup failed: \(cleanupError.localizedDescription)")
                }
                throw error
            }
        }

        private static func validate(_ entries: [Entry], limits: Limits) throws {
            var paths: [String: Entry.EntryType] = [:]
            var total: UInt64 = 0
            for entry in entries {
                let raw = entry.path
                let path = entry.type == .directory && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
                let components = path.split(separator: "/", omittingEmptySubsequences: false)
                guard
                    entry.type != .symlink, !raw.contains("\\"), !raw.contains(":"),
                    !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                    !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                    throw BrowserExtensionPackageError("The extension contains an unsafe path or symbolic link: \(raw)")
                }
                let key = path.precomposedStringWithCanonicalMapping.lowercased()
                guard paths.updateValue(entry.type, forKey: key) == nil else {
                    throw BrowserExtensionPackageError("The extension contains duplicate or case-conflicting paths: \(raw)")
                }
                guard
                    entry.uncompressedSize <= UInt64(limits.fileBytes),
                    entry.uncompressedSize <= UInt64(limits.expandedBytes) - total,
                    entry.type != .directory || entry.uncompressedSize == 0 else {
                    throw BrowserExtensionPackageError("The extracted extension exceeds the size limit.")
                }
                total += entry.uncompressedSize
            }
            for path in paths.keys {
                let components = path.split(separator: "/")
                for length in 1..<components.count {
                    let parent = components.prefix(length).joined(separator: "/")
                    guard paths[parent] != .file else {
                        throw BrowserExtensionPackageError("An extension file conflicts with a directory: \(parent)")
                    }
                }
            }
        }

        private static func manifestRoot(_ entries: [Entry]) throws -> String {
            if entries.contains(where: { $0.path == "manifest.json" && $0.type == .file }) {
                return ""
            }
            let candidates = entries.filter {
                $0.type == .file && $0.path.split(separator: "/").count == 2 && $0.path.hasSuffix("/manifest.json")
            }
            if candidates.count == 1, let manifest = candidates.first {
                let prefix = String(manifest.path.dropLast("manifest.json".count))
                if entries.allSatisfy({ $0.path.hasPrefix(prefix) }) {
                    return prefix
                }
            }
            throw BrowserExtensionPackageError("Expected manifest.json at the ZIP root or inside a single enclosing directory.")
        }

        private static func preview(
            data: Data, source: BrowserExtensionPackagePreview.Source, directory: URL,
            crx: BrowserExtensionCRX.Verified?, manifestLimit: Int
        ) throws -> BrowserExtensionPackagePreview {
            let manifestURL = directory.appendingPathComponent("manifest.json")
            let bytes = try Data(contentsOf: manifestURL)
            guard
                bytes.count <= manifestLimit,
                var manifest = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                (manifest["manifest_version"] as? NSNumber)?.doubleValue == 3,
                let name = manifest["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let version = manifest["version"] as? String, validVersion(version) else {
                throw BrowserExtensionPackageError("A Manifest V3 extension with a valid name and version is required.")
            }
            var key: Data?
            if let value = manifest["key"] {
                guard
                    let encoded = value as? String, let decoded = Data(base64Encoded: encoded.filter { !$0.isWhitespace }),
                    !decoded.isEmpty, decoded.count <= 8_192 else {
                    throw BrowserExtensionPackageError("The manifest extension key is invalid.")
                }
                key = decoded
            }
            if let crx {
                guard key == nil || key == crx.publicKey else {
                    throw BrowserExtensionPackageError("The manifest key does not match the verified CRX3 developer key.")
                }
                // Unpacked Chromium installs need the verified key to retain the CRX ID.
                // Only this metadata is added; no extension script is modified.
                key = crx.publicKey
                manifest["key"] = crx.publicKey.base64EncodedString()
                try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
            }
            func strings(_ field: String) throws -> [String] {
                guard let value = manifest[field] else { return [] }
                guard let array = value as? [String] else {
                    throw BrowserExtensionPackageError("Invalid \(field) in the extension manifest.")
                }
                return Array(Set(array)).sorted()
            }
            var contentMatches: [String] = []
            if let scripts = manifest["content_scripts"] {
                guard let scripts = scripts as? [[String: Any]], scripts.allSatisfy({ $0["matches"] is [String] }) else {
                    throw BrowserExtensionPackageError("Invalid content scripts in the extension manifest.")
                }
                contentMatches = scripts.flatMap { $0["matches"] as? [String] ?? [] }
            }
            return try BrowserExtensionPackagePreview(
                source: source, name: localizedName(name, manifest: manifest, directory: directory, limit: manifestLimit), version: version,
                extensionID: key.map { BrowserExtensionCRX.extensionID(publicKey: $0) },
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                permissions: strings("permissions"), hostPermissions: strings("host_permissions"),
                contentScriptMatches: Array(Set(contentMatches)).sorted(),
                optionalPermissions: strings("optional_permissions"), optionalHostPermissions: strings("optional_host_permissions")
            )
        }

        private static func localizedName(_ name: String, manifest: [String: Any], directory: URL, limit: Int) throws -> String {
            guard name.hasPrefix("__MSG_"), name.hasSuffix("__") else { return name }
            guard
                let locale = manifest["default_locale"] as? String, !locale.isEmpty,
                locale.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || (48...57).contains($0) }) else {
                throw BrowserExtensionPackageError("The extension's localized name has no valid default locale.")
            }
            let url = directory.appendingPathComponent("_locales/\(locale)/messages.json")
            let handle = try FileHandle(forReadingFrom: url)
            let bytes = try handle.read(upToCount: limit + 1) ?? Data()
            try handle.close()
            guard
                bytes.count <= limit, let messages = try JSONSerialization.jsonObject(with: bytes) as? [String: [String: Any]],
                let message = messages.first(where: { $0.key.lowercased() == name.dropFirst(6).dropLast(2).lowercased() })?.value["message"] as? String,
                !message.isEmpty else {
                throw BrowserExtensionPackageError("The extension's localized name could not be read.")
            }
            return message
        }

        private static func validVersion(_ version: String) -> Bool {
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            return (1...4).contains(parts.count) && parts.allSatisfy {
                !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } &&
                    ($0.count == 1 || !$0.hasPrefix("0")) && UInt16($0) != nil
            } && parts.contains { $0 != "0" }
        }

        /// ZIPFoundation's iterator stops at malformed/encrypted entries. Compare
        /// against the declared count so a valid prefix cannot hide a bad tail.
        /// Our bounded package size does not require ZIP64 or multi-volume ZIPs.
        private static func entryCount(in data: Data) throws -> Int {
            guard data.count >= 22 else { throw invalidArchive }
            func uint(_ offset: Int, _ length: Int) -> Int {
                (0..<length).reduce(0) { $0 | Int(data[offset + $1]) << (8 * $1) }
            }
            for offset in stride(from: data.count - 22, through: max(0, data.count - 22 - 65_535), by: -1) {
                guard uint(offset, 4) == 0x06054B50, offset + 22 + uint(offset + 20, 2) == data.count else { continue }
                let count = uint(offset + 10, 2)
                guard
                    uint(offset + 4, 2) == 0, uint(offset + 6, 2) == 0,
                    uint(offset + 8, 2) == count, count != 65_535,
                    uint(offset + 12, 4) + uint(offset + 16, 4) == offset else { throw invalidArchive }
                return count
            }
            throw invalidArchive
        }

        private static let invalidArchive = BrowserExtensionPackageError("The ZIP archive is invalid. ZIP64 and multi-volume archives are not supported.")
    }
#endif
