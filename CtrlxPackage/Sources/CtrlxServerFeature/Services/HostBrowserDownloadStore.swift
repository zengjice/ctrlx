import Foundation

/// CEF writes into private staging directories; only finished files are published.
actor HostBrowserDownloadStore {
    private let directory: URL
    private var staging: [UUID: URL] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    static func filename(_ suggested: String) -> String {
        let name = (suggested as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "_")
            .components(separatedBy: .controlCharacters).joined()
        guard !name.isEmpty, name != ".", name != ".." else { return "Download" }
        guard name.count > 180 else { return name }
        let suffix = (name as NSString).pathExtension
        guard !suffix.isEmpty, suffix.count < 179 else { return String(name.prefix(180)) }
        let base = (name as NSString).deletingPathExtension
        return String(base.prefix(179 - suffix.count)) + ".\(suffix)"
    }

    func prepare(_ id: UUID) throws -> String {
        let folder = directory.appendingPathComponent(".ctrlx-download-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        staging[id] = folder
        return folder.appendingPathComponent("partial.download").path
    }

    func complete(_ id: UUID, filename: String) throws -> String {
        guard let folder = staging[id] else { throw CocoaError(.fileNoSuchFile) }
        let file = folder.appendingPathComponent("partial.download")
        // Preserve normal macOS downloaded-file handling, including Gatekeeper.
        try (file as NSURL).setResourceValue([
            "LSQuarantineType": "LSQuarantineTypeWebDownload",
            "LSQuarantineAgentName": "CtrlX",
            "LSQuarantineTimeStamp": Date(),
        ], forKey: .quarantinePropertiesKey)
        let name = Self.filename(filename)
        let base = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        var index = 1
        while true {
            let candidate = index == 1 ? name : "\(base)-\(index)" + (suffix.isEmpty ? "" : ".\(suffix)")
            let destination = directory.appendingPathComponent(candidate)
            do {
                try FileManager.default.moveItem(at: file, to: destination)
                try discard(id)
                return destination.path
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                index += 1
            }
        }
    }

    func discard(_ id: UUID) throws {
        guard let folder = staging[id] else { return }
        try FileManager.default.removeItem(at: folder)
        staging[id] = nil
    }
}
