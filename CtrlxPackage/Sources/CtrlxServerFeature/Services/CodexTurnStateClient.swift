import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct CodexTurnStateClient: Sendable {
    var isIdle: @Sendable (_ processID: String, _ runtimeID: String) async -> Bool = { _, _ in false }
    var wasAborted: @Sendable (_ processID: String, _ runtimeID: String, _ conversationID: String, _ turnID: UUID) async -> Bool = { _, _, _, _ in false }
}

extension CodexTurnStateClient: DependencyKey {
    static let liveValue: Self = {
        let reader = CodexProcessSessionReader()
        return Self(
            isIdle: { await reader.turnCompleted(processID: $0, runtimeID: $1) },
            wasAborted: { await reader.turnAborted(processID: $0, runtimeID: $1, conversationID: $2, turnID: $3) }
        )
    }()

    static let testValue = Self(isIdle: { _, _ in false }, wasAborted: { _, _, _, _ in false })
}
