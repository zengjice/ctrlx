#if os(macOS) || os(iOS)
import Dependencies
import DependenciesMacros
import Foundation
import SwiftUI

#if os(macOS)
import AppKit

@DependencyClient
struct FileBrowserOpener: Sendable {
    var open: @MainActor @Sendable (URL) throws -> Void
    var showInFinder: @MainActor @Sendable (URL) -> Void
}

extension FileBrowserOpener: DependencyKey {
    static let liveValue = Self(open: { url in
        guard NSWorkspace.shared.open(url) else {
            throw FileBrowserError.message("No app could open this file. Install an app that supports its format.")
        }
    }, showInFinder: { url in
        NSWorkspace.shared.activateFileViewerSelecting([url])
    })
}
#else
import QuickLook
import UIKit
#endif

@MainActor
struct FileBrowserOpenActions: View {
    private enum Request: Equatable {
        case open(UUID)
        #if os(macOS)
        case showInFinder(UUID)
        #endif
    }

    let path: String
    let source: FileBrowserSource
    @State private var transfer = FileBrowserTransfer()
    @State private var request: Request?
    @State private var error: String?
    #if os(macOS)
    @Dependency(FileBrowserOpener.self) private var opener
    #else
    @State private var sharedFile: SharedFile?
    @State private var previewURL: URL?
    @State private var downloadedURL: URL?
    #endif

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { request = .open(UUID()) } label: {
                    Label(title, symbol: source.localFileURL == nil ? .arrowDownCircle : .arrowUpRightSquare)
                }
                .disabled(transfer.isPreparing || source.unavailableReason != nil)
                #if os(macOS)
                Button { request = .showInFinder(UUID()) } label: {
                    Label(source.localFileURL == nil ? "Download and Show in Finder" : "Open in Finder", symbol: .folder)
                }
                .disabled(transfer.isPreparing || source.unavailableReason != nil)
                .accessibilityIdentifier("file-show-in-finder")
                #endif
                #if os(iOS)
                if let url = downloadedURL {
                    Button { sharedFile = SharedFile(url: url) } label: { Label("Share / Open in…", symbol: .squareAndArrowUp) }
                }
                #endif
                if transfer.isPreparing {
                    Button("Cancel", role: .cancel) { request = nil }
                }
                Spacer()
            }
            if transfer.isPreparing, source.localFileURL == nil {
                ProgressView(value: Double(transfer.receivedBytes), total: Double(max(1, transfer.totalBytes)))
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(transfer.receivedBytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(transfer.totalBytes), countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .task(id: request) {
            guard let request else { return }
            do {
                let url = try await transfer.fileForOpening(path: path, source: source)
                try Task.checkCancellation()
                #if os(macOS)
                switch request {
                case .open: try opener.open(url)
                case .showInFinder: opener.showInFinder(url)
                }
                #else
                downloadedURL = url
                previewURL = url
                #endif
                self.request = nil
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .alert("Could Not Open File", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        #if os(iOS)
        .quickLookPreview($previewURL)
        .sheet(item: $sharedFile) { file in FileBrowserShareSheet(url: file.url) }
        #endif
    }

    private var title: String {
        #if os(macOS)
        source.localFileURL == nil ? "Download and Open" : "Open in Default App"
        #else
        "Download and Open"
        #endif
    }
}

#if os(iOS)
private struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
private struct FileBrowserShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
#endif
#endif
