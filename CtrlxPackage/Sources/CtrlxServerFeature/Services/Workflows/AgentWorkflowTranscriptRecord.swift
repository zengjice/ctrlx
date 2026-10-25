import CtrlxNetworking
import Foundation

/// Native images are not completion evidence. Strip their JSON string payloads
/// while retaining the entire message envelope, including Claude's ancestry.
/// All other strings and JSON syntax still go through the provider's parser.
struct AgentWorkflowTranscriptRecord {
    private struct Container {
        let object: Bool
        var expectingKey = true
        var key: String?
    }

    private enum StringKind { case key, text, image, imageURL }
    private static let maximumRetainedBytes = 2 * 1_024 * 1_024
    // 32 legal 20 MiB images, Base64 with every slash escaped, plus metadata.
    private static let maximumRecordBytes = maximumRetainedBytes + AgentWorkflowWire.maximumAttachments * ((20 * 1_024 * 1_024 + 2) / 3 * 8 + 1_024)
    private var containers: [Container] = []
    private var stringKind: StringKind?
    private var keyBytes: [UInt8] = []
    private var urlPrefix: [UInt8] = []
    private var escaped = false
    private var unicodeDigits = 0
    private var rawBytes = 0
    private(set) var retained = Data()

    mutating func append(_ bytes: Data.SubSequence) throws {
        rawBytes += bytes.count
        guard rawBytes <= Self.maximumRecordBytes else { throw tooLarge() }
        for byte in bytes {
            if let kind = stringKind {
                let closing = byte == 34 && !escaped && unicodeDigits == 0
                if kind == .key, keyBytes.count <= 128 {
                    keyBytes.append(byte)
                }
                if kind == .imageURL {
                    // Probe only the fixed prefix. Ordinary URLs remain intact.
                    urlPrefix.append(byte)
                    let prefix = Array("data:image".utf8)
                    if !prefix.starts(with: urlPrefix) || closing {
                        retained.append(contentsOf: urlPrefix)
                        urlPrefix.removeAll(keepingCapacity: true)
                        stringKind = .text
                    } else if urlPrefix.count == prefix.count {
                        urlPrefix.removeAll(keepingCapacity: true)
                        stringKind = .image
                    }
                } else if kind != .image || closing {
                    retained.append(byte)
                }
                if kind == .image, byte >= 128 {
                    throw invalidString()
                }
                // Even discarded payloads must be well-formed JSON strings.
                if unicodeDigits > 0 {
                    guard (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) else { throw invalidString() }
                    unicodeDigits -= 1
                } else if escaped {
                    guard [34, 92, 47, 98, 102, 110, 114, 116, 117].contains(byte) else { throw invalidString() }
                    if byte == 117 {
                        unicodeDigits = 4
                    }
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte < 32 {
                    throw invalidString()
                } else if closing {
                    if kind == .key, keyBytes.count <= 128 {
                        containers[containers.count - 1].key = try JSONDecoder().decode(String.self, from: Data(keyBytes))
                    }
                    stringKind = nil
                }
            } else {
                retained.append(byte)
                switch byte {
                case 34:
                    if containers.last?.object == true, containers.last?.expectingKey == true {
                        stringKind = .key
                        keyBytes = [34]
                    } else {
                        let key = containers.last?.key
                        let parentKey = containers.dropLast().last?.key
                        if key == "data", parentKey == "source" {
                            stringKind = .image
                        } else if
                            key == "image_url" || (key == "url" && parentKey == "image_url")
                            || (containers.last?.object == false && parentKey == "images") {
                            stringKind = .imageURL
                        } else {
                            stringKind = .text
                        }
                    }
                case 123,
                     91:
                    guard containers.count < 128 else { throw tooLarge() }
                    containers.append(.init(object: byte == 123))
                case 125,
                     93:
                    if !containers.isEmpty {
                        containers.removeLast()
                    }
                case 58:
                    if containers.last?.object == true {
                        containers[containers.count - 1].expectingKey = false
                    }
                case 44:
                    if containers.last?.object == true {
                        containers[containers.count - 1].expectingKey = true
                        containers[containers.count - 1].key = nil
                    }
                default: break
                }
            }
            guard retained.count <= Self.maximumRetainedBytes else { throw tooLarge() }
        }
    }

    func finish() throws -> Data {
        guard stringKind == nil else { throw invalidString() }
        return retained
    }

    private func tooLarge() -> AgentWorkflowError {
        AgentWorkflowError("A native transcript record exceeds the verification limit.")
    }

    private func invalidString() -> AgentWorkflowError {
        AgentWorkflowError("A native transcript contains an invalid JSON string.")
    }
}
