import CtrlxNetworking
import Foundation

public enum FileBrowserError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { switch self { case let .message(message): message } }
}

@MainActor
public struct FileBrowserSource {
    public let id: String
    public let paneID: String?
    public let unavailableReason: String?
    public let request: @MainActor (FileBrowserOperation) async throws -> FileBrowserResponse

    public init(id: String, paneID: String?, unavailableReason: String? = nil,
                request: @escaping @MainActor (FileBrowserOperation) async throws -> FileBrowserResponse) {
        self.id = id
        self.paneID = paneID
        self.unavailableReason = unavailableReason
        self.request = request
    }

    public static func remote(hostID: String, paneID: String?, connection: ViewerConnection?) -> Self {
        let reason: String? = if connection?.isHostConnected != true {
            "Host is offline. Reconnect to browse its files."
        } else if connection?.relayClient.hostSupportsFileBrowsing != true {
            "Update the Host Mac to browse files."
        } else { nil }
        return Self(id: hostID, paneID: paneID, unavailableReason: reason) { operation in
            if let reason { throw FileBrowserError.message(reason) }
            guard let connection, connection.isHostConnected else { throw FileBrowserError.message("Host is offline.") }
            try Task.checkCancellation()
            let response = try await connection.sendCommand(BrowseFiles(operation), paneId: paneID ?? "", timeout: 10).get()
            try Task.checkCancellation()
            guard let files = response.fileBrowser else { throw FileBrowserError.message("The Host returned no file data.") }
            return files
        }
    }
}
