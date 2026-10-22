#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing
    @testable import CtrlxCommon

    @MainActor
    @Suite("Browser annotation lifecycle", .serialized)
    struct BrowserAnnotationSurfaceTests {
        @Observable @MainActor
        final class State {
            var available = true
            var request: UUID?
            var appeared = false
            var captures = 0
        }

        private struct Surface: View {
            @Bindable var state: State

            var body: some View {
                BrowserAnnotationSurface(
                    capture: {
                        state.captures += 1
                        throw AgentImageError.message("Injected capture failure")
                    },
                    onEditingChanged: { editing in
                        if !editing {
                            state.request = nil
                        }
                    },
                    captureRequest: state.request
                ) {
                    Color.clear
                }
                .environment(\.browserAnnotationContext, BrowserAnnotationContext(
                    targets: [], isAvailable: state.available,
                    send: { _, _ in Issue.record("Must not send an image") },
                    didSend: { _ in Issue.record("Must not reveal an Agent") }
                ))
                .onAppear { state.appeared = true }
            }
        }

        private func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() {
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(condition(), "Timed out waiting for annotation lifecycle")
        }

        @Test(arguments: [false, true])
        func rejectedOrFailedCaptureReleasesTheRequestAndAllowsRetry(available: Bool) async throws {
            _ = NSApplication.shared
            let state = State()
            let hosting = NSHostingView(rootView: Surface(state: state))
            let window = NSWindow(
                contentRect: CGRect(x: -10_000, y: -10_000, width: 240, height: 180),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            try await wait { state.appeared }

            // A connection can disappear between the parent's click and the surface consuming it.
            state.available = available
            state.request = UUID()
            try await wait { state.request == nil }
            #expect(state.captures == (available ? 1 : 0))

            state.available = true
            state.request = UUID()
            try await wait { state.request == nil }
            #expect(state.captures == (available ? 2 : 1))
        }
    }
#endif
