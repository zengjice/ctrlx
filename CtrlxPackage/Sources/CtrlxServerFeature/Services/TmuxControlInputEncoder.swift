#if os(macOS)
    import CtrlxNetworking
    import Foundation

    /// Encodes small interactive input batches for tmux control mode.
    ///
    /// Literal bytes use `send-keys -H`, so user text never enters tmux's
    /// command grammar. Named keys come from a fixed allow-list. Large pastes,
    /// delays, and unsupported control characters return `nil` and stay on the
    /// existing process-based path.
    enum TmuxControlInputEncoder {
        static let maximumHexBytes = 4096

        private enum Segment {
            case hexadecimal([UInt8])
            case named([String])
        }

        /// Mouse reports and other raw input must stay byte-exact, including
        /// non-UTF8 bytes. Validate the entire batch before allowing any write.
        static func commands(paneId: String, rawBytes: Data) -> [String]? {
            guard isPaneId(paneId), rawBytes.count <= maximumHexBytes else { return nil }
            guard !rawBytes.isEmpty else { return [] }
            let encoded = rawBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            return ["send-keys -t \(paneId) -H \(encoded)"]
        }

        static func commands(paneId: String, keys: [TmuxKey]) -> [String]? {
            guard isPaneId(paneId), keys.count <= maximumHexBytes else { return nil }

            var segments: [Segment] = []
            var hexadecimalByteCount = 0

            for key in keys {
                switch key {
                case .delay:
                    return nil

                case let .text(text):
                    let utf8 = text.utf8
                    guard utf8.count <= maximumHexBytes - hexadecimalByteCount else { return nil }
                    let bytes = Array(utf8)
                    hexadecimalByteCount += bytes.count
                    appendHexadecimal(bytes, to: &segments)

                case let .ctrl(character):
                    guard let byte = controlByte(for: character) else { return nil }
                    guard hexadecimalByteCount < maximumHexBytes else { return nil }
                    hexadecimalByteCount += 1
                    appendHexadecimal([byte], to: &segments)

                case let .alt(character):
                    let bytes = [UInt8(0x1B)] + Array(String(character).utf8)
                    guard hexadecimalByteCount + bytes.count <= maximumHexBytes else { return nil }
                    hexadecimalByteCount += bytes.count
                    appendHexadecimal(bytes, to: &segments)

                case let .ctrlAlt(character):
                    guard let byte = controlByte(for: character) else { return nil }
                    guard hexadecimalByteCount + 2 <= maximumHexBytes else { return nil }
                    hexadecimalByteCount += 2
                    appendHexadecimal([0x1B, byte], to: &segments)

                default:
                    guard let name = namedKey(for: key) else { return nil }
                    appendNamed(name, to: &segments)
                }
            }

            return segments.compactMap { segment in
                switch segment {
                case let .hexadecimal(bytes):
                    guard !bytes.isEmpty else { return nil }
                    let encoded = bytes
                        .map { String(format: "%02x", $0) }
                        .joined(separator: " ")
                    return "send-keys -t \(paneId) -H \(encoded)"

                case let .named(names):
                    guard !names.isEmpty else { return nil }
                    return "send-keys -t \(paneId) \(names.joined(separator: " "))"
                }
            }
        }

        private static func appendHexadecimal(_ bytes: [UInt8], to segments: inout [Segment]) {
            guard !bytes.isEmpty else { return }
            if case let .hexadecimal(existing)? = segments.last {
                segments[segments.count - 1] = .hexadecimal(existing + bytes)
            } else {
                segments.append(.hexadecimal(bytes))
            }
        }

        private static func appendNamed(_ name: String, to segments: inout [Segment]) {
            if case let .named(existing)? = segments.last {
                segments[segments.count - 1] = .named(existing + [name])
            } else {
                segments.append(.named([name]))
            }
        }

        private static func namedKey(for key: TmuxKey) -> String? {
            switch key {
            case .enter: "Enter"
            case .shiftEnter: "S-Enter"
            case .escape: "Escape"
            case .tab: "Tab"
            case .backtab: "BTab"
            case .space: "Space"
            case .backspace: "BSpace"
            case .delete: "Delete"
            case .up: "Up"
            case .down: "Down"
            case .left: "Left"
            case .right: "Right"
            case .home: "Home"
            case .end: "End"
            case .pageUp: "PageUp"
            case .pageDown: "PageDown"
            case .text, .ctrl, .alt, .ctrlAlt, .delay: nil
            }
        }

        private static func controlByte(for character: Character) -> UInt8? {
            let scalars = String(character).unicodeScalars
            guard scalars.count == 1, let value = scalars.first?.value, value <= 0x7F else { return nil }

            switch value {
            case 0x20, 0x40, 0x60:
                return 0
            case 0x41 ... 0x5F:
                return UInt8(value - 0x40)
            case 0x61 ... 0x7A:
                return UInt8(value - 0x60)
            case 0x3F:
                return 0x7F
            default:
                return nil
            }
        }

        private static func isPaneId(_ value: String) -> Bool {
            let bytes = Array(value.utf8)
            guard bytes.count > 1, bytes[0] == UInt8(ascii: "%") else { return false }
            return bytes.dropFirst().allSatisfy { (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) }
        }
    }
#endif
