import CoreGraphics
import Foundation
import Testing
@testable import CtrlxCommon

#if os(macOS)
import AppKit
import SwiftUI
#endif

@MainActor
struct FilePreviewCaptureTests {
    @Test func unavailablePreviewFailsWithoutCapturingSomethingElse() async {
        await #expect(throws: FileBrowserError.self) {
            try await FilePreviewCapture().capture(filename: "/Host/report.xlsx")
        }
    }

    @Test func captionSharesOnlyTheFilenameAndKnownLocation() {
        #expect(FilePreviewCapture.caption(filename: "/Users/private/报告.docx", detail: nil) == "报告.docx")
        #expect(FilePreviewCapture.caption(filename: "/Host/report.pdf", detail: "Page 3") == "report.pdf · Page 3")
        #expect(FilePreviewCapture.caption(filename: "/Host/movie.mp4", detail: "Time 00:00:12") == "movie.mp4 · Time 00:00:12")
    }

    @Test func captureIsOnDemandAndOldCleanupCannotRemoveNewProvider() async throws {
        let capture = FilePreviewCapture()
        let old = UUID(), current = UUID()
        let image = try makeImage()
        var calls = 0
        capture.bind(owner: old) { throw FileBrowserError.message("Old preview must not be used") }
        capture.bind(owner: current) { calls += 1; return .init(image: image, detail: "Page 2") }
        capture.unbind(owner: old)
        #expect(calls == 0)
        let bytes = try await capture.capture(filename: "report.pdf")
        #expect(calls == 1)
        let decoded = try await BrowserAnnotationRenderer.decode(bytes)
        #expect(decoded.width == 200 && decoded.height == 144)
        capture.unbind(owner: current)
        await #expect(throws: FileBrowserError.self) { try await capture.capture(filename: "report.pdf") }
        #expect(calls == 1)
    }

    @Test func lateCaptureCannotReplaceANewerFile() async throws {
        let capture = FilePreviewCapture()
        let image = try makeImage()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let (gate, release) = AsyncStream<Void>.makeStream()
        capture.bind(owner: UUID()) {
            signal.yield()
            for await _ in gate { break }
            return .init(image: image)
        }
        let pending = Task { try await capture.capture(filename: "old.docx") }
        for await _ in started { break }
        capture.bind(owner: UUID()) { .init(image: image) }
        release.yield()
        await #expect(throws: CancellationError.self) { try await pending.value }
        _ = try await capture.capture(filename: "new.pptx")
    }

    @Test func cancellationNeverExportsLatePreview() async throws {
        let capture = FilePreviewCapture()
        let image = try makeImage()
        capture.bind(owner: UUID()) {
            withUnsafeCurrentTask { $0?.cancel() }
            return .init(image: image)
        }
        let pending = Task { try await capture.capture(filename: "report.xlsx") }
        await #expect(throws: CancellationError.self) { try await pending.value }
    }

    @Test func largeCaptureIsBoundedAndCanUseExistingAnnotationExport() async throws {
        let image = try makeImage(width: 3000, height: 1500)
        let data = try await FilePreviewCapture.encode(.init(image: image), filename: "picture.png")
        let decoded = try await BrowserAnnotationRenderer.decode(data)
        #expect(decoded.width == 2560 && decoded.height == 1324)
        let result = try await BrowserAnnotationRenderer.prepare(image: decoded, marks: [
            .init(tool: .rectangle, points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)]),
        ])
        #expect(result.data.count <= 512 * 1024)
    }

    @Test(arguments: [nil, 0.0, 0.5, 1.0] as [Double?])
    func officeCaptureRejectsTransparentAndSolidFrames(background: Double?) async throws {
        let context = try #require(CGContext(data: nil, width: 800, height: 640, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if let background {
            context.setFillColor(CGColor(gray: background, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 640))
        }
        let image = try #require(context.makeImage())
        await #expect(throws: FileBrowserError.self) {
            try await FilePreviewCapture.encode(.init(image: image, requiresVisibleContent: true), filename: "report.docx")
        }
        // Blank images are valid for other preview types. The guard is Office-only.
        _ = try await FilePreviewCapture.encode(.init(image: image), filename: "plain.png")
    }

    @Test func officeCaptureChecksEveryFrameBeforeAddingCaption() async throws {
        let context = try #require(CGContext(data: nil, width: 800, height: 640, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Quick Look can draw a white page with transparent side margins before
        // drawing the document. Margins alone must not count as content.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 80, y: 0, width: 640, height: 640))
        let blank = try #require(context.makeImage())
        let current = OfficeFrame(image: blank)
        let capture = FilePreviewCapture()
        capture.bind(owner: UUID()) { .init(image: current.image, requiresVisibleContent: true) }
        await #expect(throws: FileBrowserError.self) { try await capture.capture(filename: "report.docx") }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 140, y: 500, width: 3, height: 12))
        current.image = try #require(context.makeImage())
        let visible = try await BrowserAnnotationRenderer.decode(capture.capture(filename: "report.docx"))
        #expect(visible.width == 800 && visible.height == 684)

        current.image = blank
        await #expect(throws: FileBrowserError.self) { try await capture.capture(filename: "report.docx") }
        capture.bind(owner: UUID()) { .init(image: blank, requiresVisibleContent: true) }
        await #expect(throws: FileBrowserError.self) { try await capture.capture(filename: "next.pptx") }
    }

    @MainActor private final class OfficeFrame {
        var image: CGImage
        init(image: CGImage) { self.image = image }
    }

    #if os(macOS)
    @Observable @MainActor
    final class ScrollState {
        var atBottom = false
        var appeared = false
    }

    private struct ScrollPreview: View {
        let capture: FilePreviewCapture
        @Bindable var state: ScrollState

        var body: some View {
            FilePreviewSnapshotView(capture: capture) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            Color(red: 1, green: 0, blue: 0).frame(height: 400).id(0)
                            Color(red: 0, green: 1, blue: 0).frame(height: 400).id(1)
                        }
                    }
                    .onAppear { state.appeared = true }
                    .onChange(of: state.atBottom) { _, bottom in proxy.scrollTo(bottom ? 1 : 0, anchor: .bottom) }
                }
            }
            .padding(20)
            .background(Color.blue)
        }
    }

    @Test func nativeCaptureFollowsScrollAndExcludesSurroundingViews() async throws {
        _ = NSApplication.shared
        let capture = FilePreviewCapture()
        let state = ScrollState()
        let hosting = NSHostingView(rootView: ScrollPreview(capture: capture, state: state))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 240, height: 180),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !state.appeared, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(state.appeared)
        hosting.layoutSubtreeIfNeeded()

        let first = try await BrowserAnnotationRenderer.decode(capture.capture(filename: "preview.txt"))
        #expect(first.width == Int(200 * window.backingScaleFactor))
        #expect(first.height == Int(140 * window.backingScaleFactor) + 44)
        let top = try #require(NSBitmapImageRep(cgImage: first).colorAt(x: 5, y: 5)?.usingColorSpace(.deviceRGB))
        #expect(top.redComponent > 0.8 && top.blueComponent < 0.2, "First capture pixel: \(top)")

        state.atBottom = true
        let scrollDeadline = ContinuousClock.now + .seconds(2)
        var changed = false
        repeat {
            try await Task.sleep(for: .milliseconds(10))
            let latest = try await BrowserAnnotationRenderer.decode(capture.capture(filename: "preview.txt"))
            let pixel = try #require(NSBitmapImageRep(cgImage: latest).colorAt(x: 5, y: 5)?.usingColorSpace(.deviceRGB))
            changed = pixel.greenComponent > 0.4 && pixel.redComponent < 0.3
        } while !changed && ContinuousClock.now < scrollDeadline
        #expect(changed, "Capture must follow the mounted preview's scroll position, not recreate its first viewport")
    }
    #endif

    private func makeImage(width: Int = 200, height: Int = 100) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
