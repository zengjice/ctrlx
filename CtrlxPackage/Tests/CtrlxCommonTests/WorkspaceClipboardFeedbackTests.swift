#if os(macOS)
    import AppKit
    import CtrlxNetworking
    import SwiftUI
    import Testing
    @testable import CtrlxCommon

    @MainActor
    @Suite("Workspace clipboard feedback", .serialized)
    struct WorkspaceClipboardFeedbackTests {
        @Observable @MainActor
        final class State {
            var message: String?
            var renderedMessage: String?
            var appeared = false
        }

        private struct Surface: View {
            @Bindable var state: State
            let isSimulator: Bool

            private var canvas: some View {
                RemoteBrowserCanvas(
                    image: nil,
                    frame: .init(
                        jpeg: Data([1]),
                        width: isSimulator ? 390 : 1_200,
                        height: isSimulator ? 844 : 900,
                        generation: 1
                    ),
                    acceptsInput: true,
                    keyboardRequested: false,
                    isSimulator: isSimulator,
                    send: { _ in }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            var body: some View {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 70)
                    if isSimulator {
                        GeometryReader { _ in
                            ZStack {
                                Color.black
                                canvas
                            }
                        }
                        .modifier(WorkspaceClipboardFeedback(message: state.message))
                    } else {
                        canvas.modifier(WorkspaceClipboardFeedback(message: state.message))
                    }
                }
                .onChange(of: state.message, initial: true) { _, message in
                    state.renderedMessage = message
                }
                .onAppear { state.appeared = true }
            }
        }

        private func canvas(in view: NSView) -> BrowserCanvasNSView? {
            if let canvas = view as? BrowserCanvasNSView {
                return canvas
            }
            return view.subviews.lazy.compactMap { canvas(in: $0) }.first
        }

        private func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() {
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(condition(), "Timed out waiting for clipboard feedback layout")
        }

        @Test(arguments: [CGSize(width: 1_000, height: 700), CGSize(width: 400, height: 850)], [false, true])
        func repeatedClipboardFeedbackPreservesCanvasAndPointerInput(size: CGSize, isSimulator: Bool) async throws {
            _ = NSApplication.shared
            let state = State()
            let hosting = NSHostingView(rootView: Surface(state: state, isSimulator: isSimulator))
            hosting.sizingOptions = []
            let window = NSWindow(
                contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            try await wait { state.appeared && (canvas(in: hosting)?.bounds.height ?? 0) > 0 }
            let canvas = try #require(canvas(in: hosting))
            #expect(window.makeFirstResponder(canvas))
            let bounds = canvas.bounds
            let canvasRect = canvas.convert(bounds, to: hosting)
            let pageRect = RemoteBrowserGeometry.imageRect(viewSize: bounds.size, pageSize: canvas.pageSize)
            let point = canvas.convert(CGPoint(x: bounds.midX, y: bounds.maxY - 20), to: hosting.superview)
            let baselineHit = hosting.hitTest(point) === canvas
            try #require(baselineHit, "The fixture must hit the page before showing feedback")

            let copied = isSimulator ? "Copied to this device." : "Copied."
            // Copy, copy/read again, paste, then clear feedback on the next interaction.
            for message in [copied, nil, copied, nil, "Paste sent.", nil, "Paste sent.", nil] as [String?] {
                state.message = message
                try await wait { state.renderedMessage == message }
                hosting.layoutSubtreeIfNeeded()
                #expect(canvas.bounds == bounds)
                #expect(canvas.convert(canvas.bounds, to: hosting) == canvasRect)
                #expect(RemoteBrowserGeometry.imageRect(viewSize: canvas.bounds.size, pageSize: canvas.pageSize) == pageRect)
                #expect(window.firstResponder === canvas)
                let passesThrough = hosting.hitTest(point) === canvas
                #expect(passesThrough, "The feedback must let page input pass through")
            }
        }
    }
#endif
