import CoreGraphics
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@Suite("Browser annotation")
struct BrowserAnnotationTests {
    @MainActor @Test func revealRetryDoesNotResendScreenshotOrChangeRecipient() async throws {
        let delivery = BrowserAnnotationDelivery()
        let target = try recipient("%1")
        var sends = 0
        await #expect(throws: AgentImageError.self) {
            try await delivery.sendAndReveal(target: target, send: { sends += 1 }, reveal: { _ in
                throw AgentImageError.message("Terminal timed out")
            })
        }
        #expect(delivery.deliveredTarget == target)
        var revealed: AgentImageTarget?
        try await delivery.sendAndReveal(target: recipient("%2"), send: { sends += 1 }, reveal: { revealed = $0 })
        #expect(sends == 1)
        #expect(revealed == target)
    }

    @MainActor @Test func failedSendDoesNotRevealAndRetryCanSend() async throws {
        let delivery = BrowserAnnotationDelivery()
        let target = try recipient("%1")
        var reveals = 0
        await #expect(throws: AgentImageError.self) {
            try await delivery.sendAndReveal(target: target, send: { throw AgentImageError.message("Send failed") }, reveal: { _ in reveals += 1 })
        }
        #expect(delivery.deliveredTarget == nil)
        #expect(reveals == 0)
        try await delivery.sendAndReveal(target: target, send: {}, reveal: { _ in reveals += 1 })
        #expect(reveals == 1)
        #expect(delivery.deliveredTarget == target)
    }

    @MainActor @Test func cancellationAfterSendKeepsReceiptWithoutRevealing() async throws {
        let delivery = BrowserAnnotationDelivery()
        let target = try recipient("%1")
        var reveals = 0
        let task = Task {
            try await delivery.sendAndReveal(target: target, send: {
                withUnsafeCurrentTask { $0?.cancel() }
            }, reveal: { _ in reveals += 1 })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(delivery.deliveredTarget == target)
        #expect(reveals == 0)
        try await delivery.sendAndReveal(target: target, send: { Issue.record("Must not send twice") }, reveal: { _ in reveals += 1 })
        #expect(reveals == 1)
    }

    private func recipient(_ id: String) throws -> AgentImageTarget {
        try #require(AgentImageTarget(pane: PaneState(
            paneId: id, sessionName: "work", tmuxWindowId: "@2", windowName: "Agent",
            agentSession: AgentSession(paneId: id, pluginID: "codex"), claudeSessionID: "conversation-1"
        )))
    }

    @Test func coordinatesIgnoreLetterboxAndSurviveResizing() {
        let image = CGSize(width: 1000, height: 500)
        let view = CGSize(width: 400, height: 800)
        #expect(BrowserAnnotationMark.point(CGPoint(x: 200, y: 400), viewSize: view, imageSize: image) == CGPoint(x: 0.5, y: 0.5))
        #expect(BrowserAnnotationMark.point(CGPoint(x: 200, y: 100), viewSize: view, imageSize: image) == nil)
        #expect(BrowserAnnotationMark.point(CGPoint(x: 800, y: 800), viewSize: view, imageSize: image, clamp: true) == CGPoint(x: 1, y: 1))
        #expect(BrowserAnnotationMark.point(CGPoint(x: 400, y: 800), viewSize: CGSize(width: 800, height: 1600), imageSize: image) == CGPoint(x: 0.5, y: 0.5))
        #expect(BrowserAnnotationMark.point(.zero, viewSize: .zero, imageSize: image) == nil)
        #expect(BrowserAnnotationMark.point(CGPoint(x: CGFloat.nan, y: 0), viewSize: view, imageSize: image) == nil)
    }

    @Test(arguments: BrowserAnnotationTool.allCases)
    func renderingProducesBoundedReadableImage(tool: BrowserAnnotationTool) async throws {
        let context = try #require(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try #require(context.makeImage())
        let mark = BrowserAnnotationMark(tool: tool, points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.7, y: 0.6)])
        let result = try await BrowserAnnotationRenderer.prepare(image: image, marks: [mark])
        #expect(result.data.count <= SendDroppedFiles.maxRawBytes)
        #expect(result.format == .png)
        let decoded = try await BrowserAnnotationRenderer.decode(result.data)
        #expect(decoded.width == 200 && decoded.height == 100)
        let plain = try await BrowserAnnotationRenderer.prepare(image: image, marks: [])
        #expect(plain.data != result.data)
    }

    @Test func invalidCaptureIsRejected() async {
        await #expect(throws: AgentImageError.self) { try await BrowserAnnotationRenderer.decode(Data([1, 2, 3])) }
    }

    @Test func exportUsesTopLeftImageCoordinates() async throws {
        let bitmap = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = try #require(bitmap.makeImage())
        let result = try await BrowserAnnotationRenderer.prepare(image: image, marks: [
            BrowserAnnotationMark(tool: .pen, points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.2)])
        ])
        let decoded = try await BrowserAnnotationRenderer.decode(result.data)
        // ImageIO may return BGRA or RGB. Sample a known RGBA bitmap instead.
        bitmap.draw(decoded, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let pixels = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        // PNG row zero is the top row. A top annotation must not be vertically mirrored.
        let top = 20 * bitmap.bytesPerRow + 40 * 4
        let bottom = 80 * bitmap.bytesPerRow + 40 * 4
        #expect(pixels[top] > 200 && pixels[top + 1] < 100)
        #expect(pixels[bottom] > 200 && pixels[bottom + 1] > 200)
    }
}
