#if os(macOS)
    import CryptoKit
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

        struct FileIdentity: Codable, Hashable, Sendable {
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

        struct SubmissionBoundary: Codable, Hashable, Sendable {
            let identity: FileIdentity
            let offset: UInt64
            let end: UInt64
            let timestamp: Date?
            var nextOffset: UInt64? = nil
            var nextEnd: UInt64? = nil
            var inputOffset: UInt64? = nil
            var inputEnd: UInt64? = nil

            func identifies(_ other: Self) -> Bool {
                identity == other.identity && offset == other.offset && end == other.end && timestamp == other.timestamp
            }
        }

        struct SubmissionAnchor: Hashable, Sendable {
            let turnID: String
            let boundary: SubmissionBoundary
            var hookStartedAt: Date? = nil

            func canLocate(_ turn: PluginWorkflowTurn, hookStartedAt: Date?, nativeStart: SubmissionBoundary?) -> Bool {
                if let nativeStart {
                    return nativeStart.identity == boundary.identity && nativeStart.offset >= boundary.offset
                }
                if let hookStartedAt, let earliest = self.hookStartedAt {
                    return hookStartedAt >= earliest
                }
                return hookStartedAt == nil && turn.nativeTurnID == turnID
            }
        }

        private struct SubmissionQuery: Equatable {
            let turn: PluginWorkflowTurn
            let hookStartedAt: Date?
            let nativeStart: SubmissionBoundary?
            let input: String?
        }

        private struct SubmissionScan: Sendable {
            var foundTurn = false
            var rejected = false
            var latestTurnID: String?
            var firstStart: SubmissionBoundary?
            var latestStart: SubmissionBoundary?
            var nativeStart: SubmissionBoundary?
            var occurrences = 0
            var actualCount = 0
            var previousEnd: UInt64 = 0
            var revision: FileRevision
            var inputBoundary: SubmissionBoundary?
            var isRejection = false

            var submittedAt: Date? {
                nativeStart?.timestamp
            }

            var firstSubmittedAt: Date? {
                firstStart?.timestamp
            }
        }

        private struct Fingerprint {
            let start: UInt64
            let end: UInt64
            let digest: Data
        }

        private struct CachedSubmissionScan {
            let query: SubmissionQuery
            var scan: SubmissionScan
            let parser: any AgentWorkflowTranscriptParser
            let pending: AgentWorkflowTranscriptRecord
            let locating: Bool
            let readingStart: Bool
            let recordStart: UInt64
            let markerTail: Data
            let hasher: SHA256
            let hashStart: UInt64
            let hashEnd: UInt64
            let header: Fingerprint?
            let unverifiedAnchor: SubmissionAnchor?
        }

        struct VerifiedSubmission: Sendable {
            let turn: PluginWorkflowTurn
            var afterStop: StopBoundary? = nil
            var submittedAt: Date? = nil
            var nativeStart: SubmissionBoundary? = nil
            var matchedInput: String? = nil
            var isRejection = false
            fileprivate let revision: FileRevision

            var isCurrent: Bool {
                revision.isCurrent(at: turn.transcriptPath)
            }

            func hasSameRevision(as other: Self) -> Bool {
                revision == other.revision
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
        private var fixedReadRevision = false
        private var initialParser: any AgentWorkflowTranscriptParser
        private var replayingActivity = true
        private var parser: any AgentWorkflowTranscriptParser
        private var pending = AgentWorkflowTranscriptRecord()
        private var offset: UInt64 = 0
        private var buffered = Data()
        private var pendingOutcome: AgentWorkflowTranscriptOutcome?
        private var lastOutcome: AgentWorkflowTranscriptOutcome?
        private var completionOffset: UInt64?
        private var rejectedSubmission: VerifiedSubmission?
        private var locating: Bool
        private var readingStart = false
        private let markers: [Data]
        private let submissionRejectionWindow: Range<Date>?
        private var recordStart: UInt64 = 0
        private var markerTail = Data()
        /// Actual I/O, including seeks and rereads, for bounded-reader diagnostics.
        private(set) var bytesRead: UInt64 = 0
        private(set) var submissionBytesRead: UInt64 = 0
        private var submissionAnchor: SubmissionAnchor?
        private var cachedSubmissionScan: CachedSubmissionScan?
        private var scanningSubmissions = false
        private var submissionWaiters: [CheckedContinuation<Void, Never>] = []
        private var submissionHasher: SHA256?
        private var submissionHashStart: UInt64 = 0
        private var submissionHashEnd: UInt64 = 0

        init(path: String, parser: any AgentWorkflowTranscriptParser, submissionRejectionWindow: Range<Date>? = nil, submissionAnchor: SubmissionAnchor? = nil) throws {
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
                parser: parser, submissionRejectionWindow: submissionRejectionWindow, submissionAnchor: submissionAnchor
            )
        }

        private init(handle: FileHandle, revision: FileRevision, parser: any AgentWorkflowTranscriptParser, submissionRejectionWindow: Range<Date>? = nil, submissionAnchor: SubmissionAnchor? = nil) {
            self.handle = handle
            self.submissionAnchor = submissionAnchor
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

        /// Seek only after the submission was correlated with this file version.
        func start(at proof: VerifiedSubmission) async throws -> Bool {
            guard let start = proof.nativeStart, proof.isCurrent, proof.revision == readRevision else { return false }
            fixedReadRevision = true
            locating = false
            readingStart = false
            if parser.readsSessionHeader, start.offset > 0 {
                try await readSessionHeader(through: start.offset)
            }
            offset = start.offset
            buffered = Data()
            pending = .init()
            lastOutcome = nil
            pendingOutcome = nil
            completionOffset = nil
            rejectedSubmission = proof.isRejection ? proof : nil
            return proof.isCurrent
        }

        /// Finish parsing the same file version that supplied the earlier bytes.
        func verifiedOutcome(at path: String, hasStop: Bool = false) async throws -> (AgentWorkflowTranscriptOutcome?, VerifiedRecoveryEnd)? {
            if let rejectedSubmission {
                parser = initialParser
                offset = 0
                buffered = Data()
                pending = .init()
                pendingOutcome = nil
                return try await verifiedOutcome(for: rejectedSubmission, hasStop: hasStop)
            }
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

        /// Locate the original delivery, not a later replay of the same task text.
        func findSubmission(prompt: String, notBefore: Date, path: String) async throws -> VerifiedSubmission? {
            let revision = readRevision
            locating = false
            readingStart = false
            pending = .init(turnMetadataOnly: true, retainSubmissionText: true)
            var current: (String, SubmissionBoundary)?
            var selected: (String, SubmissionBoundary)?
            var previousEnd: UInt64 = 0
            while true {
                let result = try poll(through: revision.size, turnMetadataOnly: true, retainSubmissionText: true) { line in
                    let end = offset - UInt64(buffered.count)
                    let start = previousEnd
                    previousEnd = end
                    if let id = try parser.resumedTurnID(in: line) {
                        let record = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                        let timestamp = AgentTurnActivity.parseTimestamp(record?["timestamp"] as? String)
                        if selected != nil, selected?.1.nextOffset == nil {
                            selected?.1.nextOffset = start
                            selected?.1.nextEnd = end
                            return .succeeded("")
                        }
                        current = (id, .init(identity: revision.identity, offset: start, end: end, timestamp: timestamp))
                    }
                    if
                        selected == nil, let current, let time = current.1.timestamp, time >= notBefore,
                        try parser.submittedInput(in: line) == prompt {
                        selected = current
                    }
                    return nil
                }
                if result.outcome != nil || result.reachedEnd {
                    break
                }
                await Task.yield()
            }
            guard let selected, pending.retained.isEmpty, revision.isCurrent(at: path) else { return nil }
            return VerifiedSubmission(turn: .init(nativeTurnID: selected.0, transcriptPath: path), submittedAt: selected.1.timestamp, nativeStart: selected.1, revision: revision)
        }

        /// Check the accepted turn through the end of a stable snapshot,
        /// reusing the verified prefix when only ordinary output was appended.
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

        func verifyDelivery(_ turn: PluginWorkflowTurn, input: String) async throws -> VerifiedSubmission? {
            guard
                let scan = try await scanSubmissions(from: turn, input: input),
                let selected = scan.nativeStart, selected.inputOffset != nil else { return nil }
            return VerifiedSubmission(turn: turn, submittedAt: selected.timestamp, nativeStart: selected, matchedInput: input, isRejection: scan.isRejection, revision: scan.revision)
        }

        /// A changing transcript cannot establish submission order.
        func hasNewerSubmission(
            than turn: PluginWorkflowTurn, requiringReceipt: Bool = false,
            hookStartedAt: Date? = nil, nativeStart: SubmissionBoundary? = nil
        ) async throws -> Bool? {
            guard
                let scan = try await scanSubmissions(from: turn, hookStartedAt: hookStartedAt, nativeStart: nativeStart),
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
            from turn: PluginWorkflowTurn, hookStartedAt: Date? = nil, nativeStart: SubmissionBoundary? = nil, input: String? = nil
        ) async throws -> SubmissionScan? {
            let query = SubmissionQuery(turn: turn, hookStartedAt: hookStartedAt, nativeStart: nativeStart, input: input)
            while scanningSubmissions {
                await withCheckedContinuation { submissionWaiters.append($0) }
                try Task.checkCancellation()
            }
            scanningSubmissions = true
            defer {
                scanningSubmissions = false
                let waiters = submissionWaiters
                submissionWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }
            return try await resumeSubmissionScan(query)
        }

        private func resumeSubmissionScan(_ query: SubmissionQuery) async throws -> SubmissionScan? {
            defer { submissionHasher = nil }
            var useAnchor = true
            for _ in 0..<3 {
                try Task.checkCancellation()
                let revision = try currentRevision()
                guard revision.isCurrent(at: query.turn.transcriptPath) else { return nil }
                var scan: SubmissionScan
                var header: Fingerprint?
                var anchor = submissionAnchor.flatMap {
                    guard useAnchor else { return SubmissionAnchor?.none }
                    if query.input != nil, $0.boundary.inputOffset == nil || $0.boundary.inputEnd == nil {
                        return nil
                    }
                    return $0.canLocate(query.turn, hookStartedAt: query.hookStartedAt, nativeStart: query.nativeStart) ? $0 : nil
                }
                if
                    let cached = cachedSubmissionScan, cached.query == query,
                    try validates(cached, at: query.turn.transcriptPath, revision: revision) {
                    if cached.scan.revision == revision || (query.input != nil && cached.scan.nativeStart != nil) {
                        readRevision = revision
                        pending = cached.pending
                        readingStart = cached.readingStart
                        var result = cached.scan
                        result.revision = revision
                        if query.input == nil, query.nativeStart == nil, result.occurrences == 1 {
                            result.nativeStart = result.latestStart
                        }
                        return result
                    }
                    scan = cached.scan
                    scan.revision = revision
                    parser = cached.parser
                    pending = cached.pending
                    offset = cached.scan.revision.size
                    buffered = Data()
                    locating = cached.locating
                    readingStart = cached.readingStart
                    recordStart = cached.recordStart
                    markerTail = cached.markerTail
                    submissionHasher = cached.hasher
                    submissionHashStart = cached.hashStart
                    submissionHashEnd = cached.hashEnd
                    header = cached.header
                    anchor = cached.unverifiedAnchor
                } else {
                    resetSubmissionScan(retainingInput: query.input != nil)
                    scan = SubmissionScan(revision: revision)
                    if
                        let start = anchor, start.boundary.identity == revision.identity,
                        start.boundary.offset < start.boundary.end, start.boundary.end <= revision.size {
                        if parser.readsSessionHeader, start.boundary.offset > 0 {
                            locating = false
                            readingStart = false
                            while true {
                                let header = try poll(through: start.boundary.offset, turnMetadataOnly: true) { line in
                                    _ = try parser.submittedTurnID(in: line)
                                    return .succeeded("")
                                }
                                if header.outcome != nil || header.reachedEnd {
                                    break
                                }
                                await Task.yield()
                            }
                            if let hasher = submissionHasher {
                                header = Fingerprint(start: 0, end: submissionHashEnd, digest: Data(hasher.finalize()))
                            }
                        }
                        offset = start.boundary.offset
                        pending = .init(turnMetadataOnly: true, retainSubmissionRejections: submissionRejectionWindow != nil || query.input != nil, retainSubmissionText: query.input != nil)
                        buffered = Data()
                        recordStart = offset
                        scan.previousEnd = offset
                        scan.inputBoundary = query.input == nil ? nil : start.boundary
                        locating = false
                        readingStart = false
                        submissionHasher = SHA256()
                        submissionHashStart = offset
                        submissionHashEnd = offset
                    } else {
                        anchor = nil
                    }
                }
                var invalidAnchor = false
                while true {
                    let result: Poll
                    do {
                        result = try poll(through: revision.size, turnMetadataOnly: true, retainSubmissionText: query.input != nil) { line in
                            if let expected = anchor {
                                anchor = nil
                                let end = offset - UInt64(buffered.count)
                                do {
                                    let record = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                                    let timestamp = AgentTurnActivity.parseTimestamp(record?["timestamp"] as? String)
                                    let matchesRejection = try query.input != nil && parser.rejectsSubmission(line, during: .distantPast..<Date.distantFuture)
                                    invalidAnchor = try (parser.submittedTurnID(in: line) != expected.turnID && !matchesRejection)
                                        || end != expected.boundary.end || timestamp != expected.boundary.timestamp
                                } catch {
                                    // A changed line can leave the saved offset in
                                    // the middle of JSON. It is no longer a hint.
                                    invalidAnchor = true
                                }
                                if invalidAnchor {
                                    return .succeeded("")
                                }
                            }
                            let start = max(scan.previousEnd, recordStart)
                            let end = offset - UInt64(buffered.count)
                            scan.previousEnd = end
                            let resumed = try parser.resumedTurnID(in: line)
                            if resumed != nil {
                                if let value = scan.firstStart, value.nextOffset == nil, value.offset < start {
                                    scan.firstStart?.nextOffset = start
                                    scan.firstStart?.nextEnd = end
                                }
                                if let value = scan.latestStart, value.nextOffset == nil, value.offset < start {
                                    scan.latestStart?.nextOffset = start
                                    scan.latestStart?.nextEnd = end
                                }
                                if let value = scan.nativeStart, value.nextOffset == nil, value.offset < start {
                                    scan.nativeStart?.nextOffset = start
                                    scan.nativeStart?.nextEnd = end
                                }
                            }
                            if let submitted = try resumed ?? parser.submittedTurnID(in: line) {
                                if submitted == query.turn.nativeTurnID {
                                    let record = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                                    let timestamp = AgentTurnActivity.parseTimestamp(record?["timestamp"] as? String)
                                    let position = SubmissionBoundary(identity: revision.identity, offset: start, end: end, timestamp: timestamp)
                                    if resumed != nil || !scan.foundTurn || (query.input != nil && scan.latestTurnID != submitted) {
                                        if resumed != nil {
                                            if scan.actualCount == 0 {
                                                scan.occurrences = 0
                                                if query.input == nil, query.nativeStart == nil {
                                                    scan.nativeStart = nil
                                                }
                                            }
                                            scan.actualCount += 1
                                        }
                                        if scan.occurrences == 0 {
                                            scan.firstStart = position
                                        }
                                        scan.latestStart = position
                                        scan.occurrences += 1
                                        if query.input == nil, let nativeStart = query.nativeStart {
                                            if nativeStart.identifies(position) {
                                                scan.nativeStart = position
                                            }
                                        } else if query.input == nil, let hookStartedAt = query.hookStartedAt {
                                            if let timestamp, timestamp <= hookStartedAt {
                                                scan.nativeStart = position
                                            }
                                        } else if query.input == nil {
                                            scan.nativeStart = position
                                        }
                                    }
                                    scan.foundTurn = true
                                }
                                scan.latestTurnID = submitted
                            } else if let submissionRejectionWindow, !scan.foundTurn, !scan.rejected {
                                scan.rejected = try parser.rejectsSubmission(line, during: submissionRejectionWindow)
                            }
                            let rejected = try query.input != nil && parser.rejectsSubmission(line, during: .distantPast..<Date.distantFuture)
                            let matchesInput = try query.input.map { try parser.submittedInput(in: line) == $0 } ?? false
                            if query.input != nil, let expected = scan.inputBoundary, start == expected.inputOffset {
                                invalidAnchor = end != expected.inputEnd || (!rejected && (scan.latestTurnID != query.turn.nativeTurnID
                                        || scan.latestStart?.identifies(expected) != true || !matchesInput))
                                if invalidAnchor {
                                    return .succeeded("")
                                }
                            }
                            if
                                query.input != nil, scan.nativeStart == nil,
                                scan.inputBoundary == nil || scan.inputBoundary?.inputOffset == start,
                                rejected || (scan.latestTurnID == query.turn.nativeTurnID && matchesInput) {
                                if rejected {
                                    let record = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                                    scan.nativeStart = .init(identity: revision.identity, offset: start, end: end, timestamp: AgentTurnActivity.parseTimestamp(record?["timestamp"] as? String), nextOffset: end, nextEnd: end)
                                    scan.isRejection = true
                                } else {
                                    scan.nativeStart = scan.latestStart
                                }
                                scan.nativeStart?.inputOffset = start
                                scan.nativeStart?.inputEnd = end
                                return .succeeded("")
                            }
                            return nil
                        }
                    } catch {
                        guard anchor != nil else { throw error }
                        invalidAnchor = true
                        break
                    }
                    if result.reachedEnd || invalidAnchor || (query.input != nil && result.outcome != nil) {
                        break
                    }
                    await Task.yield()
                }
                if query.input != nil, scan.inputBoundary != nil, scan.nativeStart == nil, pending.retained.isEmpty {
                    invalidAnchor = true
                }
                if invalidAnchor {
                    // The persisted position is only a hint. Rebuild from the
                    // original header when its native record no longer matches.
                    cachedSubmissionScan = nil
                    submissionAnchor = nil
                    continue
                }
                if
                    query.input == nil, query.nativeStart == nil, query.hookStartedAt != nil,
                    scan.foundTurn, scan.nativeStart == nil,
                    submissionHashStart > 0, pending.retained.isEmpty {
                    // A timed receipt may belong to an earlier occurrence, even
                    // when several later matches exist after the saved anchor.
                    useAnchor = false
                    cachedSubmissionScan = nil
                    continue
                }
                guard let hasher = submissionHasher else { return nil }
                let cached = CachedSubmissionScan(
                    query: query, scan: scan, parser: parser, pending: pending,
                    locating: locating, readingStart: readingStart, recordStart: recordStart, markerTail: markerTail,
                    hasher: hasher, hashStart: submissionHashStart, hashEnd: submissionHashEnd, header: header,
                    unverifiedAnchor: anchor
                )
                cachedSubmissionScan = cached
                if revision.isCurrent(at: query.turn.transcriptPath) {
                    readRevision = revision
                    if query.input == nil, query.nativeStart == nil, scan.occurrences == 1 {
                        scan.nativeStart = scan.latestStart
                    }
                    return scan
                }
                // Keep the parsed prefix even when ordinary output arrived.
                // The next pass validates its contents before reading the tail.
            }
            return nil
        }

        private func resetSubmissionScan(retainingInput: Bool) {
            parser = initialParser
            pending = .init(turnMetadataOnly: true, retainSubmissionRejections: submissionRejectionWindow != nil || retainingInput, retainSubmissionText: retainingInput)
            offset = 0
            buffered = Data()
            recordStart = 0
            markerTail = Data()
            locating = !markers.isEmpty
            readingStart = locating && parser.readsSessionHeader
            pendingOutcome = nil
            lastOutcome = nil
            submissionHasher = SHA256()
            submissionHashStart = 0
            submissionHashEnd = 0
        }

        private func currentRevision() throws -> FileRevision {
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0, info.st_size >= 0 else {
                throw AgentWorkflowError("The native transcript could not be inspected.")
            }
            return FileRevision(info)
        }

        private func validates(_ cached: CachedSubmissionScan, at path: String, revision: FileRevision) throws -> Bool {
            guard cached.scan.revision.identity == revision.identity, revision.size >= cached.scan.revision.size else { return false }
            if revision == cached.scan.revision {
                return revision.isCurrent(at: path)
            }
            guard revision.size > cached.scan.revision.size else { return false }
            if let header = cached.header, try fingerprint(from: header.start, through: header.end) != header.digest {
                return false
            }
            guard try fingerprint(from: cached.hashStart, through: cached.hashEnd) == Data(cached.hasher.finalize()) else { return false }
            return revision.isCurrent(at: path)
        }

        private func fingerprint(from start: UInt64, through end: UInt64) throws -> Data {
            var hash = SHA256()
            var position = start
            while position < end {
                try Task.checkCancellation()
                var bytes = Data(count: Int(min(64 * 1_024, end - position)))
                let count = bytes.withUnsafeMutableBytes { pread(handle.fileDescriptor, $0.baseAddress, $0.count, off_t(position)) }
                guard count > 0 else { throw AgentWorkflowError("The native transcript changed while verifying its prefix.") }
                bytes.count = count
                bytesRead += UInt64(count)
                hash.update(data: bytes)
                position += UInt64(count)
            }
            return Data(hash.finalize())
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
            if parser.readsSessionHeader, start.offset > 0 {
                try await readSessionHeader(through: start.offset)
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
                        found = try parser.submittedTurnID(in: line) == proof.turn.nativeTurnID || (proof.isRejection && parser.rejectsSubmission(line, during: .distantPast..<Date.distantFuture))
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
            if end == nil, bytesRead == 0, !fixedReadRevision {
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

        private func readSessionHeader(through end: UInt64) async throws {
            pending = .init(turnMetadataOnly: true)
            while true {
                let result = try poll(through: end, turnMetadataOnly: true) { line in
                    _ = try parser.consume(line)
                    return .succeeded("")
                }
                if result.outcome != nil || result.reachedEnd {
                    return
                }
                await Task.yield()
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
            through end: UInt64?, turnMetadataOnly: Bool, retainSubmissionText: Bool = false,
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
                        turnMetadataOnly: turnMetadataOnly, retainSubmissionRejections: submissionRejectionWindow != nil || retainSubmissionText, retainSubmissionText: retainSubmissionText
                    )
                    buffered = Data(buffered[buffered.index(after: newline)...])
                    if readingStart {
                        readingStart = false
                        let startsTurn = try parser.isTurnStart(value)
                        let contextTurn = turnMetadataOnly ? try parser.submittedTurnID(in: value) : nil
                        locating = !startsTurn && contextTurn == nil
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
            if submissionHasher != nil {
                submissionBytesRead += UInt64(count)
                let end = offset + UInt64(count)
                if end > submissionHashEnd {
                    let start = max(offset, submissionHashEnd)
                    submissionHasher?.update(data: bytes.dropFirst(Int(start - offset)))
                    submissionHashEnd = end
                }
            }
            return bytes
        }
    }
#endif
