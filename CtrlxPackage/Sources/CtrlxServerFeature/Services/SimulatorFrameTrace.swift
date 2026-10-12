#if os(macOS)
    import Foundation

    @MainActor
    final class SimulatorFrameTrace {
        struct Row: Encodable {
            let sourceSequence: UInt64?
            let sequence: UInt64?
            let sourceAt: Double?
            let capturedAt: Double?
            let copyReadyAt: Double?
            let workerSendingAt: Double?
            let clientReceivedAt: Double?
            let clientDecodedAt: Double?
            let receivedAt: Double
            let wordHex: String?
            let copiedWordHex: String?
            let decodedAt: Double?
            let decodeMs: Double?
            let seedBefore: UInt32?
            let seedAfter: UInt32?
            let copyDecodedAt: Double?
            let copyDecodeMs: Double?
        }

        struct Sample: Encodable {
            let historyLimit: Int
            let receivedFrames: Int
            let droppedRows: Int
            let rows: [Row]
        }

        private let limit: Int
        private var receivedFrames = 0
        private var rows: [Row] = []

        init(limit: Int = 6000) { self.limit = limit }

        func record(metadata: [String: Any], receivedAt: Double, deliveryTiming: [String: NSNumber]? = nil) {
            receivedFrames += 1
            guard rows.count < limit else { return }
            let trace = metadata["sourceFrameTrace"] as? [String: Any] ?? [:]
            rows.append(Row(
                sourceSequence: (metadata["sourceSequence"] as? NSNumber)?.uint64Value,
                sequence: (metadata["sequence"] as? NSNumber)?.uint64Value,
                sourceAt: (metadata["sourceReadyAt"] as? NSNumber)?.doubleValue,
                capturedAt: (metadata["capturedAt"] as? NSNumber)?.doubleValue,
                copyReadyAt: (metadata["copyReadyAt"] as? NSNumber)?.doubleValue,
                workerSendingAt: deliveryTiming?["workerSendingAt"]?.doubleValue,
                clientReceivedAt: deliveryTiming?["clientReceivedAt"]?.doubleValue,
                clientDecodedAt: deliveryTiming?["clientDecodedAt"]?.doubleValue,
                receivedAt: receivedAt,
                wordHex: trace["wordHex"] as? String, copiedWordHex: trace["copiedWordHex"] as? String,
                decodedAt: (trace["decodedAt"] as? NSNumber)?.doubleValue,
                decodeMs: (trace["decodeMs"] as? NSNumber)?.doubleValue,
                seedBefore: (trace["seedBefore"] as? NSNumber)?.uint32Value,
                seedAfter: (trace["seedAfter"] as? NSNumber)?.uint32Value,
                copyDecodedAt: (trace["copyDecodedAt"] as? NSNumber)?.doubleValue,
                copyDecodeMs: (trace["copyDecodeMs"] as? NSNumber)?.doubleValue))
        }

        func read() -> Sample {
            Sample(historyLimit: limit, receivedFrames: receivedFrames, droppedRows: receivedFrames - rows.count, rows: rows)
        }

        func reset() {
            receivedFrames = 0
            rows.removeAll(keepingCapacity: true)
        }
    }
#endif
