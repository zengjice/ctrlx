#if os(macOS) || os(iOS)
import SwiftUI

#if os(macOS)
import Quartz
#else
import QuickLook
#endif

@MainActor
struct FileBrowserOfficePreview: View {
    let path: String
    let source: FileBrowserSource
    let capture: FilePreviewCapture
    @State private var transfer = FileBrowserTransfer()
    @State private var shouldLoad = true
    @State private var url: URL?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 8) {
            if let url {
                FileBrowserOfficeQuickLook(url: url, capture: capture).id(url)
            } else if let error {
                Text(error).padding().textSelection(.enabled)
            } else if shouldLoad {
                if transfer.totalBytes > 0 {
                    ProgressView(value: Double(transfer.receivedBytes), total: Double(transfer.totalBytes))
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(transfer.receivedBytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(transfer.totalBytes), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView("Loading Preview")
                }
                Button("Cancel", role: .cancel) { shouldLoad = false }
            } else {
                Text("Preview cancelled. Use Refresh Preview to try again.")
                    .padding().foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: shouldLoad) {
            guard shouldLoad else { return }
            do {
                let file = try await transfer.fileForOpening(path: path, source: source,
                    maximumRemoteBytes: FileBrowserOfficeDocument.maximumPreviewBytes)
                try Task.checkCancellation()
                url = file
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

#if os(macOS)
@MainActor
struct FileBrowserOfficeQuickLook: NSViewRepresentable {
    let url: URL
    let capture: FilePreviewCapture

    func makeNSView(context: Context) -> QLPreviewView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            preconditionFailure("Could not create the system Quick Look view")
        }
        view.shouldCloseWithWindow = false
        view.autostarts = false
        capture.bind(owner: context.coordinator.owner) { [weak view] in
            guard let view, view.previewItem != nil else { throw FileBrowserError.message("Wait for the Office preview to load.") }
            return .init(image: try FilePreviewCapture.snapshot(view), requiresVisibleContent: true)
        }
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        view.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var url: URL?; let owner = UUID() }
}
#else
@MainActor
struct FileBrowserOfficeQuickLook: UIViewControllerRepresentable {
    let url: URL
    let capture: FilePreviewCapture

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.reloadData()
        capture.bind(owner: context.coordinator.owner) { [weak controller] in
            guard let controller, controller.isViewLoaded, controller.currentPreviewItem != nil else {
                throw FileBrowserError.message("Wait for the Office preview to load.")
            }
            return .init(image: try FilePreviewCapture.snapshot(controller.view), requiresVisibleContent: true)
        }
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    static func dismantleUIViewController(_ controller: QLPreviewController, coordinator: Coordinator) {
        controller.dataSource = nil
        controller.delegate = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        var url: URL
        let owner = UUID()

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }

        nonisolated func previewController(_ controller: QLPreviewController,
                               editingModeFor previewItem: any QLPreviewItem) -> QLPreviewItemEditingMode {
            .disabled
        }

        nonisolated func previewController(_ controller: QLPreviewController, shouldOpen url: URL,
                               for previewItem: any QLPreviewItem) -> Bool {
            false
        }
    }
}
#endif
#endif
