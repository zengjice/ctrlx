import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct CodexTurnStateClient: Sendable {
    var isIdle: @Sendable (_ processID: String, _ runtimeID: String) async -> Bool = { _, _ in false }
    var wasAbortedOrFailed: @Sendable (_ processID: String, _ runtimeID: String, _ conversationID: String, _ turnID: UUID) async -> Bool = { _, _, _, _ in false }
    var cancelledQuestionIDs: @Sendable (_ processID: String, _ runtimeID: String, _ conversationID: String, _ questionIDs: [String]) async -> [String] = { _, _, _, _ in [] }
}

extension CodexTurnStateClient: DependencyKey {
    static let liveValue: Self = {
        let reader = CodexProcessSessionReader()
        return Self(
            isIdle: { await reader.turnCompleted(processID: $0, runtimeID: $1) },
            wasAbortedOrFailed: { await reader.turnAbortedOrFailed(processID: $0, runtimeID: $1, conversationID: $2, turnID: $3) },
            cancelledQuestionIDs: { await reader.cancelledQuestionIDs(processID: $0, runtimeID: $1, conversationID: $2, questionIDs: $3) }
        )
    }()

    static let testValue = Self(isIdle: { _, _ in false }, wasAbortedOrFailed: { _, _, _, _ in false }, cancelledQuestionIDs: { _, _, _, _ in [] })
}
