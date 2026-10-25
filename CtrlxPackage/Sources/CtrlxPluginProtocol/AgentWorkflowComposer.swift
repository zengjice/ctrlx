import Foundation

/// The native plugin describes its empty composer; the Host inspects actual
/// terminal cells before allowing an automatic paste. Unknown layouts fail closed.
public struct AgentWorkflowComposer: Sendable {
    public let prompt: String
    public let dimPlaceholder: String?
    public let enclosedByRules: Bool
    public let drawsInverseCursor: Bool
    public let pendingInputHints: [String]

    public init(prompt: String, dimPlaceholder: String? = nil, enclosedByRules: Bool = false, drawsInverseCursor: Bool = false, pendingInputHints: [String] = []) {
        self.prompt = prompt
        self.dimPlaceholder = dimPlaceholder
        self.enclosedByRules = enclosedByRules
        self.drawsInverseCursor = drawsInverseCursor
        self.pendingInputHints = pendingInputHints
    }
}
