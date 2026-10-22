import CtrlxNetworking
import Foundation

/// A preview belongs to the clicked Host/pane, independently of the Files tab catalog.
@MainActor
public struct TerminalArtifactPreview: Identifiable {
    public let id = UUID()
    public let link: TerminalFileLinkRequest
    public let context: RepositoryFileContext
    public let source: FileBrowserSource
    public let path: String

    public init(link: TerminalFileLinkRequest, context: RepositoryFileContext, source: FileBrowserSource, path: String) {
        self.link = link
        self.context = context
        self.source = source
        self.path = path
    }

    public var filesLink: TerminalFileLinkRequest {
        .init(path: link.path, paneID: link.paneID, hostID: link.hostID, prefersPreview: false)
    }

    public static func supports(path: String?) -> Bool {
        guard let path else { return false }
        return isMermaid(path: path) || ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
            .contains((path as NSString).pathExtension.lowercased())
    }

    public static func isMermaid(path: String) -> Bool {
        ["mmd", "mermaid"].contains((path as NSString).pathExtension.lowercased())
    }

    /// Reuse bounded, revision-checked reads, then revalidate the source before presentation.
    public func load() async throws -> Data {
        let destination = try await TerminalFileDestination.resolve(path: link.path, context: context, source: source)
        guard destination.file == path else { throw FileBrowserError.message("The linked file changed. Open the link again.") }
        let tab = FileBrowserTab(path: destination.directory, sourcePaneID: link.paneID)
        tab.selectedFile = path
        await tab.loadPreview(source: source)
        try Task.checkCancellation()
        guard let data = tab.previewData, let info = tab.preview else {
            throw FileBrowserError.message(tab.previewError ?? "This file cannot be previewed.")
        }
        guard
            case let .info(current) = try await source.request(.repositoryInfo(path: link.path, context: context)),
            current.path == path, current.revision == info.revision else {
            throw FileBrowserError.message("The linked file changed. Open the link again.")
        }
        try Task.checkCancellation()
        if Self.isMermaid(path: path) {
            guard data.count <= 64 * 1_024, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
                throw FileBrowserError.message("Mermaid previews require a UTF-8 file no larger than 64 KiB.")
            }
        }
        return data
    }
}
