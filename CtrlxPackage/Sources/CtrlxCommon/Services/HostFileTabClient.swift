import CtrlxNetworking
import Foundation

@MainActor
public enum HostFileTabClient {
    public static func open(connection: ViewerConnection?, sessionName: String, paneID: String, new: Bool = false) async throws -> HostFileTab {
        guard let connection, connection.isHostConnected else { throw FileBrowserError.message("Host is offline.") }
        let response = try await connection.sendCommand(BrowseFiles(.tabs(.open(sessionName: sessionName, new: new))), paneId: paneID).get()
        try Task.checkCancellation()
        guard case let .tab(tab) = response.fileBrowser, tab.sourcePaneID == paneID, tab.sessionName == sessionName, tab.group == .human else {
            throw FileBrowserError.message("The Host returned no matching Files tab.")
        }
        connection.relayClient.rememberOpenedFileTab(tab)
        _ = await connection.relayClient.requestSessionState()
        return tab
    }

    public static func close(connection: ViewerConnection?, id: UUID) async throws {
        guard let connection, connection.isHostConnected else { throw FileBrowserError.message("Host is offline.") }
        let response = try await connection.sendCommand(BrowseFiles(.tabs(.close(id: id))), paneId: "").get()
        guard response.fileBrowser == .tabClosed else { throw FileBrowserError.message("The Host did not confirm closing the Files tab.") }
        connection.relayClient.forgetClosedFileTab(id)
        _ = await connection.relayClient.requestSessionState()
    }
}
