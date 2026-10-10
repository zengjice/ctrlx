#if os(macOS) || os(iOS)
import CtrlxNetworking
import Dependencies
import ImageIO
import PDFKit
import SwiftUI
import Textual
import UniformTypeIdentifiers

/// Host files on all three surfaces. Only a local source can supply a native URL.
@MainActor
public struct WorkspaceFileBrowserView: View {
    @Bindable private var tab: FileBrowserTab
    private let source: FileBrowserSource
    @FocusState private var searchFocused: Bool
    @Dependency(ClipboardClient.self) private var clipboard
    @Environment(\.scenePhase) private var scenePhase
    @State private var upload = FileBrowserUpload()
    @State private var uploadRequest: UploadRequest?
    @State private var destination: Destination?
    @State private var showsImporter = false
    @State private var showsFolderPrompt = false
    @State private var folderName = ""
    @State private var folderRequest: FolderRequest?
    @State private var actionMessage: String?

    private struct Destination {
        let path: String
        let source: FileBrowserSource
    }
    private struct UploadRequest: Identifiable {
        let id = UUID()
        let destination: Destination
        let urls: [URL]
    }
    private struct FolderRequest: Identifiable {
        let id = UUID()
        let destination: Destination
        let name: String
    }

    public init(tab: FileBrowserTab, source: FileBrowserSource) {
        self.tab = tab
        self.source = source
    }

