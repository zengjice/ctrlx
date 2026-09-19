import CtrlxNetworking
import Foundation

/// The form knows only its target and a read-only lookup, not local filesystem
/// APIs or connection routing. Each remote source is bound to one Host.
@MainActor
public struct SessionDirectorySource {
    public let id: String
    public let unavailableReason: String?
    public let list: @MainActor (ListSessionDirectories) async throws -> SessionDirectoryListing

    public init(
        id: String,
        unavailableReason: String? = nil,
        list: @escaping @MainActor (ListSessionDirectories) async throws -> SessionDirectoryListing
    ) {
        self.id = id
        self.unavailableReason = unavailableReason
        self.list = list
    }

    public static func remote(hostID: String, connection: ViewerConnection?, supportsBrowsing: Bool) -> Self {
        let reason: String? = if connection?.isHostConnected != true {
            "Host is offline. Reconnect to browse its directories."
        } else if !supportsBrowsing {
            "Update this Host to browse directories. You can still enter a path manually."
        } else {
            nil
        }
        return Self(id: hostID, unavailableReason: reason) { request in
            if let reason { throw LookupError.unavailable(reason) }
            guard let connection, connection.isHostConnected else {
                throw LookupError.unavailable("Host is offline. Reconnect to browse its directories.")
            }
            try Task.checkCancellation()
            let response = try await connection.sendCommand(request, paneId: "", timeout: 10).get()
            try Task.checkCancellation()
            guard let listing = response.directoryListing else {
                throw LookupError.unavailable("The Host did not return a directory listing. Update it and retry.")
            }
            return listing
        }
    }

    enum LookupError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case let .unavailable(message): message }
        }
    }
}

/// Value-state request ownership. A late reply cannot replace a newer query,
/// including A → B → A input, retry, or a switch to another Host.
struct SessionDirectoryBrowseState {
    struct Query: Equatable {
        let hostID: String
        let path: String
        let includeHidden: Bool
        let unavailableReason: String?
        var retry = 0
    }

    private(set) var query: Query?
    private(set) var requestID: UUID?
    private(set) var listing: SessionDirectoryListing?
    private(set) var error: String?
    private(set) var isLoading = false

    mutating func begin(_ query: Query) -> UUID {
        let id = UUID()
        self.query = query
        requestID = id
        listing = nil
        error = nil
        isLoading = true
        return id
    }

    mutating func finish(_ id: UUID, listing: SessionDirectoryListing) {
        guard requestID == id else { return }
        self.listing = listing
        isLoading = false
    }

    mutating func fail(_ id: UUID, message: String) {
        guard requestID == id else { return }
        error = message
        isLoading = false
    }
}
