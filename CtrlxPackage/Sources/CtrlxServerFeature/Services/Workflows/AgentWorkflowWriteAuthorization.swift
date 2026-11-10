import CtrlxNetworking
import Foundation
import Synchronization

/// Revocation and the process launch share one synchronous boundary.
/// Once launched, input is in flight and pause/end cannot retract it.
final class AgentWorkflowWriteAuthorization: Sendable {
    private struct State {
        var remaining: Int
        var configuring = false
    }

    private let state: Mutex<State>
    private let numberOfWrites: Int
    private let expiresAt: Date

    init(expiresAt: Date, numberOfWrites: Int = 1) {
        self.expiresAt = expiresAt
        self.numberOfWrites = numberOfWrites
        self.state = Mutex(State(remaining: numberOfWrites))
    }

    func perform(_ launch: () throws -> Void) throws {
        try state.withLock { value in
            guard value.remaining > 0, !value.configuring, expiresAt > Date() else {
                throw AgentWorkflowError("The workflow is no longer authorized to submit this input.")
            }
            value.remaining -= 1
            try launch()
        }
    }

    func beginConfiguration() throws {
        try state.withLock { value in
            guard value.remaining == numberOfWrites, expiresAt > Date() else {
                throw AgentWorkflowError("The workflow is no longer authorized to configure this step.")
            }
            value.configuring = true
        }
    }

    func performConfiguration(_ launch: () throws -> Void) throws {
        try state.withLock { value in
            guard value.configuring, value.remaining > 0, expiresAt > Date() else {
                throw AgentWorkflowError("The workflow is no longer authorized to configure this step.")
            }
            try launch()
        }
    }

    func endConfiguration() {
        state.withLock { $0.configuring = false }
    }

    var isStaging: Bool {
        state.withLock { $0.remaining > 0 && ($0.configuring || $0.remaining < numberOfWrites) && expiresAt > Date() }
    }

    func revoke() {
        state.withLock { $0.remaining = 0
            $0.configuring = false
        }
    }
}
