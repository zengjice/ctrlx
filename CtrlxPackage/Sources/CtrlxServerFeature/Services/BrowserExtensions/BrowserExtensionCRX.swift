#if os(macOS)
    import CryptoKit
    import Foundation
    import Security

    struct BrowserExtensionPackageError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? {
            message
        }

        init(_ message: String) {
            self.message = message
        }
    }

    /// CRX3 authenticates the archive and developer identity, not store approval.
    enum BrowserExtensionCRX {
        struct Verified {
            let archive: Data
            let publicKey: Data
            let extensionID: String
        }

        static func extensionID(publicKey: Data) -> String {
            let alphabet = Array("abcdefghijklmnop")
            return SHA256.hash(data: publicKey).prefix(16).map {
                String(alphabet[Int($0 >> 4)]) + String(alphabet[Int($0 & 15)])
            }.joined()
        }

        static func verify(_ data: Data) throws -> Verified {
            guard data.count >= 12, data.prefix(4) == Data("Cr24".utf8), data.littleEndian32(at: 4) == 3 else {
                throw BrowserExtensionPackageError("Only CRX3 extension packages are supported.")
            }
            let headerSize = Int(data.littleEndian32(at: 8))
            guard headerSize > 0, headerSize <= 1_048_576, headerSize < data.count - 12 else {
                throw BrowserExtensionPackageError("The CRX3 header is invalid or exceeds 1 MiB.")
            }
            let fields = try Proto.fields(Data(data[12..<12 + headerSize]))
            let signed = try Proto.single(10_000, in: fields)
            let identity = try Proto.single(1, in: Proto.fields(signed))
            guard identity.count == 16 else { throw BrowserExtensionPackageError("The CRX3 extension ID is invalid.") }
            let archive = Data(data[(12 + headerSize)...])
            var digest = SHA256()
            digest.update(data: Data("CRX3 SignedData\0".utf8))
            var length = UInt32(signed.count).littleEndian
            withUnsafeBytes(of: &length) { digest.update(data: Data($0)) }
            digest.update(data: signed)
            digest.update(data: archive)
            let signatureDigest = Data(digest.finalize())
            let proofs = fields.filter { $0.0 == 2 || $0.0 == 3 }
            guard !proofs.isEmpty, proofs.count <= 16 else {
                throw BrowserExtensionPackageError("The CRX3 package has no supported signature or too many signatures.")
            }
            var developerKey: Data?
            for (kind, bytes) in proofs {
                let proof = try Proto.fields(bytes)
                let publicKey = try Proto.single(1, in: proof)
                let signature = try Proto.single(2, in: proof)
                let key = try importPublicKey(publicKey, rsa: kind == 2)
                let algorithm: SecKeyAlgorithm = kind == 2 ? .rsaSignatureDigestPKCS1v15SHA256 : .ecdsaSignatureDigestX962SHA256
                guard SecKeyVerifySignature(key, algorithm, signatureDigest as CFData, signature as CFData, nil) else {
                    throw BrowserExtensionPackageError("CRX3 signature verification failed. The package may be damaged or modified.")
                }
                if Data(SHA256.hash(data: publicKey).prefix(16)) == identity {
                    developerKey = publicKey
                }
            }
            guard let developerKey else {
                throw BrowserExtensionPackageError("The CRX3 developer signature does not match its extension ID.")
            }
            return Verified(archive: archive, publicKey: developerKey, extensionID: extensionID(publicKey: developerKey))
        }

        private static func importPublicKey(_ spki: Data, rsa: Bool) throws -> SecKey {
            var outer = DER(spki)
            var sequence = try DER(outer.read(tag: 0x30))
            var algorithm = try DER(sequence.read(tag: 0x30))
            let oid = try algorithm.read(tag: 0x06)
            if rsa {
                guard oid == Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 1, 1, 1]) else { throw invalidKey }
                if !algorithm.isEmpty, try !algorithm.read(tag: 0x05).isEmpty {
                    throw invalidKey
                }
            } else {
                guard
                    oid == Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 2, 1]),
                    try algorithm.read(tag: 0x06) == Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 3, 1, 7]) else { throw invalidKey }
            }
            let bits = try sequence.read(tag: 0x03)
            guard outer.isEmpty, sequence.isEmpty, algorithm.isEmpty, bits.first == 0 else { throw invalidKey }
            guard rsa || (bits.count == 66 && bits[1] == 0x04) else { throw invalidKey }
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: rsa ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass: kSecAttrKeyClassPublic,
            ]
            guard let key = SecKeyCreateWithData(Data(bits.dropFirst()) as CFData, attributes as CFDictionary, nil) else {
                throw invalidKey
            }
            return key
        }

        private static let invalidKey = BrowserExtensionPackageError("The CRX3 public key is invalid or uses an unsupported algorithm.")

        private struct DER {
            let bytes: [UInt8]
            var offset = 0
            var isEmpty: Bool {
                offset == bytes.count
            }

            init(_ data: Data) {
                self.bytes = Array(data)
            }

            mutating func read(tag: UInt8) throws -> Data {
                guard bytes.count - offset >= 2, bytes[offset] == tag else { throw invalidKey }
                offset += 1
                var length = Int(bytes[offset])
                offset += 1
                if length & 0x80 != 0 {
                    let size = length & 0x7F
                    guard size > 0, size <= 4, size <= bytes.count - offset, bytes[offset] != 0 else { throw invalidKey }
                    length = 0
                    for byte in bytes[offset..<offset + size] {
                        length = length * 256 + Int(byte)
                    }
                    offset += size
                    guard length >= 128 else { throw invalidKey }
                }
                guard length <= bytes.count - offset else { throw invalidKey }
                defer { offset += length }
                return Data(bytes[offset..<offset + length])
            }
        }

        private enum Proto {
            static func single(_ tag: Int, in fields: [(Int, Data)]) throws -> Data {
                let matches = fields.filter { $0.0 == tag }
                guard matches.count == 1, let field = matches.first else { throw malformed }
                return field.1
            }

            static func fields(_ data: Data) throws -> [(Int, Data)] {
                let bytes = Array(data)
                var offset = 0
                var result: [(Int, Data)] = []
                func varint() throws -> UInt64 {
                    var value: UInt64 = 0
                    for index in 0..<10 {
                        guard offset < bytes.count else { throw malformed }
                        let byte = bytes[offset]
                        offset += 1
                        guard index < 9 || byte <= 1 else { throw malformed }
                        value |= UInt64(byte & 0x7F) << (index * 7)
                        if byte & 0x80 == 0 {
                            return value
                        }
                    }
                    throw malformed
                }
                while offset < bytes.count {
                    let key = try varint()
                    guard key >> 3 > 0, key >> 3 <= 0x1FFFFFFF else { throw malformed }
                    let wire = key & 7
                    if wire == 0 {
                        _ = try varint()
                        continue
                    }
                    let length: UInt64
                    switch wire {
                    case 1: length = 8
                    case 2: length = try varint()
                    case 5: length = 4
                    default: throw malformed
                    }
                    guard length <= UInt64(bytes.count - offset) else { throw malformed }
                    let end = offset + Int(length)
                    if wire == 2 {
                        result.append((Int(key >> 3), Data(bytes[offset..<end])))
                    }
                    offset = end
                }
                return result
            }

            static let malformed = BrowserExtensionPackageError("The CRX3 signature header is malformed.")
        }
    }

    fileprivate extension Data {
        func littleEndian32(at offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(self[offset + $1]) << ($1 * 8) }
        }
    }
#endif
