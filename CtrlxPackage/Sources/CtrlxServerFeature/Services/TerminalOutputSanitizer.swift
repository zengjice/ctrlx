#if os(macOS)
    import CtrlxCommon
    import Foundation

    /// Reassembles the one terminal token that may straddle tmux `%output`
    /// notifications.
    ///
    /// Control mode splits pane output at arbitrary byte offsets: a notification
    /// may end inside either a UTF-8 scalar or an ANSI escape sequence. Downstream
    /// snapshot gates discard complete pre-snapshot output, so forwarding such a
    /// prefix on its own would leave the post-snapshot suffix as visible garbage.
    /// Keep only the unfinished token and release it once its final byte arrives.
    struct TerminalOutputTokenFramer: Sendable {
        private enum State: Sendable {
            case ground
            case utf8(continuations: Int)
            case escape
            case escapeIntermediate
            case csi
            case osc
            case oscEscape
            case controlString
            case controlStringEscape
        }

        /// A malformed, unterminated control string must not grow memory without
        /// bound. Normal CSI/OSC tokens are tiny; 64 KiB also leaves ample room
        /// for legitimate titles and hyperlinks.
        private static let maximumPendingTokenBytes = 64 * 1_024

        private var state = State.ground
        private var pendingToken = Data()
        private var isDiscardingOversizedToken = false
        private(set) var didExitAlternateScreen = false

        mutating func frame(_ data: Data) -> Data {
            didExitAlternateScreen = false
            guard !data.isEmpty else { return Data() }

            var framed = Data()
            framed.reserveCapacity(data.count + pendingToken.count)
            for byte in data {
                process(byte, into: &framed)
            }
            return framed
        }

        private mutating func process(_ byte: UInt8, into framed: inout Data) {
            var byteToProcess: UInt8? = byte

            // An invalid UTF-8 continuation completes the invalid leading byte
            // and must then be interpreted again as a possible token start.
            while let current = byteToProcess {
                byteToProcess = nil

                switch state {
                case .ground:
                    beginTokenIfNeeded(current, orAppendTo: &framed)

                case let .utf8(continuations):
                    guard current >= 0x80, current <= 0xBF else {
                        finishToken(into: &framed)
                        byteToProcess = current
                        continue
                    }
                    appendPending(current)
                    if continuations == 1 {
                        finishToken(into: &framed)
                    } else {
                        state = .utf8(continuations: continuations - 1)
                    }

                case .escape:
                    appendPending(current)
                    switch current {
                    case 0x5B: // [ — CSI
                        state = .csi
                    case 0x5D: // ] — OSC
                        state = .osc
                    case 0x50,
                         0x58,
                         0x5E,
                         0x5F,
                         0x6B: // DCS, SOS, PM, APC, tmux title
                        state = .controlString
                    case 0x20...0x2F:
                        state = .escapeIntermediate
                    case 0x30...0x7E,
                         0x18,
                         0x1A:
                        finishToken(into: &framed)
                    default:
                        // C0 controls execute without leaving escape state.
                        break
                    }

                case .escapeIntermediate:
                    appendPending(current)
                    switch current {
                    case 0x30...0x7E,
                         0x18,
                         0x1A:
                        finishToken(into: &framed)
                    case 0x1B:
                        state = .escape
                    default:
                        break
                    }

                case .csi:
                    appendPending(current)
                    switch current {
                    case 0x40...0x7E,
                         0x18,
                         0x1A:
                        finishToken(into: &framed)
                    case 0x1B:
                        state = .escape
                    default:
                        break
                    }

                case .osc:
                    appendPending(current)
                    switch current {
                    case 0x07,
                         0x9C,
                         0x18,
                         0x1A: // BEL, ST, CAN, SUB
                        finishToken(into: &framed)
                    case 0x1B:
                        state = .oscEscape
                    default:
                        break
                    }

                case .oscEscape:
                    appendPending(current)
                    if isStringTerminator(current) {
                        finishToken(into: &framed)
                    } else if current != 0x1B {
                        state = .osc
                    }

                case .controlString:
                    appendPending(current)
                    switch current {
                    case 0x9C,
                         0x18,
                         0x1A: // ST, CAN, SUB
                        finishToken(into: &framed)
                    case 0x1B:
                        state = .controlStringEscape
                    default:
                        break
                    }

                case .controlStringEscape:
                    appendPending(current)
                    if isStringTerminator(current) {
                        finishToken(into: &framed)
                    } else if current != 0x1B {
                        state = .controlString
                    }
                }
            }
        }

        private func isStringTerminator(_ byte: UInt8) -> Bool {
            byte == 0x5C || byte == 0x9C || byte == 0x18 || byte == 0x1A
        }

        private mutating func beginTokenIfNeeded(
            _ byte: UInt8,
            orAppendTo framed: inout Data
        ) {
            switch byte {
            case 0x1B:
                beginToken(byte, state: .escape)
            case 0x9B:
                beginToken(byte, state: .csi)
            case 0x9D:
                beginToken(byte, state: .osc)
            case 0x90,
                 0x98,
                 0x9E,
                 0x9F:
                beginToken(byte, state: .controlString)
            case 0xC2...0xDF:
                beginToken(byte, state: .utf8(continuations: 1))
            case 0xE0...0xEF:
                beginToken(byte, state: .utf8(continuations: 2))
            case 0xF0...0xF4:
                beginToken(byte, state: .utf8(continuations: 3))
            default:
                framed.append(byte)
            }
        }

        private mutating func beginToken(_ byte: UInt8, state: State) {
            pendingToken.append(byte)
            self.state = state
        }

        private mutating func appendPending(_ byte: UInt8) {
            if !isDiscardingOversizedToken {
                pendingToken.append(byte)
                if pendingToken.count > Self.maximumPendingTokenBytes {
                    pendingToken.removeAll(keepingCapacity: true)
                    isDiscardingOversizedToken = true
                }
            }
        }

        private mutating func finishToken(into framed: inout Data) {
            if !isDiscardingOversizedToken {
                if case .csi = state, pendingToken.last == 0x6C { // l — DECRST
                    let prefixLength = pendingToken.first == 0x9B ? 1 : 2
                    let parameters = pendingToken.dropFirst(prefixLength).dropLast()
                    if parameters.first == 0x3F { // ? — private modes
                        let modes = parameters.dropFirst().split(separator: 0x3B)
                        if modes.contains(where: { [47, 1_047, 1_049].contains(Int(String(decoding: $0, as: UTF8.self)) ?? 0) }) {
                            didExitAlternateScreen = true
                        }
                    }
                }
                framed.append(pendingToken)
            }
            pendingToken.removeAll(keepingCapacity: true)
            isDiscardingOversizedToken = false
            state = .ground
        }
    }

    /// Incrementally strips tmux's legacy title wrapper from terminal bytes.
    struct TmuxTitleSequenceFilter: Sendable {
        private var buffer = Data()

        var hasBufferedSequence: Bool {
            !buffer.isEmpty
        }

        mutating func reset() {
            buffer = Data()
        }

        mutating func filter(_ data: Data) -> Data {
            var result = Data()
            var dataToProcess = data
            if !buffer.isEmpty {
                dataToProcess = buffer + data
                buffer = Data()
            }

            var index = dataToProcess.startIndex
            while index < dataToProcess.endIndex {
                guard dataToProcess[index] == 0x1B else {
                    result.append(dataToProcess[index])
                    index = dataToProcess.index(after: index)
                    continue
                }

                guard index + 1 < dataToProcess.endIndex else {
                    buffer = Data(dataToProcess[index...])
                    break
                }

                guard dataToProcess[index + 1] == 0x6B else { // "k"
                    result.append(dataToProcess[index])
                    index = dataToProcess.index(after: index)
                    continue
                }

                var end = dataToProcess.index(index, offsetBy: 2)
                var foundTerminator = false
                while end < dataToProcess.endIndex {
                    if dataToProcess[end] == 0x1B {
                        guard end + 1 < dataToProcess.endIndex else {
                            buffer = Data(dataToProcess[index...])
                            return result
                        }
                        if dataToProcess[end + 1] == 0x5C { // "\\"
                            end = dataToProcess.index(end, offsetBy: 2)
                            foundTerminator = true
                            break
                        }
                    }
                    end = dataToProcess.index(after: end)
                }

                guard foundTerminator else {
                    buffer = Data(dataToProcess[index...])
                    break
                }
                index = end
            }

            return result
        }
    }

    /// Applies the same terminal-feed filtering to decoded control-mode output
    /// that the notification-only pipe reader applies to raw PTY bytes.
    struct TerminalOutputSanitizer: Sendable {
        private var titleFilter = TmuxTitleSequenceFilter()
        private var notificationParser = TerminalNotificationParser()

        mutating func sanitize(_ data: Data) -> Data {
            guard !data.isEmpty else { return Data() }
            if canUsePlainDataPath(data) {
                return data
            }

            let tmuxFiltered = titleFilter.filter(data)
            guard !tmuxFiltered.isEmpty else { return Data() }
            let daFiltered = TerminalResponseFilter.stripDAQueries(tmuxFiltered)
            guard !daFiltered.isEmpty else { return Data() }
            let dsrFiltered = TerminalResponseFilter.stripDSRQueries(daFiltered)
            guard !dsrFiltered.isEmpty else { return Data() }
            let decrqmFiltered = TerminalResponseFilter.stripDECRQMQueries(dsrFiltered)
            guard !decrqmFiltered.isEmpty else { return Data() }
            let kittyFiltered = TerminalResponseFilter.stripKittyKeyboardProtocol(decrqmFiltered)
            guard !kittyFiltered.isEmpty else { return Data() }
            let oscFiltered = TerminalResponseFilter.stripOSCColorQueries(kittyFiltered)
            guard !oscFiltered.isEmpty else { return Data() }
            return notificationParser.parse(oscFiltered).filteredData
        }

        private func canUsePlainDataPath(_ data: Data) -> Bool {
            !titleFilter.hasBufferedSequence
                && !notificationParser.hasBufferedSequence
                && !data.contains(0x1B)
                && !data.contains(0x9B)
                && !data.contains(0x9D)
        }
    }
#endif
