import CtrlxNetworking
import Foundation
import Observation

@MainActor @Observable
final public class RemoteSimulatorSession {
    public private(set) var frame: RemoteSimulatorFrame?
    public private(set) var error: String?
    public var frameMaxDimension = 1_024
    @ObservationIgnored private let tab: RemoteSimulatorTab
    @ObservationIgnored private let send: @MainActor (BrowseSimulator) async throws -> RemoteSimulatorResponse
    @ObservationIgnored private var epoch = UUID()

    public init(tab: RemoteSimulatorTab, send: @escaping @MainActor (BrowseSimulator) async throws -> RemoteSimulatorResponse) {
        self.tab = tab
        self.send = send
    }

    public convenience init(tab: RemoteSimulatorTab, client: ViewerRelayClient) {
        self.init(tab: tab) { request in
            let result = try await client.sendCommand(request, paneId: "", timeout: 8).get()
            guard result.success, let response = result.simulator else {
                throw ViewerRelayClientError.commandFailed(result.error ?? "Missing simulator response")
            }
            return response
        }
    }

    public func watch() async {
        stop()
        let current = epoch
        defer {
            if epoch == current {
                stop()
            }
        }
        while !Task.isCancelled, epoch == current {
            do {
                let response = try await send(BrowseSimulator(
                    sessionName: tab.sessionName,
                    tabID: tab.id,
                    frameMaxDimension: frameMaxDimension
                ))
                try Task.checkCancellation()
                guard epoch == current else { return }
                guard response.tab.id == tab.id, response.tab.sessionName == tab.sessionName, response.frame.isValid else {
                    throw ViewerRelayClientError.commandFailed("Invalid simulator preview")
                }
                frame = response.frame
                error = nil
            } catch is CancellationError { return }
            catch {
                guard epoch == current else { return }
                self.error = error.localizedDescription
            }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        }
    }

    public func stop() {
        epoch = UUID()
        frame = nil
    }
}
