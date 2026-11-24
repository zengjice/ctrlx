import CtrlxNetworking
import Foundation

/// Streams away image strings while retaining the message envelope. The
/// turn-metadata mode also drops strings unrelated to native turn verification.
struct AgentWorkflowTranscriptRecord {
    private struct Container {
        let object: Bool
        var expectingKey = true
        var key: String?
    }

    private enum StringKind { case key, text, image, imageURL, discardedText }
    private static let maximumRetainedBytes = 2 * 1_024 * 1_024
    // 32 legal 20 MiB images, Base64 with every slash escaped, plus metadata.
    private static let maximumRecordBytes = maximumRetainedBytes + AgentWorkflowWire.maximumAttachments * ((20 * 1_024 * 1_024 + 2) / 3 * 8 + 1_024)
    private let turnMetadataOnly: Bool
    private let retainSubmissionRejections: Bool
    private var containers: [Container] = []
    private var stringKind: StringKind?
    private var keyBytes: [UInt8] = []
    private var urlPrefix: [UInt8] = []
    private var escaped = false
    private var unicodeDigits = 0
    private var utf8Remaining = 0
    private var utf8Next: ClosedRange<UInt8> = 0x80...0xBF
    private var rawBytes = 0
    private(set) var retained = Data()

    init(turnMetadataOnly: Bool = false, retainSubmissionRejections: Bool = false) {
        self.turnMetadataOnly = turnMetadataOnly
        self.retainSubmissionRejections = retainSubmissionRejections
    }

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
                } else if (kind != .image && kind != .discardedText) || closing {
                    retained.append(byte)
                }
                if kind == .image, byte >= 128 {
                    throw invalidString()
                }
                if kind == .discardedText, byte >= 128 || utf8Remaining != 0 {
                    try validateUTF8(byte)
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
                        if turnMetadataOnly {
                            let isRecordField = containers.count == 1 && (key == "type" || key == "sessionId" || key == "promptId")
                            let isTurnField = containers.count == 2 && parentKey == "payload" && (key == "type" || key == "turn_id" || key == "id")
                            let isRejectionField = retainSubmissionRejections && (
                                (containers.count == 1 && (key == "subtype" || key == "timestamp" || key == "uuid" || key == "content"))
                                    || (containers.count == 3 && parentKey == "ending" && key == "kind")
                            )
                            stringKind = isRecordField || isTurnField || isRejectionField ? .text : .discardedText
                        } else if key == "data", parentKey == "source" {
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

    /// A discarded string still has to contain valid UTF-8, including across reads.
    private mutating func validateUTF8(_ byte: UInt8) throws {
        if utf8Remaining > 0 {
            guard utf8Next.contains(byte) else { throw invalidString() }
            utf8Remaining -= 1
            utf8Next = 0x80...0xBF
            return
        }
        switch byte {
        case 0xC2...0xDF: utf8Remaining = 1
        case 0xE0: (utf8Remaining, utf8Next) = (2, 0xA0...0xBF)
        case 0xE1...0xEC,
             0xEE...0xEF: utf8Remaining = 2
        case 0xED: (utf8Remaining, utf8Next) = (2, 0x80...0x9F)
        case 0xF0: (utf8Remaining, utf8Next) = (3, 0x90...0xBF)
        case 0xF1...0xF3: utf8Remaining = 3
        case 0xF4: (utf8Remaining, utf8Next) = (3, 0x80...0x8F)
        default: throw invalidString()
        }
    }

    private func tooLarge() -> AgentWorkflowError {
        AgentWorkflowError("A native transcript record exceeds the verification limit.")
    }

    private func invalidString() -> AgentWorkflowError {
        AgentWorkflowError("A native transcript contains an invalid JSON string.")
    }
}
