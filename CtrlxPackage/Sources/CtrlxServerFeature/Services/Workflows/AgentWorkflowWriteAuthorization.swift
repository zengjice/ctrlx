import CtrlxNetworking
import Foundation
import Synchronization

/// Revocation and the process launch share one synchronous boundary.
/// Once launched, input is in flight and pause/end cannot retract it.
final class AgentWorkflowWriteAuthorization: Sendable {
    private let available = Mutex(true)
    private let expiresAt: Date

    init(expiresAt: Date) {
        self.expiresAt = expiresAt
    }

    func perform(_ launch: () throws -> Void) throws {
        try available.withLock { value in
            guard value, expiresAt > Date() else {
                throw AgentWorkflowError("The workflow is no longer authorized to submit this input.")
            }
            value = false
            try launch()
        }
    }

    func revoke() {
        available.withLock { $0 = false }
    }
}
