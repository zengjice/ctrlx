import Darwin
import Foundation

/// Reads only the active writer's metadata, never argv (which names the parent
/// of a fork) or a history-directory search (which can belong to another pane).
actor CodexProcessSessionReader {
    static func supports(pluginID: String) -> Bool {
        pluginID == "codex" || pluginID == "traex"
    }

    static let headerLimit = 256 * 1_024
    static let completionLimit = 1_024 * 1_024
    private static let descriptorLimit = 4_096

    func sessionID(processID: String, runtimeID: String) -> String? {
        guard
            !Task.isCancelled, let pid = Int32(processID),
            AgentSessionIdentityClient.processRuntimeID(processID) == runtimeID,
            let before = activeRollout(pid: pid),
            let header = readHeader(before),
            let id = Self.sessionID(header: header, path: before.path),
            !Task.isCancelled,
            AgentSessionIdentityClient.processRuntimeID(processID) == runtimeID,
            activeRollout(pid: pid) == before
        else { return nil }
        return id
    }

    func turnCompleted(processID: String, runtimeID: String) -> Bool {
        hasCompletedTurn(processID: processID, runtimeID: runtimeID)
    }

    func turnAbortedOrFailed(processID: String, runtimeID: String, conversationID: String, turnID: UUID) -> Bool {
        guard let sessionID = UUID(uuidString: conversationID) else { return false }
        return hasCompletedTurn(processID: processID, runtimeID: runtimeID, conversationID: sessionID, abortedOrFailedTurnID: turnID)
    }

    private func hasCompletedTurn(processID: String, runtimeID: String, conversationID: UUID? = nil, abortedOrFailedTurnID: UUID? = nil) -> Bool {
        guard
            !Task.isCancelled, let pid = Int32(processID),
            AgentSessionIdentityClient.processRuntimeID(processID) == runtimeID,
            let writer = activeRollout(pid: pid, conversationID: conversationID),
            let header = readHeader(writer),
            let sessionID = Self.sessionID(header: header, path: writer.path),
            conversationID == nil || UUID(uuidString: sessionID) == conversationID,
            readCompletion(writer, abortedOrFailedTurnID: abortedOrFailedTurnID),
            !Task.isCancelled,
            AgentSessionIdentityClient.processRuntimeID(processID) == runtimeID,
            activeRollout(pid: pid, conversationID: conversationID) == writer,
            conversationID == nil || readHeader(writer) == header
        else { return false }
        return true
    }

    /// Authenticated receipts already name a conversation. Verify that exact
    /// CLI writer even when /new has retained a previous conversation's file.
    func ownsSession(processID: String, runtimeID: String, conversationID: String) -> Bool {
        guard
            !Task.isCancelled, let pid = Int32(processID), let id = UUID(uuidString: conversationID),
            AgentSessionIdentityClient.processRuntimeID(processID) == runtimeID,
            let writer = activeRollout(pid: pid, conversationID: id),
            let header = readHeader(writer),
            Self.sessionID(header: header, path: writer.path) == conversationID,
            !Task.isCancelled,
            AgentSessionIdentityClient.processRuntimeID(processID) == runtimeID,
            activeRollout(pid: pid, conversationID: id) == writer
        else { return false }
        return true
    }

    private struct Rollout: Equatable {
        let path: String
        let device: UInt32
        let inode: UInt64
    }

    private func activeRollout(pid: Int32, conversationID: UUID? = nil) -> Rollout? {
        guard let writers = writableRollouts(pid: pid) else { return nil }
        let matches = writers.filter { conversationID == nil || Self.filenameID($0.path) == conversationID }
        guard let first = matches.first, matches.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private func writableRollouts(pid: Int32) -> [Rollout]? {
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Self.descriptorLimit)
        let capacity = descriptors.count * MemoryLayout<proc_fdinfo>.stride
        let size = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard size > 0, size < capacity, Int(size) % MemoryLayout<proc_fdinfo>.stride == 0 else { return nil }
        var result: [Rollout] = []
        for descriptor in descriptors.prefix(Int(size) / MemoryLayout<proc_fdinfo>.stride) {
            guard descriptor.proc_fdtype == PROX_FDTYPE_VNODE else { continue }
            var info = vnode_fdinfowithpath()
            guard
                proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
                info.pfi.fi_openflags & UInt32(FWRITE) != 0,
                info.pvip.vip_vi.vi_stat.vst_mode & UInt16(S_IFMT) == UInt16(S_IFREG)
            else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) {
                String(bytes: $0.prefix(while: { $0 != 0 }), encoding: .utf8)
            }
            guard let path, Self.filenameID(path) != nil else { continue }
            let candidate = Rollout(path: path, device: info.pvip.vip_vi.vi_stat.vst_dev, inode: info.pvip.vip_vi.vi_stat.vst_ino)
            result.append(candidate)
        }
        return result
    }

    private func openRollout(_ rollout: Rollout) -> Int32? {
        let fd = open(rollout.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard
            fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            UInt32(bitPattern: info.st_dev) == rollout.device, info.st_ino == rollout.inode
        else {
            close(fd)
            return nil
        }
        return fd
    }

    private func readHeader(_ rollout: Rollout) -> Data? {
        guard let fd = openRollout(rollout) else { return nil }
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: Self.headerLimit + 1)
        let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count > 0, let newline = bytes.prefix(count).firstIndex(of: 10), newline <= Self.headerLimit else { return nil }
        return Data(bytes[..<newline])
    }

    private func readCompletion(_ rollout: Rollout, abortedOrFailedTurnID: UUID?) -> Bool {
        guard let fd = openRollout(rollout) else { return false }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_size > 0 else { return false }
        let matches: Bool
        if let abortedOrFailedTurnID {
            matches = readAbortedOrFailedTurn(fd, end: before.st_size, turnID: abortedOrFailedTurnID)
        } else {
            let offset = max(0, before.st_size - off_t(Self.completionLimit))
            guard let bytes = readChunk(fd, from: offset, to: before.st_size) else { return false }
            matches = Self.lastTurnCompleted(bytes, startsAtBeginning: offset == 0)
        }
        var after = stat()
        return matches && fstat(fd, &after) == 0 && after.st_size == before.st_size
            && after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
            && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
    }

    private func readAbortedOrFailedTurn(_ fd: Int32, end: off_t, turnID: UUID) -> Bool {
        var scan = TurnCompletion(abortedOrFailedTurnID: turnID)
        var chunkEnd = end
        var recordEnd: off_t?
        while chunkEnd > 0 {
            let offset = max(0, chunkEnd - off_t(Self.completionLimit))
            guard !Task.isCancelled, let bytes = readChunk(fd, from: offset, to: chunkEnd) else { return false }
            if chunkEnd == end, bytes.last != 10 {
                return false
            }
            for index in bytes.indices.reversed() where bytes[index] == 10 {
                let newline = offset + off_t(index)
                defer { recordEnd = newline }
                guard let recordEnd, newline + 1 < recordEnd else { continue }
                // Reread a split record from its start to validate the JSON while discarding large bodies.
                let line = recordEnd <= chunkEnd
                    ? bytes[(index + 1)..<Int(recordEnd - offset)]
                    : readSplitRecord(fd, from: newline + 1, to: recordEnd)
                guard let line else { return false }
                if let result = scan.consume(line) {
                    return result
                }
            }
            chunkEnd = offset
        }
        // The first line is the separately verified session header.
        return false
    }

    private func readSplitRecord(_ fd: Int32, from start: off_t, to end: off_t) -> Data? {
        var record = AgentWorkflowTranscriptRecord(turnMetadataOnly: true)
        var offset = start
        do {
            while offset < end {
                let next = min(end, offset + off_t(Self.completionLimit))
                guard !Task.isCancelled, let bytes = readChunk(fd, from: offset, to: next) else { return nil }
                try record.append(bytes)
                offset = next
            }
            return try record.finish()
        } catch {
            return nil
        }
    }

    private func readChunk(_ fd: Int32, from offset: off_t, to end: off_t) -> Data? {
        var bytes = Data(count: Int(end - offset))
        let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, offset) }
        return count == bytes.count ? bytes : nil
    }

    static func lastTurnCompleted(_ data: Data, startsAtBeginning: Bool = true, abortedOrFailedTurnID: UUID? = nil) -> Bool {
        // A partial append may be a newer task start. Never fall back to an
        // older completion when the latest record is incomplete or malformed.
        guard data.count <= completionLimit, data.last == 10 else { return false }
        var lines = data.split(separator: 10)
        if !startsAtBeginning, !lines.isEmpty {
            lines.removeFirst()
        }
        var scan = TurnCompletion(abortedOrFailedTurnID: abortedOrFailedTurnID)
        for line in lines.reversed() {
            if let result = scan.consume(line) {
                return result
            }
        }
        return false
    }

    private struct TurnCompletion {
        private struct Record: Decodable {
            struct Payload: Decodable {
                let type: String?
                let turn_id: String?
            }

            let type: String
            let payload: Payload
        }

        private struct FailedCompletion: Decodable {
            struct Payload: Decodable {
                struct ErrorDetails: Decodable {
                    let message: String
                }

                let error: ErrorDetails
            }

            let payload: Payload
        }

        let abortedOrFailedTurnID: UUID?
        var completedTurn: UUID?

        /// Continue only until the latest turn boundary or contradictory evidence.
        mutating func consume(_ line: Data) -> Bool? {
            guard let record = try? JSONDecoder().decode(Record.self, from: line) else { return false }
            if record.type == "turn_context" {
                guard let id = record.payload.turn_id.flatMap(UUID.init(uuidString:)), id == completedTurn else { return false }
            }
            guard record.type == "event_msg" else {
                guard completedTurn != nil else { return false }
                return nil
            }
            switch record.payload.type {
            case "task_complete",
                 "turn_complete",
                 "turn_aborted":
                guard let id = record.payload.turn_id.flatMap(UUID.init(uuidString:)), completedTurn == nil || completedTurn == id else { return false }
                if let abortedOrFailedTurnID, completedTurn == nil {
                    guard
                        id == abortedOrFailedTurnID,
                        record.payload.type == "turn_aborted" || (try? JSONDecoder().decode(FailedCompletion.self, from: line)) != nil
                    else { return false }
                }
                completedTurn = id
            case "task_started",
                 "turn_started":
                return completedTurn != nil && record.payload.turn_id.flatMap(UUID.init(uuidString:)) == completedTurn
            default:
                let isThreadSettings = abortedOrFailedTurnID != nil && record.payload.type == "thread_settings_applied"
                guard completedTurn != nil || record.payload.type == "token_count" || isThreadSettings else { return false }
                if let raw = record.payload.turn_id {
                    guard let id = UUID(uuidString: raw), id == completedTurn else { return false }
                }
            }
            return nil
        }
    }

    static func sessionID(header: Data, path: String) -> String? {
        struct Record: Decodable {
            struct Metadata: Decodable {
                let id: String
                let source: String
            }

            let type: String
            let payload: Metadata
        }
        guard
            header.count <= headerLimit,
            let filenameID = filenameID(path),
            let record = try? JSONDecoder().decode(Record.self, from: header),
            record.type == "session_meta", record.payload.source == "cli",
            UUID(uuidString: record.payload.id) == filenameID
        else { return nil }
        return record.payload.id
    }

    private static func filenameID(_ path: String) -> UUID? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return nil }
        let stem = name.dropLast(6)
        // A resumed Codex thread adds the rollout UUID after the thread UUID.
        if let separator = stem.firstIndex(of: "_") {
            guard UUID(uuidString: String(stem[stem.index(after: separator)...])) != nil else { return nil }
            return UUID(uuidString: String(stem[..<separator].suffix(36)))
        }
        return UUID(uuidString: String(stem.suffix(36)))
    }
}
