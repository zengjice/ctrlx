import CtrlxNetworking
import Foundation
import Synchronization

/// Revocation and the process launch share one synchronous boundary.
/// Once launched, input is in flight and pause/end cannot retract it.
final class AgentWorkflowWriteAuthorization: Sendable {
    private let remaining: Mutex<Int>
    private let numberOfWrites: Int
    private let expiresAt: Date

    init(expiresAt: Date, numberOfWrites: Int = 1) {
        self.expiresAt = expiresAt
        self.numberOfWrites = numberOfWrites
        self.remaining = Mutex(numberOfWrites)
    }

    func perform(_ launch: () throws -> Void) throws {
        try remaining.withLock { value in
            guard value > 0, expiresAt > Date() else {
                throw AgentWorkflowError("The workflow is no longer authorized to submit this input.")
            }
            value -= 1
            try launch()
        }
    }

    var isStaging: Bool {
        remaining.withLock { $0 > 0 && $0 < numberOfWrites && expiresAt > Date() }
    }

    func revoke() {
        remaining.withLock { $0 = 0 }
    }
}
