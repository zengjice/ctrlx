import CtrlxNetworking
import Foundation

struct SessionDirectoryCreationState {
    struct Request: Identifiable {
        let id = UUID()
        let hostID: String
        let path: String
        let command: CreateSessionDirectory
    }

    private(set) var request: Request?
    private(set) var error: String?
    var isCreating: Bool { request != nil }

    mutating func begin(hostID: String, path: String, parentDirectory: String, name: String) -> Request? {
        guard request == nil, SessionDirectoryName.isValid(name) else { return nil }
        let request = Request(hostID: hostID, path: path, command: .init(parentDirectory: parentDirectory, name: name))
        self.request = request
        error = nil
        return request
    }

    // The filesystem mutation may finish after leaving the form. It must not
    // navigate a new Host/path or turn into a session launch.
    mutating func finish(_ id: UUID, directory: String, hostID: String, path: String) -> String? {
        guard let request, request.id == id else { return nil }
        self.request = nil
        return request.hostID == hostID && request.path == path ? directory : nil
    }

    mutating func fail(_ id: UUID, message: String, hostID: String, path: String) {
        guard let request, request.id == id else { return }
        self.request = nil
        if request.hostID == hostID && request.path == path { error = message }
    }

    mutating func cancel() { request = nil }
}
