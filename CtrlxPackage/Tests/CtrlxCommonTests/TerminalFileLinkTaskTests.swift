#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing
    @testable import CtrlxCommon

    @MainActor
    @Suite("Terminal file link task", .serialized)
    struct TerminalFileLinkTaskTests {
        @Observable @MainActor
        final class State {
            var pending: TerminalFileLinkRequest?
            var handled = 0
            var appeared = false
        }

        private struct Surface: View {
            @Bindable var state: State

            var body: some View {
                Color.clear
                    .terminalFileLinkTask($state.pending) { _ in
                        state.handled += 1
                    }
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
            try #require(condition(), "Timed out waiting for the file-link task")
        }

        @Test
        func sameRequestRunsAgainAfterHandling() async throws {
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

            let request = TerminalFileLinkRequest(path: "docs/report.md", paneID: "%1", hostID: nil)
            state.pending = request
            try await wait { state.handled == 1 && state.pending == nil }

            state.pending = request
            try await wait { state.handled == 2 && state.pending == nil }
        }
    }
#endif
