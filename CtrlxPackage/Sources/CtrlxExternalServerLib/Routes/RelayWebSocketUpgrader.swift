import CtrlxNetworking
import NIOCore
import NIOHTTP1
import NIOWebSocket
import Vapor

/// Vapor's convenience upgrader does not expose WebSocketKit's aggregation limits.
struct RelayWebSocketUpgrader: Upgrader {
    static let maximumFragments = 1024
    static let closeTimeout: TimeAmount = .seconds(5)
    static let pingInterval: TimeAmount = .seconds(30)

    let onUpgrade: @Sendable (WebSocket) -> Void

    func applyUpgrade(req: Request, res: Response) -> HTTPServerProtocolUpgrader {
        NIOWebSocketServerUpgrader(
            maxFrameSize: RelayPayloadLimits.maxWebSocketFrameBytes,
            automaticErrorHandling: false,
            shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture([:]) },
            upgradePipelineHandler: { channel, _ in
                var configuration = WebSocket.Configuration()
                configuration.maxAccumulatedFrameSize = RelayPayloadLimits.maxWebSocketFrameBytes
                configuration.maxAccumulatedFrameCount = Self.maximumFragments
                let limits = configuration
                return channel.eventLoop.submit {
                    try channel.pipeline.syncOperations.addHandler(RelayWebSocketCloseHandler())
                }.flatMap {
                    WebSocket.server(on: channel, config: limits) { socket in
                        socket.pingInterval = Self.pingInterval
                        onUpgrade(socket)
                    }
                }
            }
        )
    }
}

/// A close frame alone leaves the TCP channel alive when the peer never replies.
final class RelayWebSocketCloseHandler: ChannelDuplexHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let timeout: TimeAmount
    private var deadline: Scheduled<Void>?

    init(timeout: TimeAmount = RelayWebSocketUpgrader.closeTimeout) {
        self.timeout = timeout
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if unwrapOutboundIn(data).opcode == .connectionClose, deadline == nil {
            let channel = context.channel
            deadline = context.eventLoop.scheduleTask(in: timeout) {
                channel.close(promise: nil)
            }
        }
        context.write(data, promise: promise)
    }

    func channelInactive(context: ChannelHandlerContext) {
        deadline?.cancel()
        deadline = nil
        context.fireChannelInactive()
    }
}