    public var body: some View {
        VStack(spacing: 0) {
            navigation
            if upload.isRunning {
                HStack {
                    VStack(alignment: .leading) {
                        Text(upload.filename).lineLimit(1)
                        if let path = uploadRequest?.destination.path {
                            Text("To: \(path)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        ProgressView(value: Double(upload.sentBytes), total: Double(max(1, upload.totalBytes)))
                        Text("\(upload.sentBytes.formatted(.byteCount(style: .file))) / \(upload.totalBytes.formatted(.byteCount(style: .file)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Cancel") { uploadRequest = nil }
                }.padding(10)
            } else if let summary = upload.summary {
                ScrollView {
                    Text(summary).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.frame(maxHeight: 90)
            }
            if folderRequest != nil { ProgressView("Creating folder…").padding(10) }
            if let actionMessage { Text(actionMessage).font(.caption).textSelection(.enabled).padding(10) }
            Divider()
            #if os(macOS)
            HSplitView {
                directory.frame(minWidth: 200, idealWidth: 280)
                preview.frame(minWidth: 200, maxWidth: .infinity)
            }
            #else
            if tab.selectedFile == nil { directory }
            else { preview }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: tab.loadKey(source: source)) { await tab.load(source: source) }
        .task(id: previewKey) {
            await tab.loadPreview(source: source)
        }
        .task(id: uploadRequest?.id) {
            guard let request = uploadRequest else { return }
            await upload.run(urls: request.urls, directory: request.destination.path, source: request.destination.source) {
                tab.refresh += 1
            }
            if uploadRequest?.id == request.id { uploadRequest = nil }
        }
        .task(id: folderRequest?.id) { await createFolder() }
        .onDisappear {
            tab.releasePreview()
            // The iOS document picker can cover this view without closing its tab.
            if !showsImporter { cancelWrites() }
        }
        .onChange(of: source.unavailableReason) { _, reason in
            if reason != nil { cancelWrites() }
        }
        .onChange(of: source.id) { _, _ in cancelWrites() }
        .onChange(of: scenePhase) { _, phase in
            #if os(iOS)
            if phase == .background { cancelWrites() }
            #endif
        }
        .alert("New Folder", isPresented: $showsFolderPrompt) {
            TextField("Folder name", text: $folderName)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            Button("Cancel", role: .cancel) { destination = nil }
            Button("Create") {
                if let destination { folderRequest = .init(destination: destination, name: folderName) }
            }.disabled(!SessionDirectoryName.isValid(folderName))
        } message: {
            Text("Create in \(destination?.path ?? ""). Enter one folder name, without /.")
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            guard let target = destination, target.source.id == source.id, source.unavailableReason == nil else { return }
            destination = nil
            switch result {
            case let .success(urls):
                if !urls.isEmpty { uploadRequest = .init(destination: target, urls: urls) }
            case let .failure(error): actionMessage = error.localizedDescription
            }
        }
        .onChange(of: tab.searchFocusRequest, initial: true) { _, value in
            if value > 0 { searchFocused = true }
        }
    }

    private struct PreviewKey: Hashable {
        let path: String?
        let refresh: Int
        let sourceID: String
        let unavailable: String?
        let downloadUnavailable: String?
    }

    private var previewKey: PreviewKey {
        .init(path: tab.selectedFile, refresh: tab.refresh, sourceID: source.id,
              unavailable: source.unavailableReason, downloadUnavailable: source.downloadUnavailableReason)
    }

    private func updateSearch(query: String, mode: FileBrowserSearchMode) {
        #if os(iOS)
        tab.updateSearch(query: query, mode: mode, dismissPreview: true)
        #else
        tab.updateSearch(query: query, mode: mode, dismissPreview: false)
        #endif
    }

    private var navigation: some View {
        VStack(spacing: 8) {
            HStack {
                Button { tab.navigate(tab.path.map { ($0 as NSString).deletingLastPathComponent }) } label: {
                    Label("Up", symbol: .arrowUpCircleFill).labelStyle(.iconOnly)
                }
                .disabled(tab.path == nil || tab.path == "/")
                Button { tab.navigate(tab.homeDirectory) } label: { Label("Home", symbol: .house).labelStyle(.iconOnly) }
                TextField("Host directory", text: $tab.pathInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { tab.navigate(tab.pathInput) }
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                Button { tab.refresh += 1 } label: { Label("Refresh", symbol: .arrowClockwise).labelStyle(.iconOnly) }
                Menu {
                    Button {
                        guard captureDestination() else { return }
                        folderName = ""
                        showsFolderPrompt = true
                    } label: { Label("New Folder…", symbol: .folderBadgePlus) }
                    .accessibilityIdentifier("file-browser-new-folder")
                    .disabled(writesBusy || tab.path == nil || tab.isLoading || source.creationUnavailableReason != nil)
                    Button {
                        guard captureDestination() else { return }
                        showsImporter = true
                    } label: {
                        Label(source.localFileURL == nil ? "Upload Files…" : "Import Files…", symbol: .squareAndArrowUp)
                    }
                    .accessibilityIdentifier("file-browser-upload")
                    .disabled(writesBusy || tab.path == nil || tab.isLoading || source.uploadUnavailableReason != nil)
                    if let reason = source.creationUnavailableReason ?? source.uploadUnavailableReason {
                        Text(reason)
                    }
                    Divider()
                    if tab.sourcePaneID != nil {
                        Button { tab.navigate(nil) } label: { Label("Source Pane Directory", symbol: .terminal) }
                    }
                    Toggle("Show Hidden Files", isOn: $tab.includeHidden)
                    Button("Copy Directory Path") { if let path = tab.path { clipboard.setString(path) } }
                } label: { Label("File Browser Options", symbol: .ellipsisCircle).labelStyle(.iconOnly) }
            }
            HStack {
                TextField("Search files", text: Binding(
                    get: { tab.query },
                    set: { updateSearch(query: $0, mode: tab.searchMode) }
                )).textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                Picker("Search", selection: Binding(
                    get: { tab.searchMode },
                    set: { updateSearch(query: tab.query, mode: $0) }
                )) {
                    Text("Name").tag(FileBrowserSearchMode.name)
                    Text("Text").tag(FileBrowserSearchMode.content)
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(10)
        .disabled(source.unavailableReason != nil)
    }

    private var writesBusy: Bool { uploadRequest != nil || upload.isRunning || folderRequest != nil }

    private func captureDestination() -> Bool {
        guard let path = tab.path, !writesBusy, source.unavailableReason == nil else { return false }
        destination = Destination(path: path, source: source)
        actionMessage = nil
        return true
    }

    private func cancelWrites() {
        uploadRequest = nil
        folderRequest = nil
        destination = nil
        showsImporter = false
        showsFolderPrompt = false
    }

    private func createFolder() async {
        guard let request = folderRequest else { return }
        defer { if folderRequest?.id == request.id { folderRequest = nil; destination = nil } }
        do {
            guard let create = request.destination.source.createDirectory else {
                throw FileBrowserError.message("Update the Host Mac to create folders.")
            }
            try Task.checkCancellation()
            _ = try await create(.init(parentDirectory: request.destination.path, name: request.name))
            try Task.checkCancellation()
            guard folderRequest?.id == request.id else { return }
            actionMessage = "Created \(request.name) in \(request.destination.path)."
            if tab.path == request.destination.path { tab.query = ""; tab.selectedFile = nil }
            tab.refresh += 1
        } catch {
            if !Task.isCancelled, folderRequest?.id == request.id { actionMessage = error.localizedDescription }
        }
    }

    private var directory: some View {
        VStack(spacing: 0) {
            if let error = tab.error {
                Text(error).foregroundStyle(.secondary).padding().textSelection(.enabled)
            }
            if tab.isLoading { ProgressView().padding() }
            List {
                if let result = tab.searchResults {
                    ForEach(result.matches) { match in
                        VStack(alignment: .leading) {
                            row(match.entry)
                            Text(match.entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if let line = match.lineText {
                                Text("\(match.lineNumber ?? 0): \(line)").font(.caption.monospaced()).lineLimit(2)
                            }
                        }
                    }
                    if result.isTruncated { Text("Search limit reached. Narrow the directory or query.").font(.caption).foregroundStyle(.secondary) }
                    if result.matches.isEmpty { Text("No matches") }
                } else if let listing = tab.listing {
                    ForEach(listing.entries) { item in
                        FileBrowserTreeRow(item: item, tab: tab, source: source, depth: 0)
                    }
                    if listing.entries.isEmpty { Text("Empty folder").foregroundStyle(.secondary) }
                    if listing.nextOffset != nil {
                        Button("Load More") { Task { await tab.loadDirectory(listing.directory, more: true, source: source) } }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func row(_ item: FileBrowserEntry) -> some View {
        Button {
            if item.kind == .directory { tab.navigate(item.path) }
            else { tab.selectedFile = item.path }
        } label: {
            Label(item.name, symbol: item.kind == .directory ? .folder : .docPlaintextFill)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { Button("Copy Path") { clipboard.setString(item.path) } }
    }

    private var preview: some View {
        VStack(spacing: 0) {
            if let path = tab.selectedFile {
                HStack {
                    #if os(iOS)
                    Button { tab.selectedFile = nil } label: { Label("Files", symbol: .chevronLeft) }
                    #endif
                    Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Menu {
                        Button("Copy Path") { clipboard.setString(path) }
                        if let data = tab.previewData, tab.preview?.kind == .text || tab.preview?.kind == .markdown,
                           let text = String(data: data, encoding: .utf8) {
                            Button("Copy Text") { clipboard.setString(text) }
                        }
                        Button("Refresh Preview") { tab.refresh += 1 }
                    } label: { Label("File Actions", symbol: .ellipsisCircle).labelStyle(.iconOnly) }
                }.padding(10)
                Divider()
                FileBrowserOpenActions(path: path, source: source)
                    .id(OpenKey(path: path, sourceID: source.id, unavailable: source.unavailableReason,
                                downloadUnavailable: source.downloadUnavailableReason))
                if tab.isPreviewLoading { ProgressView().padding() }
                if let error = tab.previewError { Text(error).padding().textSelection(.enabled) }
                if FileBrowserOfficeDocument.supports(path: path) {
                    FileBrowserOfficePreview(path: path, source: source).id(previewKey)
                } else if source.localFileURL == nil, FileBrowserVideo.supports(path: path) {
                    FileBrowserVideoPreview(path: path, source: source).id(previewKey)
                } else {
                    #if os(macOS)
                    if let url = tab.previewURL {
                        FileBrowserMediaPreview(url: url).id(url)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let data = tab.previewData, let info = tab.preview {
                        FileBrowserPreview(data: data, kind: info.kind).id(info.path)
                    } else { Spacer() }
                    #else
                    if let data = tab.previewData, let info = tab.preview {
                        FileBrowserPreview(data: data, kind: info.kind).id(info.path)
                    } else { Spacer() }
                    #endif
                }
            } else {
                ContentUnavailableView("Select a File", symbol: .docPlaintextFill, description: "Preview files from the Host without downloading a folder.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct OpenKey: Hashable {
        let path: String
        let sourceID: String
        let unavailable: String?
        let downloadUnavailable: String?
    }
}

@MainActor
private struct FileBrowserTreeRow: View {
    let item: FileBrowserEntry
    @Bindable var tab: FileBrowserTab
    let source: FileBrowserSource
    let depth: Int
    @Dependency(ClipboardClient.self) private var clipboard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                #if os(macOS)
                if item.kind == .directory, depth < 20 {
                    Button {
                        if tab.expanded.contains(item.path) { tab.expanded.remove(item.path) }
                        else { tab.expanded.insert(item.path) }
                    } label: {
                        (tab.expanded.contains(item.path) ? Symbols.chevronDown : Symbols.chevronRight).image
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Expand \(item.name)")
                }
                #endif
                Button {
                    if item.kind == .directory { tab.navigate(item.path) }
                    else { tab.selectedFile = item.path }
                } label: {
                    Label(item.name, symbol: item.kind == .directory ? .folder : .docPlaintextFill)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .contextMenu { Button("Copy Path") { clipboard.setString(item.path) } }
            #if os(macOS)
            if tab.expanded.contains(item.path), depth < 20 {
                Group {
                    if let listing = tab.listings[item.path] {
                        ForEach(listing.entries) { child in
                            FileBrowserTreeRow(item: child, tab: tab, source: source, depth: depth + 1)
                        }
                        if listing.nextOffset != nil {
                            Button("Load More") { Task { await tab.loadDirectory(item.path, more: true, source: source) } }
                        }
                    } else {
                        Button("Load Folder") { Task { await tab.loadDirectory(item.path, more: false, source: source) } }
                    }
                }
                .padding(.leading, 16)
                .task(id: tab.listing?.revision) {
                    if tab.listings[item.path] == nil { await tab.loadDirectory(item.path, more: false, source: source) }
                }
            }
            #endif
        }
    }
}

private struct FileBrowserPreview: View {
    let data: Data
    let kind: FileBrowserKind
    @State private var image: CGImage?
    @State private var imageFailed = false
    var body: some View {
        Group {
            switch kind {
            case .text, .markdown:
                ScrollView([.vertical, .horizontal]) {
                    if kind == .markdown {
                        StructuredText(markdown: String(decoding: data, as: UTF8.self))
                            .textual.imageAttachmentLoader(FilePreviewAttachments())
                            .textual.emojiAttachmentLoader(FilePreviewAttachments())
                            .padding()
                    } else {
                        Text(String(decoding: data, as: UTF8.self)).font(.system(.body, design: .monospaced))
                            .textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            case .image:
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().padding()
                } else if imageFailed { Text("This image cannot be decoded.") }
                else { ProgressView() }
            case .pdf: FileBrowserPDF(data: data)
            default: Text("Preview unavailable")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: data) {
            guard kind == .image else { return }
            image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                ] as CFDictionary)
            }.value
            imageFailed = image == nil
        }
    }
}

/// A remote Markdown file must not silently fetch URLs or resolve file:// on the Viewer.
private struct FilePreviewAttachments: AttachmentLoader {
    func attachment(for url: URL, text: String, environment: ColorEnvironmentValues) async throws -> AnyAttachment {
        throw FileBrowserError.message("Open image files directly to preview attachments.")
    }
}

#if os(macOS)
private struct FileBrowserPDF: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; return view }
    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.data != data { view.document = PDFDocument(data: data); context.coordinator.data = data }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var data: Data? }
}
#else
private struct FileBrowserPDF: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; return view }
    func updateUIView(_ view: PDFView, context: Context) {
        if context.coordinator.data != data { view.document = PDFDocument(data: data); context.coordinator.data = data }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var data: Data? }
}
#endif
#endif
