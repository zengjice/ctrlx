import CtrlxNetworking
import Foundation
import Observation

@MainActor @Observable
final public class RemoteSimulatorSession {
    public private(set) var preview: RemoteSimulatorResponse?
    public var frame: RemoteSimulatorFrame? {
        preview?.frame
    }

    public private(set) var error: String?
    public var frameMaxDimension = 1_024
    @ObservationIgnored private var tab: RemoteSimulatorTab
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

    public static func open(
        sessionName: String,
        sourcePaneID: String,
        client: ViewerRelayClient,
        inputBinding: ViewerWorkspaceInputBinding
    ) async throws -> RemoteSimulatorTab {
        let result = try await client.sendCommand(
            OpenPaneSimulator(sessionName: sessionName, sourcePaneID: sourcePaneID),
            paneId: sourcePaneID, timeout: 240, inputBinding: inputBinding
        ).get()
        try Task.checkCancellation()
        _ = try inputBinding.expectedPane(current: client.workspaceInputState.binding(paneID: sourcePaneID))
        guard result.success, let tab = result.simulatorTab, tab.sessionName == sessionName, tab.sourcePaneID == sourcePaneID else {
            throw ViewerRelayClientError.commandFailed(result.error ?? "Host did not return the source pane's simulator")
        }
        client.rememberOpenedSimulator(tab)
        return tab
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
                let response = try await requestFrame(tab, maxDimension: frameMaxDimension)
                guard epoch == current else { return }
                tab = response.tab
                preview = response
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
        preview = nil
    }

    /// Freeze the decoded, displayed frame, not a newer response still waiting to be displayed.
    public func annotationScreenshot(from displayed: RemoteSimulatorResponse) throws -> Data {
        guard
            preview != nil, displayed.frame.isValid,
            displayed.tab.id == tab.id, displayed.tab.sessionName == tab.sessionName,
            displayed.tab.windowID == tab.windowID, displayed.tab.sourcePaneID == tab.sourcePaneID else {
            throw ViewerRelayClientError.commandFailed("The simulator preview changed. Wait for its current frame and try again.")
        }
        stop()
        return displayed.frame.jpeg
    }

    private func requestFrame(_ tab: RemoteSimulatorTab, maxDimension: Int) async throws -> RemoteSimulatorResponse {
        try Task.checkCancellation()
        let response = try await send(BrowseSimulator(
            sessionName: tab.sessionName, tabID: tab.id, frameMaxDimension: maxDimension
        ))
        try Task.checkCancellation()
        guard
            response.tab.id == tab.id, response.tab.sessionName == tab.sessionName,
            response.frame.isValid else {
            throw ViewerRelayClientError.commandFailed("The simulator changed or its preview is invalid. Reopen the tab and try again.")
        }
        return response
    }
}
