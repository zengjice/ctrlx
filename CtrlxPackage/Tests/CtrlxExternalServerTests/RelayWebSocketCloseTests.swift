import NIOCore
import NIOWebSocket
import Testing
import VaporTesting
@testable import CtrlxExternalServerLib

@Suite("Relay WebSocket close deadline")
struct RelayWebSocketCloseTests {
    @Test("A peer that ignores close is forcibly disconnected after the grace period")
    func unacknowledgedClose() throws {
        let channel = EmbeddedChannel(handler: RelayWebSocketCloseHandler())
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 8080)).wait()
        defer { _ = try? channel.finish(acceptAlreadyClosed: true) }

        // Ordinary outbound traffic must not start the close deadline.
        try channel.writeOutbound(WebSocketFrame(fin: true, opcode: .binary, data: channel.allocator.buffer(capacity: 0)))
        channel.embeddedEventLoop.advanceTime(by: .seconds(10))
        #expect(channel.isActive)

        try channel.writeOutbound(WebSocketFrame(fin: true, opcode: .connectionClose, data: channel.allocator.buffer(capacity: 0)))
        channel.embeddedEventLoop.advanceTime(by: .seconds(4))
        #expect(channel.isActive)
        // Repeated close frames must not extend the deadline.
        try channel.writeOutbound(WebSocketFrame(fin: true, opcode: .connectionClose, data: channel.allocator.buffer(capacity: 0)))
        channel.embeddedEventLoop.advanceTime(by: .seconds(1))
        #expect(!channel.isActive)
    }
}
