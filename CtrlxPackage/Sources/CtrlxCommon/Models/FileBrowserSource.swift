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
    public let downloadUnavailableReason: String?
    public let uploadUnavailableReason: String?
    public let creationUnavailableReason: String?
    public let createDirectory: (@MainActor (CreateSessionDirectory) async throws -> String)?
    /// Only local Host sources provide this. Remote paths must never become Viewer file URLs.
    public let localFileURL: (@MainActor (FileBrowserEntry) async throws -> URL)?
    public let request: @MainActor (FileBrowserOperation) async throws -> FileBrowserResponse

    public init(id: String, paneID: String?, unavailableReason: String? = nil,
                downloadUnavailableReason: String? = nil,
                uploadUnavailableReason: String? = nil,
                creationUnavailableReason: String? = nil,
                createDirectory: (@MainActor (CreateSessionDirectory) async throws -> String)? = nil,
                localFileURL: (@MainActor (FileBrowserEntry) async throws -> URL)? = nil,
                request: @escaping @MainActor (FileBrowserOperation) async throws -> FileBrowserResponse) {
        self.id = id
        self.paneID = paneID
        self.unavailableReason = unavailableReason
        self.downloadUnavailableReason = downloadUnavailableReason
        self.uploadUnavailableReason = uploadUnavailableReason
        self.creationUnavailableReason = creationUnavailableReason ?? (createDirectory == nil ? "Folder creation is unavailable on this Host." : nil)
        self.createDirectory = createDirectory
        self.localFileURL = localFileURL
        self.request = request
    }

    public static func remote(hostID: String, paneID: String?, connection: ViewerConnection?) -> Self {
        let reason: String? = if connection?.isHostConnected != true {
            "Host is offline. Reconnect to browse its files."
        } else if connection?.relayClient.hostSupportsFileBrowsing != true {
            "Update the Host Mac to browse files."
        } else { nil }
        let downloadReason = reason ?? (connection?.relayClient.hostSupportsFileDownloads == true ? nil : "Update the Host Mac to download files.")
        let uploadReason = reason ?? (connection?.relayClient.hostSupportsFileUploads == true ? nil : "Update the Host Mac to upload files.")
        let creationReason = reason ?? (connection?.relayClient.hostSupportsDirectoryCreation == true ? nil : "Update the Host Mac to create folders.")
        let epoch = connection?.relayClient.fileTransferEpoch
        let inputBinding: ViewerWorkspaceInputBinding? = if let paneID, !paneID.isEmpty {
            connection?.relayClient.workspaceInputState.binding(paneID: paneID) ?? .unavailable
        } else {
            nil
        }
        return Self(id: hostID, paneID: paneID, unavailableReason: reason, downloadUnavailableReason: downloadReason,
                    uploadUnavailableReason: uploadReason, creationUnavailableReason: creationReason, createDirectory: { request in
            if let creationReason { throw FileBrowserError.message(creationReason) }
            guard let connection, connection.isHostConnected, connection.relayClient.fileTransferEpoch == epoch else {
                throw FileBrowserError.message("Host connection changed. Try again.")
            }
            try Task.checkCancellation()
            let response = try await connection.sendCommand(request, paneId: "", timeout: 10).get()
            guard let directory = response.createdDirectory else { throw FileBrowserError.message("Missing created directory. Refresh before retrying.") }
            return directory
        }) { operation in
            if let reason { throw FileBrowserError.message(reason) }
            guard let connection, connection.isHostConnected else { throw FileBrowserError.message("Host is offline.") }
            if case .upload = operation {
                if let uploadReason { throw FileBrowserError.message(uploadReason) }
                guard connection.relayClient.fileTransferEpoch == epoch else { throw FileBrowserError.message("Upload connection changed. Choose the files again.") }
            }
            try Task.checkCancellation()
            let binding = operation.usesSourcePane ? inputBinding : nil
            let response = try await connection.relayClient.sendCommand(BrowseFiles(operation), paneId: paneID ?? "", timeout: 10, inputBinding: binding).get()
            try Task.checkCancellation()
            if let binding, let paneID {
                _ = try binding.expectedPane(current: connection.relayClient.workspaceInputState.binding(paneID: paneID))
            }
            guard let files = response.fileBrowser else { throw FileBrowserError.message("The Host returned no file data.") }
            return files
        }
    }
}
