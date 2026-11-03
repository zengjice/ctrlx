import CtrlxNetworking
import SwiftUI

@MainActor
public struct BrowserDownloadsButton: View {
    let downloads: [BrowserDownloadItem]
    let openTitle: String
    let open: (String) -> Void
    @State private var isPresented = false

    public init(downloads: [BrowserDownloadItem], openTitle: String = "Open in Files", open: @escaping (String) -> Void) {
        self.downloads = downloads
        self.openTitle = openTitle
        self.open = open
    }

    public var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 4) {
                Label("Downloads", symbol: .arrowDownCircle)
                if downloads.contains(where: \.isActive) {
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .labelStyle(.iconOnly)
        .help("Downloads on Host")
        .accessibilityIdentifier("browser-downloads")
        .accessibilityValue("\(downloads.filter(\.isActive).count) active, \(downloads.count) total")
        #if os(macOS)
            .popover(isPresented: $isPresented) { panel.frame(width: 380, height: 380) }
        #else
            .sheet(isPresented: $isPresented) {
                panel.presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        #endif
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Downloads on Host").font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
            }
            Text("Saved in the Host Mac’s Downloads folder. Closing the Browser tab cancels its active downloads.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(downloads.reversed()) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.filename).lineLimit(2)
                            if item.isActive {
                                if item.totalBytes > 0 {
                                    ProgressView(value: min(Double(item.receivedBytes) / Double(item.totalBytes), 1))
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                                Text(item.state == .saving ? "Saving…" : ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if item.state == .completed, let path = item.path {
                                Button(openTitle) {
                                    isPresented = false
                                    open(path)
                                }
                                .labelStyle(.titleAndIcon)
                            } else {
                                Text(item.error ?? (item.state == .cancelled ? "Cancelled" : "Download failed"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }
}
