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

        struct ActivityDrain: Sendable {
            fileprivate(set) var entries: [AgentTurnActivity]
            fileprivate(set) var evictedActivityIDs: Set<String> = []
            let isComplete: Bool
            let hasPartialRecord: Bool
            fileprivate var checkedEvictionIDs: Set<String> = []
            fileprivate let revision: FileRevision

            var fileIdentity: FileIdentity {
                revision.identity
            }
        }

        struct FileIdentity: Codable, Equatable, Sendable {
            let device: dev_t
            let inode: ino_t
        }

        struct VerifiedSubmission: Sendable {
            let turn: PluginWorkflowTurn
            fileprivate let revision: FileRevision

            var isCurrent: Bool {
                revision.isCurrent(at: turn.transcriptPath)
            }
        }

        fileprivate struct FileRevision: Equatable, Sendable {
            let identity: FileIdentity
            let size: UInt64
            let modifiedSeconds: Int
            let modifiedNanoseconds: Int
            let changedSeconds: Int
            let changedNanoseconds: Int

            init(_ info: stat) {
                self.identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
                self.size = UInt64(info.st_size)
                self.modifiedSeconds = info.st_mtimespec.tv_sec
                self.modifiedNanoseconds = info.st_mtimespec.tv_nsec
                self.changedSeconds = info.st_ctimespec.tv_sec
                self.changedNanoseconds = info.st_ctimespec.tv_nsec
            }

            func referencesSameFile(as other: Self) -> Bool {
                identity == other.identity
            }

            func isCurrent(at path: String) -> Bool {
                var info = stat()
                return lstat(path, &info) == 0 && info.st_size >= 0 && Self(info) == self
            }
        }

        private let handle: FileHandle
        private nonisolated let openedFile: FileRevision
        private var initialParser: any AgentWorkflowTranscriptParser
        private var replayingActivity = true
        private var parser: any AgentWorkflowTranscriptParser
        private var pending = AgentWorkflowTranscriptRecord()
        private var offset: UInt64 = 0
        private var buffered = Data()
        private var pendingOutcome: AgentWorkflowTranscriptOutcome?
        private var failure: AgentWorkflowTranscriptOutcome?
        private var locating: Bool
        private var readingStart = false
        private let markers: [Data]
        private let submissionRejectionWindow: Range<Date>?
        private var recordStart: UInt64 = 0
        private var markerTail = Data()
        /// Actual I/O, including seeks and rereads, for bounded-reader diagnostics.
        private(set) var bytesRead: UInt64 = 0

        init(path: String, parser: any AgentWorkflowTranscriptParser, submissionRejectionWindow: Range<Date>? = nil) throws {
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else {
                if errno == ENOENT {
                    throw CocoaError(.fileNoSuchFile)
                }
                throw AgentWorkflowError("The native transcript could not be opened.")
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_size >= 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
                close(fd)
                throw AgentWorkflowError("The native transcript must be a regular file owned by this user.")
            }
            self.init(
                handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true), revision: FileRevision(info),
                parser: parser, submissionRejectionWindow: submissionRejectionWindow
            )
        }

        private init(handle: FileHandle, revision: FileRevision, parser: any AgentWorkflowTranscriptParser, submissionRejectionWindow: Range<Date>? = nil) {
            self.handle = handle
            self.openedFile = revision
            self.initialParser = parser
            self.parser = parser
            let rejectionMarker = submissionRejectionWindow == nil ? nil : parser.submissionRejectionMarker
            self.submissionRejectionWindow = rejectionMarker == nil ? nil : submissionRejectionWindow
            self.markers = (parser.startMarkers + [rejectionMarker].compactMap { $0 }).filter { !$0.isEmpty }.map { Data($0.utf8) }
            self.locating = !markers.isEmpty
            self.readingStart = locating && parser.readsSessionHeader
        }

        func updateCandidate(_ candidate: String) {
            pendingOutcome = failure ?? parser.updateCandidate(candidate)
        }

        var activityWindow: (entries: [AgentTurnActivity], evicted: Set<String>) {
            (parser.activity, parser.evictedActivityIDs)
        }

        func trackSavedActivityEvictions(_ activity: [AgentTurnActivity]) {
            parser.trackActivityEvictions(for: Set(activity.suffix(AgentTurnActivityLog.maximumEntries).map(\.id)))
        }

        nonisolated var fileIdentity: FileIdentity {
            openedFile.identity
        }

        nonisolated func referencesSameFile(as other: AgentWorkflowTranscriptFile) -> Bool {
            openedFile.referencesSameFile(as: other.openedFile)
        }

        nonisolated func referencesSameFile(as drain: ActivityDrain) -> Bool {
            openedFile.referencesSameFile(as: drain.revision)
        }

        func alignActivity(with saved: [AgentTurnActivity]) {
            initialParser.captureActivity(aligningWith: saved)
            parser.captureActivity(aligningWith: saved)
        }

        func pollRecovery() throws -> Poll {
            let result = try poll()
            guard result.reachedEnd, pending.retained.isEmpty else { return result }
            return .init(outcome: result.outcome ?? parser.recoveredCompletion, reachedEnd: true)
        }

        /// Use a fresh reader to locate the accepted turn and check submissions
        /// through the end of a stable transcript snapshot.
        func verifyCurrentSubmission(_ turn: PluginWorkflowTurn) async throws -> VerifiedSubmission? {
            guard
                let scan = try await scanSubmissions(from: turn),
                scan.latestTurnID == turn.nativeTurnID, pending.retained.isEmpty else { return nil }
            return VerifiedSubmission(turn: turn, revision: scan.revision)
        }

        /// A changing transcript cannot establish submission order.
        func hasNewerSubmission(than turn: PluginWorkflowTurn, requiringReceipt: Bool = false) async throws -> Bool? {
            guard
                let scan = try await scanSubmissions(from: turn),
                !requiringReceipt || ((scan.foundTurn || scan.rejected) && pending.retained.isEmpty) else { return nil }
            if !scan.foundTurn, scan.rejected {
                return true
            }
            return scan.foundTurn && scan.latestTurnID != turn.nativeTurnID
        }

        private func scanSubmissions(from turn: PluginWorkflowTurn) async throws -> (foundTurn: Bool, rejected: Bool, latestTurnID: String?, revision: FileRevision)? {
            let revision = try FileRevision(fileInfo())
            pending = .init(turnMetadataOnly: true, retainSubmissionRejections: submissionRejectionWindow != nil)
            var foundTurn = false
            var rejected = false
            var latestTurnID: String?
            while true {
                let result = try poll(through: revision.size, turnMetadataOnly: true) { line in
                    if let submitted = try parser.submittedTurnID(in: line) {
                        if submitted == turn.nativeTurnID {
                            foundTurn = true
                        }
                        latestTurnID = submitted
                    } else if let submissionRejectionWindow, !foundTurn, !rejected {
                        rejected = try parser.rejectsSubmission(line, during: submissionRejectionWindow)
                    }
                    return nil
                }
                if result.reachedEnd {
                    break
                }
                await Task.yield()
            }
            guard
                offset == revision.size, try FileRevision(fileInfo()) == revision,
                revision.isCurrent(at: turn.transcriptPath) else { return nil }
            return (foundTurn, rejected, latestTurnID, revision)
        }

        func drainActivity(reusing previous: ActivityDrain? = nil, checking candidates: Set<String> = []) async throws -> ActivityDrain {
            let revision = try FileRevision(fileInfo())
            if let previous, previous.revision == revision {
                return try await checkEvictions(in: previous, for: candidates)
            }
            let result = try await drain(through: revision.size)
            let hasPartialRecord = result.outcome == nil && !locating && !pending.retained.isEmpty
            let isComplete = result.outcome != nil || (!locating && !hasPartialRecord)
            let saved = previous?.entries ?? []
            let (observed, observedEvictions) = activityWindow
            let evicted = observedEvictions.union(previous?.evictedActivityIDs ?? []).subtracting(observed.map(\.id))
            let activityDrain = ActivityDrain(
                entries: observed, evictedActivityIDs: evicted,
                isComplete: isComplete, hasPartialRecord: hasPartialRecord, revision: revision
            )
            var checked = try await checkEvictions(in: activityDrain, for: candidates.union(saved.map(\.id)))
            checked.entries = AgentTurnActivity.merging(observed, into: saved.filter { !checked.evictedActivityIDs.contains($0.id) })
            return checked
        }

        func checkEvictions(in drain: ActivityDrain, for candidates: Set<String>) async throws -> ActivityDrain {
            let missing = candidates.subtracting(drain.entries.map(\.id)).subtracting(drain.evictedActivityIDs).subtracting(drain.checkedEvictionIDs)
            guard drain.entries.count >= AgentTurnActivityLog.maximumEntries, !missing.isEmpty else { return drain }
            // Reuse the verified descriptor even if the path now names a replacement.
            var parser = initialParser
            parser.trackActivityEvictions(for: missing)
            let replay = AgentWorkflowTranscriptFile(handle: handle, revision: drain.revision, parser: parser)
            _ = try await replay.drain(through: drain.revision.size)
            var checked = drain
            checked.evictedActivityIDs.formUnion(await replay.parser.evictedActivityIDs)
            checked.checkedEvictionIDs.formUnion(missing)
            return checked
        }

        private func drain(through end: UInt64) async throws -> Poll {
            updateCandidate("")
            while true {
                let result = try poll(through: end)
                if result.outcome != nil || result.reachedEnd {
                    return result
                }
                await Task.yield()
            }
        }

        func poll(through end: UInt64? = nil) throws -> Poll {
            try poll(through: end, turnMetadataOnly: false) { try parser.consume($0) }
        }

        private func poll(
            through end: UInt64?, turnMetadataOnly: Bool,
            consume: (Data) throws -> AgentWorkflowTranscriptOutcome?
        ) throws -> Poll {
            _ = try fileInfo()
            if let outcome = pendingOutcome {
                pendingOutcome = nil
                return .init(outcome: outcome, reachedEnd: false)
            }
            // Yield after 1 MiB so a large transcript cannot monopolize a task.
            for _ in 0..<16 {
                try Task.checkCancellation()
                if buffered.isEmpty {
                    guard let bytes = try readChunk(through: end), !bytes.isEmpty else {
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
                    pending = AgentWorkflowTranscriptRecord(
                        turnMetadataOnly: turnMetadataOnly, retainSubmissionRejections: submissionRejectionWindow != nil
                    )
                    buffered = Data(buffered[buffered.index(after: newline)...])
                    if readingStart {
                        readingStart = false
                        locating = try !parser.isTurnStart(value)
                        if locating {
                            if recordStart == 0, parser.readsSessionHeader {
                                _ = try consume(value)
                            }
                            recordStart = offset - UInt64(buffered.count)
                            break
                        }
                        // Reuse the complete, image-stripped start record;
                        // do not seek back and parse its payload a second time.
                    }
                    guard !value.isEmpty else { continue }
                    if replayingActivity, offset - UInt64(buffered.count) > openedFile.size {
                        replayingActivity = false
                        parser.beginAppendingActivity()
                    }
                    let outcome = try consume(value)
                    if let outcome {
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

        private func fileInfo() throws -> stat {
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0, info.st_size >= 0, UInt64(info.st_size) >= offset else {
                throw AgentWorkflowError("The native transcript was truncated while verifying a turn.")
            }
            return info
        }

        private func readChunk(through end: UInt64?) throws -> Data? {
            let size: UInt64 = 64 * 1_024
            let available = end.map { min(size, $0 - offset) } ?? size
            guard available > 0 else { return nil }
            // Activity replay and the live reader have independent cursors.
            var bytes = Data(count: Int(available))
            let count = bytes.withUnsafeMutableBytes { buffer in
                pread(handle.fileDescriptor, buffer.baseAddress, buffer.count, off_t(offset))
            }
            guard count >= 0 else { throw AgentWorkflowError("The native transcript could not be read.") }
            bytes.count = count
            bytesRead += UInt64(count)
            return bytes
        }
    }
#endif
