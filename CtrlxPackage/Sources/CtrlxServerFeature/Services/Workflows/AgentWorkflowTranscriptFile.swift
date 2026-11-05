#if os(macOS)
    import CtrlxNetworking
    import CtrlxPluginProtocol
    import Darwin
    import Foundation

    /// Holds one native transcript descriptor and an incremental parser. Memory
    /// and work per poll are bounded even for an existing long-running session.
    actor AgentWorkflowTranscriptFile {
        struct Poll: Sendable {
            let outcome: AgentWorkflowTranscriptOutcome?
            let reachedEnd: Bool
        }

        private let handle: FileHandle
        private var parser: any AgentWorkflowTranscriptParser
        private var pending = AgentWorkflowTranscriptRecord()
        private var offset: UInt64 = 0
        private var buffered = Data()
        private var pendingOutcome: AgentWorkflowTranscriptOutcome?
        private var failure: AgentWorkflowTranscriptOutcome?
        private var locating: Bool
        private var readingStart = false
        private let markers: [Data]
        private var recordStart: UInt64 = 0
        private var markerTail = Data()
        /// Actual I/O, including seeks and rereads, for bounded-reader diagnostics.
        private(set) var bytesRead: UInt64 = 0

        init(path: String, parser: any AgentWorkflowTranscriptParser) throws {
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else {
                if errno == ENOENT {
                    throw CocoaError(.fileNoSuchFile)
                }
                throw AgentWorkflowError("The native transcript could not be opened.")
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
                close(fd)
                throw AgentWorkflowError("The native transcript must be a regular file owned by this user.")
            }
            self.handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            self.parser = parser
            self.markers = parser.startMarkers.filter { !$0.isEmpty }.map { Data($0.utf8) }
            self.locating = !markers.isEmpty
            self.readingStart = locating && parser.readsSessionHeader
        }

        func updateCandidate(_ candidate: String) {
            pendingOutcome = failure ?? parser.updateCandidate(candidate)
        }

        func poll() throws -> Poll {
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0, info.st_size >= 0, UInt64(info.st_size) >= offset else {
                throw AgentWorkflowError("The native transcript was truncated while verifying a turn.")
            }
            if let outcome = pendingOutcome {
                pendingOutcome = nil
                return .init(outcome: outcome, reachedEnd: false)
            }
            // Yield after 1 MiB so a large transcript cannot monopolize a task.
            for _ in 0..<16 {
                try Task.checkCancellation()
                if buffered.isEmpty {
                    guard let bytes = try readChunk(), !bytes.isEmpty else {
                        // The prompt or its newline may not exist yet. Keep the
                        // locator's partial-record position until it is complete.
                        return .init(outcome: nil, reachedEnd: true)
                    }
                    offset += UInt64(bytes.count)
                    buffered = bytes
                }
                if locating, !readingStart {
                    try locateTurn()
                    continue
                }
                while let newline = buffered.firstIndex(of: 10) {
                    try pending.append(buffered[..<newline])
                    let value = try pending.finish()
                    pending = AgentWorkflowTranscriptRecord()
                    buffered = Data(buffered[buffered.index(after: newline)...])
                    if readingStart {
                        readingStart = false
                        locating = try !parser.isTurnStart(value)
                        if locating {
                            if recordStart == 0, parser.readsSessionHeader {
                                _ = try parser.consume(value)
                            }
                            recordStart = offset - UInt64(buffered.count)
                            break
                        }
                        // Reuse the complete, image-stripped start record;
                        // do not seek back and parse its payload a second time.
                    }
                    if !value.isEmpty, let outcome = try parser.consume(value) {
                        if case .failed = outcome {
                            failure = outcome
                        }
                        // Preserve bytes after this record when Stop follows a
                        // submission watch which has already seen completion.
                        return .init(outcome: outcome, reachedEnd: false)
                    }
                }
                if locating, !readingStart {
                    continue
                }
                try pending.append(buffered[...])
                buffered = Data()
            }
            return .init(outcome: nil, reachedEnd: false)
        }

        /// Old tool output and images are scanned as bytes, not decoded. Only
        /// the session header and records containing this task's IDs are parsed.
        private func locateTurn() throws {
            let start = offset - UInt64(buffered.count)
            var remaining = buffered[...]
            while !remaining.isEmpty {
                let newline = remaining.firstIndex(of: 10)
                let part = remaining[..<(newline ?? remaining.endIndex)]
                let search = markerTail + part
                if markers.contains(where: { search.range(of: $0) != nil }) {
                    readingStart = true
                    markerTail = Data()
                    if recordStart >= start {
                        buffered = Data(buffered.dropFirst(Int(recordStart - start)))
                    } else {
                        // A late ID requires revisiting the skipped prefix.
                        // The ordinary poll loop accounts for every read and
                        // retains its partial record across budget boundaries.
                        try handle.seek(toOffset: recordStart)
                        offset = recordStart
                        buffered = Data()
                    }
                    return
                }
                markerTail = Data(search.suffix(max(0, (markers.map(\.count).max() ?? 1) - 1)))
                guard let newline else { break }
                recordStart = start + UInt64(newline - buffered.startIndex) + 1
                markerTail = Data()
                remaining = remaining[remaining.index(after: newline)...]
            }
            buffered = Data()
        }

        private func readChunk() throws -> Data? {
            let bytes = try handle.read(upToCount: 64 * 1_024)
            bytesRead += UInt64(bytes?.count ?? 0)
            return bytes
        }
    }
#endif
