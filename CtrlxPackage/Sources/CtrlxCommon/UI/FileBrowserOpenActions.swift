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
}

extension FileBrowserOpener: DependencyKey {
    static let liveValue = Self(open: { url in
        guard NSWorkspace.shared.open(url) else {
            throw FileBrowserError.message("No app could open this file. Install an app that supports its format.")
        }
    })
}
#else
import QuickLook
import UIKit
#endif

@MainActor
struct FileBrowserOpenActions: View {
    let path: String
    let source: FileBrowserSource
    @State private var transfer = FileBrowserTransfer()
    @State private var request: UUID?
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
                Button { request = UUID() } label: {
                    Label(title, symbol: source.localFileURL == nil ? .arrowDownCircle : .arrowUpRightSquare)
                }
                .disabled(transfer.isPreparing || source.unavailableReason != nil)
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
            guard request != nil else { return }
            do {
                let url = try await transfer.fileForOpening(path: path, source: source)
                try Task.checkCancellation()
                #if os(macOS)
                try opener.open(url)
                #else
                downloadedURL = url
                previewURL = url
                #endif
                request = nil
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
