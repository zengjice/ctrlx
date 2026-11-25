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

        struct StopBoundary: Codable, Equatable, Sendable {
            let identity: FileIdentity
            let size: UInt64
            /// Older ledgers used the file size at hook processing time.
            var nativeRecord: Bool? = true

            init(identity: FileIdentity, size: UInt64) {
                self.identity = identity
                self.size = size
            }
        }

        struct SubmissionBoundary: Codable, Equatable, Sendable {
            let identity: FileIdentity
            let offset: UInt64
            let end: UInt64
            let timestamp: Date?
            var nextOffset: UInt64? = nil
            var nextEnd: UInt64? = nil

            func identifies(_ other: Self) -> Bool {
                identity == other.identity && offset == other.offset && end == other.end && timestamp == other.timestamp
            }
        }

        struct VerifiedSubmission: Sendable {
            let turn: PluginWorkflowTurn
            var afterStop: StopBoundary? = nil
            var submittedAt: Date? = nil
            var nativeStart: SubmissionBoundary? = nil
            fileprivate let revision: FileRevision

            var isCurrent: Bool {
                revision.isCurrent(at: turn.transcriptPath)
            }
        }

        struct VerifiedRecoveryEnd: Sendable {
            fileprivate let path: String
            fileprivate let revision: FileRevision
            fileprivate let completionOffset: UInt64?
            let hasPartialRecord: Bool

            var stopBoundary: StopBoundary? {
                completionOffset.map { .init(identity: revision.identity, size: $0) }
            }

            var isCurrent: Bool {
                revision.isCurrent(at: path)
            }

            func follows(_ previous: StopBoundary) -> Bool {
                revision.identity == previous.identity && completionOffset.map { $0 > previous.size } == true
            }

            func validate() throws {
                guard isCurrent else {
                    throw AgentWorkflowError("The native transcript changed while verifying its result. Try continuing again.")
                }
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
        private var readRevision: FileRevision
        private var initialParser: any AgentWorkflowTranscriptParser
        private var replayingActivity = true
        private var parser: any AgentWorkflowTranscriptParser
        private var pending = AgentWorkflowTranscriptRecord()
        private var offset: UInt64 = 0
        private var buffered = Data()
        private var pendingOutcome: AgentWorkflowTranscriptOutcome?
        private var lastOutcome: AgentWorkflowTranscriptOutcome?
        private var completionOffset: UInt64?
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
            self.readRevision = revision
            self.initialParser = parser
            self.parser = parser
            let rejectionMarker = submissionRejectionWindow == nil ? nil : parser.submissionRejectionMarker
            self.submissionRejectionWindow = rejectionMarker == nil ? nil : submissionRejectionWindow
            self.markers = (parser.startMarkers + [rejectionMarker].compactMap { $0 }).filter { !$0.isEmpty }.map { Data($0.utf8) }
            self.locating = !markers.isEmpty
            self.readingStart = locating && parser.readsSessionHeader
        }

        func updateCandidate(_ candidate: String) {
            let candidateOutcome = parser.updateCandidate(candidate)
            let recorded = parser.tracksCompletionAtEnd ? parser.recoveredCompletion : lastOutcome
            if case .failed? = recorded {
                pendingOutcome = recorded
            } else {
                pendingOutcome = candidateOutcome
            }
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

        func hasCurrentReadRevision(at path: String) -> Bool {
            readRevision.isCurrent(at: path)
        }

        /// Finish parsing the same file version that supplied the earlier bytes.
        func verifiedOutcome(at path: String, hasStop: Bool = false) async throws -> (AgentWorkflowTranscriptOutcome?, VerifiedRecoveryEnd)? {
            let revision = readRevision
            guard offset <= revision.size, revision.isCurrent(at: path) else { return nil }
            while true {
                let result = try poll(through: revision.size)
                if result.reachedEnd {
                    break
                }
                await Task.yield()
            }
            guard offset == revision.size, revision.isCurrent(at: path) else { return nil }
            let hasPartialRecord = !pending.retained.isEmpty || readingStart
            var outcome: AgentWorkflowTranscriptOutcome?
            if !hasPartialRecord {
                outcome = parser.recoveredCompletion
                if outcome == nil, !parser.tracksCompletionAtEnd {
                    if hasStop {
                        outcome = lastOutcome
                    } else if case .failed? = lastOutcome {
                        outcome = lastOutcome
                    }
                }
            }
            return (outcome, .init(path: path, revision: revision, completionOffset: completionOffset, hasPartialRecord: hasPartialRecord))
        }

        nonisolated func stillAtPath(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0 && openedFile.identity == FileIdentity(device: info.st_dev, inode: info.st_ino)
        }

        func verifyResumedSubmission(
            _ turn: PluginWorkflowTurn, after boundary: StopBoundary?, matching stop: PluginWorkflowEvent?, resumedStop: PluginWorkflowEvent? = nil
        ) async throws -> VerifiedSubmission? {
            let revision = try FileRevision(fileInfo())
            let prior = boundary.flatMap { $0.nativeRecord == true ? $0 : nil }
            if let prior, prior.identity != revision.identity || prior.size >= revision.size {
                return nil
            }
            var recordEnd: UInt64 = 0
            var stopEnd = prior?.size
            var latestSubmission: String?
            var stopBeforeSubmission: UInt64?
            var completedSubmission = false
            while true {
                let result = try poll(through: revision.size, turnMetadataOnly: false) { line in
                    let lineStart = recordEnd
                    recordEnd = offset - UInt64(buffered.count)
                    if let outcome = try consumeOutcome(line).completion, recordEnd > (prior?.size ?? 0) {
                        if stopBeforeSubmission != nil, let resumedStop {
                            completedSubmission = resumedStop.kind == .failed
                            if case let .succeeded(answer) = outcome, resumedStop.corroboratesAnswer(answer) {
                                completedSubmission = true
                            }
                        }
                        // Any later ending closes the submissions seen so far.
                        latestSubmission = nil
                        if stopEnd != nil {
                            stopEnd = recordEnd
                        } else if case let .succeeded(answer) = outcome, stop?.corroboratesAnswer(answer) != false {
                            stopEnd = recordEnd
                        }
                    }
                    if let stopEnd, lineStart >= stopEnd, let id = try parser.resumedTurnID(in: line) {
                        latestSubmission = id
                        stopBeforeSubmission = id == turn.nativeTurnID ? stopEnd : nil
                        completedSubmission = false
                    }
                    return nil
                }
                if result.reachedEnd {
                    break
                }
                await Task.yield()
            }
            guard
                let stopEnd = stopBeforeSubmission, latestSubmission == turn.nativeTurnID || completedSubmission,
                offset == revision.size, pending.retained.isEmpty, !readingStart,
                revision.isCurrent(at: turn.transcriptPath) else { return nil }
            return VerifiedSubmission(turn: turn, afterStop: .init(identity: revision.identity, size: stopEnd), revision: revision)
        }

        /// Use a fresh reader to locate the accepted turn and check submissions
        /// through the end of a stable transcript snapshot.
        func verifyCurrentSubmission(_ turn: PluginWorkflowTurn, hookStartedAt: Date? = nil) async throws -> VerifiedSubmission? {
            guard
                let scan = try await scanSubmissions(from: turn, hookStartedAt: hookStartedAt),
                scan.latestTurnID == turn.nativeTurnID, let selected = scan.nativeStart, let latest = scan.latestStart,
                selected.identifies(latest), pending.retained.isEmpty else { return nil }
            return VerifiedSubmission(turn: turn, submittedAt: scan.submittedAt, nativeStart: scan.nativeStart, revision: scan.revision)
        }

        func verifySubmittedTurn(
            _ turn: PluginWorkflowTurn, firstOccurrence: Bool = false, hookStartedAt: Date? = nil, nativeStart: SubmissionBoundary? = nil
        ) async throws -> VerifiedSubmission? {
            guard
                let scan = try await scanSubmissions(from: turn, hookStartedAt: hookStartedAt, nativeStart: nativeStart),
                scan.foundTurn, let selected = firstOccurrence ? scan.firstStart : scan.nativeStart,
                pending.retained.isEmpty else { return nil }
            return VerifiedSubmission(
                turn: turn, submittedAt: firstOccurrence ? scan.firstSubmittedAt : scan.submittedAt, nativeStart: selected, revision: scan.revision
            )
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

        func submissionFollows(_ turn: PluginWorkflowTurn, after anchor: PluginWorkflowTurn) async throws -> Bool? {
            guard anchor.transcriptPath == turn.transcriptPath else { return nil }
            let revision = try FileRevision(fileInfo())
            locating = false
            readingStart = false
            pending = .init(turnMetadataOnly: true)
            var foundAnchor = false
            var follows: Bool?
            while true {
                let result = try poll(through: revision.size, turnMetadataOnly: true) { line in
                    if let id = try parser.submittedTurnID(in: line) {
                        if id == anchor.nativeTurnID {
                            foundAnchor = true
                        }
                        if id == turn.nativeTurnID {
                            follows = foundAnchor
                        }
                    }
                    return nil
                }
                if result.reachedEnd {
                    break
                }
                await Task.yield()
            }
            guard offset == revision.size, pending.retained.isEmpty, revision.isCurrent(at: turn.transcriptPath) else { return nil }
            return follows
        }

        private func scanSubmissions(
            from turn: PluginWorkflowTurn, hookStartedAt: Date? = nil, nativeStart: SubmissionBoundary? = nil
        ) async throws -> (
            foundTurn: Bool, rejected: Bool, latestTurnID: String?, submittedAt: Date?, firstSubmittedAt: Date?,
            nativeStart: SubmissionBoundary?, firstStart: SubmissionBoundary?, latestStart: SubmissionBoundary?, revision: FileRevision
        )? {
            let revision = try FileRevision(fileInfo())
            pending = .init(turnMetadataOnly: true, retainSubmissionRejections: submissionRejectionWindow != nil)
            var foundTurn = false
            var rejected = false
            var latestTurnID: String?
            var firstStart: SubmissionBoundary?
            var latestStart: SubmissionBoundary?
            var selectedStart: SubmissionBoundary?
            var count = 0
            var actualCount = 0
            var previousEnd: UInt64 = 0
            while true {
                let result = try poll(through: revision.size, turnMetadataOnly: true) { line in
                    let start = max(previousEnd, recordStart)
                    let end = offset - UInt64(buffered.count)
                    previousEnd = end
                    let resumed = try parser.resumedTurnID(in: line)
                    if resumed != nil {
                        if let value = firstStart, value.nextOffset == nil, value.offset < start {
                            firstStart?.nextOffset = start
                            firstStart?.nextEnd = end
                        }
                        if let value = latestStart, value.nextOffset == nil, value.offset < start {
                            latestStart?.nextOffset = start
                            latestStart?.nextEnd = end
                        }
                        if let value = selectedStart, value.nextOffset == nil, value.offset < start {
                            selectedStart?.nextOffset = start
                            selectedStart?.nextEnd = end
                        }
                    }
                    if let submitted = try resumed ?? parser.submittedTurnID(in: line) {
                        if submitted == turn.nativeTurnID {
                            let record = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                            let timestamp = AgentTurnActivity.parseTimestamp(record?["timestamp"] as? String)
                            let position = SubmissionBoundary(identity: revision.identity, offset: start, end: end, timestamp: timestamp)
                            if resumed != nil || !foundTurn {
                                if resumed != nil {
                                    if actualCount == 0 {
                                        count = 0
                                        selectedStart = nil
                                    }
                                    actualCount += 1
                                }
                                if count == 0 {
                                    firstStart = position
                                }
                                latestStart = position
                                count += 1
                                if let nativeStart {
                                    if nativeStart.identifies(position) {
                                        selectedStart = position
                                    }
                                } else if let hookStartedAt {
                                    if let timestamp, timestamp <= hookStartedAt {
                                        selectedStart = position
                                    }
                                } else {
                                    selectedStart = position
                                }
                            }
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
            if nativeStart == nil, count == 1 {
                selectedStart = latestStart
            }
            return (foundTurn, rejected, latestTurnID, selectedStart?.timestamp, firstStart?.timestamp, selectedStart, firstStart, latestStart, revision)
        }

        /// Read the verified submission and the next input's envelope, which
        /// some native parsers need to recognize an interrupted turn.
        func verifiedOutcome(
            for proof: VerifiedSubmission, hasStop: Bool
        ) async throws -> (AgentWorkflowTranscriptOutcome?, VerifiedRecoveryEnd)? {
            let revision = readRevision
            guard
                let start = proof.nativeStart, proof.revision == revision,
                start.identity == revision.identity, revision.isCurrent(at: proof.turn.transcriptPath) else { return nil }
            let end = start.nextOffset ?? revision.size
            let boundaryEnd = start.nextEnd ?? end
            guard start.offset < start.end, start.end <= end, end <= boundaryEnd, boundaryEnd <= revision.size else { return nil }
            locating = false
            readingStart = false
            if parser.readsSessionHeader {
                pending = .init(turnMetadataOnly: true)
                _ = try poll(through: start.offset, turnMetadataOnly: true) { line in
                    _ = try parser.consume(line)
                    return .succeeded("")
                }
            }
            offset = start.offset
            buffered = Data()
            pending = .init()
            lastOutcome = nil
            completionOffset = nil
            var found = false
            var first = true
            while true {
                let result = try poll(through: end, turnMetadataOnly: false) { line in
                    if first {
                        first = false
                        found = try parser.submittedTurnID(in: line) == proof.turn.nativeTurnID
                        if let timestamp = start.timestamp {
                            let record = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                            found = found && AgentTurnActivity.parseTimestamp(record?["timestamp"] as? String) == timestamp
                        }
                    }
                    if found {
                        let consumed = try consumeOutcome(line)
                        if let value = consumed.announced {
                            lastOutcome = value
                        }
                        if consumed.completion != nil {
                            completionOffset = offset - UInt64(buffered.count)
                        }
                    }
                    return nil
                }
                if result.reachedEnd {
                    break
                }
                await Task.yield()
            }
            if found, boundaryEnd > end {
                pending = .init(turnMetadataOnly: true)
                while true {
                    let result = try poll(through: boundaryEnd, turnMetadataOnly: true) { line in
                        // Reusing the ID begins a different submission; it must
                        // not reset this segment's native failure or success.
                        guard try parser.submittedTurnID(in: line) != proof.turn.nativeTurnID else { return nil }
                        let consumed = try consumeOutcome(line)
                        if let value = consumed.announced {
                            lastOutcome = value
                        }
                        if consumed.completion != nil {
                            completionOffset = offset - UInt64(buffered.count)
                        }
                        return nil
                    }
                    if result.reachedEnd {
                        break
                    }
                    await Task.yield()
                }
            }
            guard found, offset == boundaryEnd, revision.isCurrent(at: proof.turn.transcriptPath) else { return nil }
            let partial = !pending.retained.isEmpty
            var outcome = parser.tracksCompletionAtEnd ? parser.recoveredCompletion : lastOutcome
            if partial {
                outcome = nil
            } else if !hasStop, !parser.tracksCompletionAtEnd, case .succeeded? = outcome {
                outcome = nil
            }
            return (outcome, .init(path: proof.turn.transcriptPath, revision: revision, completionOffset: completionOffset, hasPartialRecord: partial))
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
            if end == nil, bytesRead == 0 {
                readRevision = try FileRevision(fileInfo())
            }
            return try poll(through: end, turnMetadataOnly: false) { line in
                let outcome = try consumeOutcome(line)
                if outcome.completion != nil {
                    completionOffset = offset - UInt64(buffered.count)
                }
                return outcome.announced
            }
        }

        private func consumeOutcome(_ line: Data) throws -> (announced: AgentWorkflowTranscriptOutcome?, completion: AgentWorkflowTranscriptOutcome?) {
            let previous = parser.recoveredCompletion
            if let outcome = try parser.consume(line) {
                return (outcome, outcome)
            }
            let latest = parser.recoveredCompletion
            return (nil, latest == previous ? nil : latest)
        }

        private func poll(
            through end: UInt64?, turnMetadataOnly: Bool,
            consume: (Data) throws -> AgentWorkflowTranscriptOutcome?
        ) throws -> Poll {
            _ = try fileInfo()
            if let outcome = pendingOutcome {
                pendingOutcome = nil
                lastOutcome = outcome
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
                        lastOutcome = outcome
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
