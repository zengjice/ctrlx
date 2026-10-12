import CtrlxNetworking
import Observation

/// A navigation retry must not insert an already acknowledged screenshot again.
@MainActor @Observable
final class BrowserAnnotationDelivery {
    private(set) var deliveredTarget: AgentImageTarget?

    func sendAndReveal(target: AgentImageTarget,
                       send: () async throws -> Void,
                       reveal: (AgentImageTarget) async throws -> Void) async throws {
        if deliveredTarget == nil {
            try await send()
            deliveredTarget = target
        }
        try Task.checkCancellation()
        if let deliveredTarget { try await reveal(deliveredTarget) }
        try Task.checkCancellation()
    }
}
