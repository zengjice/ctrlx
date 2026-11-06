import Dependencies
import DependenciesMacros

@DependencyClient
struct CodexHookTrustIdleClient: Sendable {
    var isIdle: @Sendable (_ processID: String, _ runtimeID: String) async -> Bool = { _, _ in false }
}

extension CodexHookTrustIdleClient: DependencyKey {
    static let liveValue: Self = {
        let reader = CodexProcessSessionReader()
        return Self(isIdle: { await reader.turnCompleted(processID: $0, runtimeID: $1) })
    }()

    static let testValue = Self(isIdle: { _, _ in false })
}
