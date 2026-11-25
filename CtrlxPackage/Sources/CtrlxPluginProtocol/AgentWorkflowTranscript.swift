import CtrlxNetworking
import Foundation

public enum AgentWorkflowTranscriptOutcome: Equatable, Sendable {
    case succeeded(String)
    case failed(String)
}

public struct AgentTurnActivity: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case update
        case command
        case file
        case search
        case tool
    }

    public let id: String
    public let kind: Kind
    public let text: String
    public let sequence: Int?
    public var timestamp: Date?
    public let hasAlignedSequence: Bool?

    public static func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
}

/// Bounded, display-only events from one native turn. Never carries raw tool
/// inputs, outputs or model reasoning.
public struct AgentTurnActivityLog: Sendable {
    public static let maximumEntries = 18
    private let savedSequences: [String: Int]
    private let latestSavedSequence: Int
    private var recorded: [AgentTurnActivity] = []
    public var trackedEvictionIDs: Set<String> {
        didSet { evictedActivityIDs.formIntersection(trackedEvictionIDs) }
    }

    public private(set) var evictedActivityIDs: Set<String> = []
    private var sequence = 0
    private var lastSharedSequence: Int?
    private var isAppending = false

    public init(aligningWith saved: [AgentTurnActivity] = []) {
        let sequences = Dictionary(saved.enumerated().map { ($1.id, $1.sequence ?? ($0 + 1)) }, uniquingKeysWith: max)
        self.savedSequences = sequences
        self.latestSavedSequence = sequences.values.max() ?? 0
        self.trackedEvictionIDs = Set(saved.suffix(Self.maximumEntries).map(\.id))
    }

    public var entries: [AgentTurnActivity] {
        // Later matches can establish more of the replayed history. Only the
        // suffix after the last match continues beyond the saved sequence.
        guard let lastSharedSequence else { return recorded }
        let shift = max(0, latestSavedSequence - lastSharedSequence)
        return recorded.map { entry in
            guard let sequence = entry.sequence, sequence > lastSharedSequence else { return entry }
            return .init(id: entry.id, kind: entry.kind, text: entry.text, sequence: sequence + shift, timestamp: entry.timestamp, hasAlignedSequence: true)
        }
    }

    public mutating func beginAppending() {
        isAppending = true
        if lastSharedSequence == nil {
            sequence = max(sequence, latestSavedSequence)
        }
    }

    public mutating func record(id: String, kind: AgentTurnActivity.Kind, text: String, timestamp: Date? = nil) {
        guard !id.isEmpty, id.utf8.count <= 256, !recorded.contains(where: { $0.id == id }) else { return }
        let preview = String(String.UnicodeScalarView(text.unicodeScalars.prefix(360).filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n"
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else { return }
        if recorded.count == Self.maximumEntries {
            let evicted = recorded.removeFirst().id
            if trackedEvictionIDs.contains(evicted) {
                evictedActivityIDs.insert(evicted)
            }
        }
        evictedActivityIDs.remove(id)
        sequence += 1
        if let savedSequence = savedSequences[id] {
            sequence = max(sequence, savedSequence)
            lastSharedSequence = sequence
        }
        recorded.append(.init(id: id, kind: kind, text: preview, sequence: sequence, timestamp: timestamp, hasAlignedSequence: isAppending ? true : nil))
    }
}

/// Consume complete JSONL records in file order. A partial trailing record is
/// retained by the reader, never interpreted as an empty or completed answer.
public protocol AgentWorkflowTranscriptParser: Sendable {
    /// Cheap byte markers locate candidate records without decoding old history.
    var startMarkers: [String] { get }
    var readsSessionHeader: Bool { get }
    /// A durable native completion, independent of a Stop callback lost on restart.
    var recoveredCompletion: AgentWorkflowTranscriptOutcome? { get }
    /// Whether a nil recovery result also invalidates earlier terminal records.
    var tracksCompletionAtEnd: Bool { get }
    var activity: [AgentTurnActivity] { get }
    var evictedActivityIDs: Set<String> { get }
    mutating func trackActivityEvictions(for ids: Set<String>)
    mutating func captureActivity(aligningWith saved: [AgentTurnActivity])
    mutating func beginAppendingActivity()
    func isTurnStart(_ line: Data) throws -> Bool
    mutating func submittedTurnID(in line: Data) throws -> String?
    mutating func resumedTurnID(in line: Data) throws -> String?
    var submissionRejectionMarker: String? { get }
    func rejectsSubmission(_ line: Data, during: Range<Date>) throws -> Bool
    /// Update Stop text without resetting the turn; return matching evidence
    /// already consumed so a late callback or inspection retry needs no replay.
    mutating func updateCandidate(_ candidate: String) -> AgentWorkflowTranscriptOutcome?
    mutating func consume(_ line: Data) throws -> AgentWorkflowTranscriptOutcome?
}

public extension AgentWorkflowTranscriptParser {
    var tracksCompletionAtEnd: Bool {
        false
    }

    var activity: [AgentTurnActivity] {
        []
    }

    var evictedActivityIDs: Set<String> {
        []
    }

    mutating func trackActivityEvictions(for _: Set<String>) { }

    mutating func captureActivity() {
        captureActivity(aligningWith: [])
    }

    mutating func captureActivity(aligningWith _: [AgentTurnActivity]) { }

    mutating func beginAppendingActivity() { }

    var recoveredCompletion: AgentWorkflowTranscriptOutcome? {
        nil
    }

    var startMarkers: [String] {
        []
    }

    var readsSessionHeader: Bool {
        false
    }

    func isTurnStart(_: Data) throws -> Bool {
        false
    }

    mutating func submittedTurnID(in _: Data) throws -> String? {
        nil
    }

    mutating func resumedTurnID(in line: Data) throws -> String? {
        try submittedTurnID(in: line)
    }

    var submissionRejectionMarker: String? {
        nil
    }

    func rejectsSubmission(_: Data, during _: Range<Date>) throws -> Bool {
        false
    }
}

/// Optional capability implemented by native Agent plugins. The Host owns I/O
/// and scheduling; each core owns its provider's durable completion semantics.
public protocol AgentWorkflowProviding: Actor {
    nonisolated var workflowCapabilities: AgentWorkflowCapabilities { get }
    nonisolated var workflowComposer: AgentWorkflowComposer { get }
    nonisolated var workflowCLIVersionSupport: String? { get }
    nonisolated func supportsWorkflowCLI(_ version: String) -> Bool
    nonisolated func workflowTranscript(
        conversationID: String,
        nativeTurnID: String,
        prompt: String,
        candidate: String
    ) -> any AgentWorkflowTranscriptParser
}

public extension AgentWorkflowProviding {
    nonisolated var workflowCLIVersionSupport: String? {
        nil
    }

    nonisolated func supportsWorkflowCLI(_: String) -> Bool {
        false
    }

    /// Version admission is separate from native hook and instance validation.
    nonisolated func workflowRuntimeIssue(cliVersion: String?) -> String? {
        guard let cliVersion, !cliVersion.isEmpty else {
            // CLI upgrades can remove the executable while its Agent is still running.
            return nil
        }
        guard supportsWorkflowCLI(cliVersion) else {
            return "Workflows do not support \(cliVersion)."
                + (workflowCLIVersionSupport.map { " Supported range: \($0)." } ?? " This plugin has no supported workflow CLI versions.")
        }
        return nil
    }
}
