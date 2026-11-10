import CtrlxNetworking
import Darwin
import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct AgentRestartProcessClient: Sendable {
    var terminate: @Sendable (_ processID: String, _ runtimeID: String) throws -> Void
}

extension AgentRestartProcessClient: DependencyKey {
    static let liveValue = Self(terminate: { processID, runtimeID in
        guard
            let pid = Int32(processID), pid > 1,
            AgentSessionIdentityClient.processRuntimeID(processID) == runtimeID else {
            throw AgentRestartError("The Agent process changed before it could exit.")
        }
        guard Darwin.kill(pid, SIGTERM) == 0 else {
            throw AgentRestartError("Could not ask the Agent to exit: \(String(cString: strerror(errno)))")
        }
    })
    static let testValue = Self()
}
