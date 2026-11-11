#if os(macOS) || os(iOS)
    import Foundation
    import SwiftUI

    #if os(iOS)
        import QuickLook
        import UIKit
    #endif

    @MainActor
    struct FileBrowserOpenActions: View {
        let path: String
        let source: FileBrowserSource
        @Bindable var session: FileBrowserOpenSession
        #if os(iOS)
            @State private var sharedFile: SharedFile?
        #endif

        var body: some View {
            let transfer = session.transfer
            VStack(spacing: 8) {
                HStack {
                    Button { session.start(.open, path: path, source: source) } label: {
                        Label(title, symbol: source.localFileURL == nil ? .arrowDownCircle : .arrowUpRightSquare)
                    }
                    .disabled(session.isRunning || source.unavailableReason != nil)
                    .accessibilityIdentifier("file-download-open")
                    #if os(macOS)
                        Button { session.start(.showInFinder, path: path, source: source) } label: {
                            Label(source.localFileURL == nil ? "Download and Show in Finder" : "Open in Finder", symbol: .folder)
                        }
                        .disabled(session.isRunning || source.unavailableReason != nil)
                        .accessibilityIdentifier("file-show-in-finder")
                    #endif
                    #if os(iOS)
                        if let url = session.downloadedURL {
                            Button { sharedFile = SharedFile(url: url) } label: { Label("Share / Open in…", symbol: .squareAndArrowUp) }
                        }
                    #endif
                    if session.isRunning {
                        Button("Cancel", role: .cancel) { session.cancel() }
                            .accessibilityIdentifier("file-download-cancel")
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
            .alert("Could Not Open File", isPresented: Binding(get: { session.error != nil }, set: {
                if !$0 {
                    session.error = nil
                }
            })) {
                Button("OK", role: .cancel) { session.error = nil }
            } message: { Text(session.error ?? "") }
            #if os(iOS)
                .quickLookPreview($session.previewURL)
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
