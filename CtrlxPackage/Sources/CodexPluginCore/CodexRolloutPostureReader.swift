import Foundation

// MARK: - CodexRolloutPostureReader

/// Reads a session's EFFECTIVE approvals posture from the latest
/// `turn_context` record of its rollout file (issue #717).
///
/// codex ≥ 0.146 persists `approvals_reviewer` (and `approval_policy`) into
/// every `turn_context` rollout record — turn contexts are written when a
/// turn spawns, from the same context that routes that turn's approvals, so
/// the latest record IS the per-session ground truth the #585 snapshot
/// design had to approximate. In particular it survives resumes (which fire
/// no SessionStart hook) and attributes mid-session "Approve for me"
/// toggles to the toggling session.
///
/// Reads backward from a snapshot of EOF in fixed-size chunks, with limits
/// on both record size and total I/O. Multi-day rollouts can exceed gigabytes;
/// never read the whole file or follow concurrent appends. If the scan cannot
/// finish within its limits, return `.user` (notify-anyway), NOT nil: falling
/// back to a snapshot or an older record could suppress a real permission.
///
/// Returns `nil` when the rollout carries no signal (missing file, no
/// `turn_context` records, or a pre-0.146 record without
/// `approvals_reviewer`) so the caller can fall back to the snapshot
/// heuristic. Any present-but-unrecognized value degrades toward `.user`
/// (notify-anyway), the same fail-safe direction as `CodexConfigReader`.
struct CodexRolloutPostureReader: Sendable {
    static let readChunkBytes = 256 * 1024
    static let maximumRecordBytes = 1024 * 1024
    static let maximumScanBytes = 8 * 1024 * 1024

    /// What a scan of one region concluded — distinguishes "no turn_context
    /// here" (worth scanning further) from "found one, and its verdict is
    /// nil" (pre-0.146 record: the latest record IS the answer, and the
    /// answer is "no signal").
    private enum ScanResult {
        case found(CodexApprovalsReviewer?)
        case noTurnContext
    }

    /// Resolves the posture from the rollout at `transcriptPath`.
    func posture(transcriptPath: String) -> CodexApprovalsReviewer? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        var end = size
        var bytesRead = 0
        var suffix = Data()
        while end > 0, bytesRead < Self.maximumScanBytes {
            let count = Int(min(end, UInt64(min(Self.readChunkBytes, Self.maximumScanBytes - bytesRead))))
            let start = end - UInt64(count)
            guard
                (try? handle.seek(toOffset: start)) != nil,
                var chunk = try? handle.read(upToCount: count),
                chunk.count == count
            else { return .user } // Truncation/I/O failure makes this scan inconclusive.
            bytesRead += count
            chunk.append(suffix)

            // Reassemble bytes before decoding: even a UTF-8 character or
            // JSON record split exactly at a chunk boundary remains intact.
            var lineEnd = chunk.endIndex
            for index in chunk.indices.reversed() where chunk[index] == 0x0A {
                let line = chunk[(index + 1)..<lineEnd]
                if case let .found(posture) = scanLine(line) { return posture }
                lineEnd = index
            }
            let prefix = chunk[..<lineEnd]
            if start == 0 {
                if case let .found(posture) = scanLine(prefix) { return posture }
                return nil
            }
            // Do not skip an oversized record and accidentally use an older
            // auto-review verdict. Bound memory even for newline-free files.
            guard prefix.count <= Self.maximumRecordBytes else { return .user }
            suffix = Data(prefix)
            end = start
        }
        return end == 0 ? nil : .user
    }

    private func scanLine(_ data: Data) -> ScanResult {
        guard data.count <= Self.maximumRecordBytes else { return .found(.user) }
        // A torn append only corrupts its own record, not preceding records.
        // swiftlint:disable:next optional_data_string_conversion
        let line = String(decoding: data, as: UTF8.self)
        guard line.contains("\"turn_context\""), let payload = turnContextPayload(of: line) else {
            return .noTurnContext
        }
        return .found(reviewer(of: payload))
    }

    /// Parses a candidate line, returning its `payload` only when the line
    /// really is a `turn_context` record.
    private func turnContextPayload(of line: String) -> [String: Any]? {
        guard
            let record = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                as? [String: Any],
            record["type"] as? String == "turn_context",
            let payload = record["payload"] as? [String: Any]
        else { return nil }
        return payload
    }

    /// Maps a turn_context payload to a posture. `nil` when the record
    /// predates the `approvals_reviewer` field (codex < 0.146).
    ///
    /// The reviewer alone is not sufficient: under an `untrusted`/
    /// `on-failure` approval policy codex routes approvals to the USER even
    /// with `auto_review` set, so suppression additionally requires the
    /// guardian-routing `on-request` policy. Unknown reviewer or policy
    /// values (future codex) fail safe to `.user`.
    private func reviewer(of payload: [String: Any]) -> CodexApprovalsReviewer? {
        guard let reviewer = payload["approvals_reviewer"] as? String else {
            return nil
        }
        guard
            reviewer == "auto_review" || reviewer == "guardian_subagent",
            payload["approval_policy"] as? String == "on-request"
        else { return .user }
        return .autoReview
    }
}
