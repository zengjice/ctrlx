#if os(macOS)
import AppKit
import CtrlxNetworking
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import CtrlxCommon

@MainActor
@Suite("Remote browser frame presentation", .serialized)
struct RemoteBrowserFrameDecodingTests {
    @Observable @MainActor
    final class State {
        var frame: RemoteBrowserFrame?
        var isAnnotating = false
        var image: CGImage?
        var displayedFrame: RemoteBrowserFrame?
        var observedFrame: RemoteBrowserFrame?
        var observedAnnotation: Bool?
    }

    private struct Surface: View {
        @Bindable var state: State
        var body: some View {
            Color.clear
                .modifier(RemoteBrowserFrameDecoding(frame: state.frame, isAnnotating: state.isAnnotating,
                                                     image: $state.image, displayedFrame: $state.displayedFrame))
                .onChange(of: state.isAnnotating, initial: true) { _, value in state.observedAnnotation = value }
                .onChange(of: state.frame, initial: true) { _, value in state.observedFrame = value }
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "Timed out waiting for SwiftUI frame presentation")
    }

    private func frame(width: Int, generation: UInt64) throws -> RemoteBrowserFrame {
        let bitmap = try #require(CGContext(data: nil, width: width, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: 4))
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(bitmap.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return RemoteBrowserFrame(jpeg: bytes as Data, width: Double(width), height: 4, generation: generation)
    }

    @Test(arguments: [UInt64(1), UInt64(2)])
    func leavingAnnotationPresentsLatestFrameWithoutAnotherPoll(generation: UInt64) async throws {
        _ = NSApplication.shared
        let state = State()
        let original = try frame(width: 4, generation: 1)
        let latest = try frame(width: 8, generation: generation)
        state.frame = original
        let hosting = NSHostingView(rootView: Surface(state: state))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 100, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        try await wait { state.displayedFrame == original }
        #expect(state.image?.width == 4)

        state.isAnnotating = true
        try await wait { state.observedAnnotation == true }
        state.frame = latest
        try await wait { state.observedFrame == latest }
        #expect(state.displayedFrame == original)

        // Host stays still: no further frame assignment or poll can wake decoding.
        state.isAnnotating = false
        try await wait { state.displayedFrame == latest }
        #expect(state.image?.width == 8)
        #expect(state.displayedFrame?.generation == generation)

        // Closing/disconnecting during annotation also clears stale presentation on exit.
        state.isAnnotating = true
        try await wait { state.observedAnnotation == true }
        state.frame = nil
        try await wait { state.observedFrame == nil }
        state.isAnnotating = false
        try await wait { state.displayedFrame == nil && state.image == nil }
    }
}
#endif
