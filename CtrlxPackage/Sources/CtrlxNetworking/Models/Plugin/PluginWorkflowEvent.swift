import Foundation

/// Native lifecycle evidence, not a declaration that a workflow succeeded.
/// A Stop hook runs before other hooks can veto completion; its transcript
/// must confirm the final outcome before the Host hands a result downstream.
public struct PluginWorkflowEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case submitted
        case stopCandidate
        case failed
    }

    public let kind: Kind
    public let nativeTurnID: String
    public let transcriptPath: String
    public let text: String
    public let hasPendingWork: Bool

    public init(kind: Kind, nativeTurnID: String, transcriptPath: String, text: String, hasPendingWork: Bool = false) {
        self.kind = kind
        self.nativeTurnID = nativeTurnID
        self.transcriptPath = transcriptPath
        self.text = text
        self.hasPendingWork = hasPendingWork
    }
}
