import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

/// Opt-in, real filesystem comparison. Timings are evidence, not CI thresholds.
@MainActor
struct HostFilesPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_FILES_PERFORMANCE"] == "1"))
    func localFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-files-performance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<1_200 {
            try Data().write(to: root.appendingPathComponent("file\(index).txt"))
        }
        let image = root.appendingPathComponent("preview.png")
        let contents = Data(repeating: 65, count: FileBrowserLimits.maximumPreviewBytes)
        try contents.write(to: image)
        let host = HostFileBrowser()
        var reads = 0
        let source = FileBrowserSource(
            id: "local",
            paneID: nil,
            localFileURL: { try await host.localFileURL($0) },
            localPreview: { try await host.localPreview($0) }
        ) {
            if case .read = $0 {
                reads += 1
            }
            return try await host.request($0)
        }
        let tab = FileBrowserTab(path: root.path)
        tab.selectedFile = image.path
        let clock = ContinuousClock()
        func milliseconds(_ start: ContinuousClock.Instant) -> Double {
            let duration = start.duration(to: clock.now).components
            return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1E15
        }
        var previews: [Double] = []
        var directories: [Double] = []
        for _ in 0..<5 {
            let start = clock.now
            await tab.loadPreview(source: source)
            previews.append(milliseconds(start))
            #expect(tab.previewData == contents)
            #expect(tab.previewError == nil)
            tab.releasePreview()
        }
        for _ in 0..<5 {
            let start = clock.now
            var offset = 0
            var count = 0
            repeat {
                guard case let .listing(page) = try await host.request(.list(path: root.path, offset: offset, includeHidden: false)) else {
                    Issue.record("Missing directory page")
                    return
                }
                count += page.entries.count
                offset = page.nextOffset ?? 0
            } while offset > 0
            directories.append(milliseconds(start))
            #expect(count == 1_201)
        }
        let result: [String: Any] = [
            "preview8MiB_ms": previews, "previewChunkRequests": reads,
            "directory1201Entries_ms": directories,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("HOST_FILES_PERFORMANCE \(String(decoding: data, as: UTF8.self))")
    }
}
