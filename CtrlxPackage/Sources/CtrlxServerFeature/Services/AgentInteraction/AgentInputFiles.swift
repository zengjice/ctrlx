import Foundation

actor AgentInputFiles {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func create(_ text: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
