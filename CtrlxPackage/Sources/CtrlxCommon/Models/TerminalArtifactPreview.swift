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

    public var newFilesLink: TerminalFileLinkRequest {
        .init(path: link.path, paneID: link.paneID, hostID: link.hostID, prefersPreview: false, opensNewTab: true)
    }

    public static func supports(path: String?) -> Bool {
        guard let path else { return false }
        return isMermaid(path: path) || isMarkdown(path: path) || isImage(path: path)
    }

    public static func isImage(path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
            .contains((path as NSString).pathExtension.lowercased())
    }

    public static func isMarkdown(path: String) -> Bool {
        ["md", "markdown"].contains((path as NSString).pathExtension.lowercased())
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
        if Self.isMarkdown(path: path) {
            guard
                data.count <= FileBrowserLimits.maximumTextBytes,
                let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
                throw FileBrowserError.message("Markdown previews require a UTF-8 file no larger than 512 KiB.")
            }
        }
        return data
    }

    /// Resolve document-relative URLs lexically; the Host then checks the real workspace boundary.
    public func documentLink(_ reference: String) throws -> TerminalFileLinkRequest {
        // Preserve existing escapes when a Markdown URL mixes Unicode and percent encoding.
        guard
            let encoded = reference.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(CharacterSet(charactersIn: "%#"))),
            let url = URLComponents(string: encoded), url.scheme == nil, url.host == nil,
            !url.path.isEmpty, !url.path.hasPrefix("/"), !url.path.contains("\\") else {
            throw FileBrowserError.message("Only files inside this workspace can be previewed.")
        }
        var parts = link.path.split(separator: "/").dropLast().map(String.init)
        for part in url.path.split(separator: "/") {
            if part == "." {
                continue
            }
            if part == ".." {
                guard !parts.isEmpty else { throw FileBrowserError.message("The link leaves this workspace.") }
                parts.removeLast()
            } else {
                parts.append(String(part))
            }
        }
        let path = parts.isEmpty ? "." : parts.joined(separator: "/")
        guard RepositoryFileLink.isValid(path: path) else { throw FileBrowserError.message("Invalid workspace-relative link.") }
        return .init(path: path, paneID: link.paneID, hostID: link.hostID)
    }

    public func loadDocumentImage(_ reference: String) async throws -> Data {
        let imageLink = try documentLink(reference)
        guard Self.isImage(path: imageLink.path) || (imageLink.path as NSString).pathExtension.lowercased() == "svg" else {
            throw FileBrowserError.message("This image format is not supported.")
        }
        let destination = try await TerminalFileDestination.resolve(path: imageLink.path, context: context, source: source)
        guard let path = destination.file else { throw FileBrowserError.message("The image link points to a folder.") }
        return try await Self(link: imageLink, context: context, source: source, path: path).load()
    }
}
