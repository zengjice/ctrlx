import Foundation
import Testing
@testable import CtrlxNetworking

@Suite("Terminal stream lease commands")
struct TerminalStreamLeaseCommandTests {
    @Test("Modern stream commands preserve their lease")
    func modernRoundTrip() throws {
        let leaseId = UUID()
        let commands: [CommandType] = [
            .startTerminalStream(StartTerminalStream(leaseId: leaseId)),
            .stopTerminalStream(StopTerminalStream(leaseId: leaseId)),
        ]

        for command in commands {
            let decoded = try JSONDecoder().decode(
                CommandType.self,
                from: JSONEncoder().encode(command)
            )
            #expect(decoded == command)
        }
    }

    @Test("Legacy empty commands decode without a lease")
    func legacyEmptyPayload() throws {
        let encodedStart = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(StartTerminalStream()))
                as? [String: Any]
        )
        let encodedStop = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(StopTerminalStream()))
                as? [String: Any]
        )
        let start = try JSONDecoder().decode(
            StartTerminalStream.self,
            from: Data("{}".utf8)
        )
        let stop = try JSONDecoder().decode(
            StopTerminalStream.self,
            from: Data("{}".utf8)
        )

        #expect(encodedStart.isEmpty)
        #expect(encodedStop.isEmpty)
        #expect(start.leaseId == nil)
        #expect(stop.leaseId == nil)
    }

    @Test("Stream frames retain their lease and reject stale or missing leases on capable Hosts")
    func streamFrameIdentity() throws {
        let current = UUID()
        let stale = UUID()
        let updates: [TerminalStreamMessage.StreamUpdateType] = [
            .initialState(.init(width: 80, height: 24, content: Data())),
            .resetState(.init(width: 80, height: 24, content: Data())),
            .dataChunk(.init(data: Data("bytes".utf8))),
            .dimensionChange(.init(width: 90, height: 30)),
            .titleChange(.init(title: "title")),
            .notification(.init(body: "notice")),
            .clipboardUpdate(.init(content: "clipboard")),
            .streamEnd,
        ]
        for update in updates {
            let legacy = TerminalStreamMessage(paneId: "%0", updateType: update)
            let modern = legacy.withLeaseId(current)
            let decoded = try JSONDecoder().decode(TerminalStreamMessage.self, from: JSONEncoder().encode(modern))
            #expect(decoded.leaseId == current && decoded.id == legacy.id && decoded.updateType == update)
            #expect(decoded.matchesLease(current, requiresLease: true))
            #expect(!decoded.matchesLease(stale, requiresLease: true))
            #expect(!decoded.matchesLease(stale, requiresLease: false))
            #expect(!decoded.matchesLease(nil, requiresLease: false))
            let oldDecoded = try JSONDecoder().decode(TerminalStreamMessage.self, from: JSONEncoder().encode(legacy))
            #expect(oldDecoded.leaseId == nil)
            #expect(oldDecoded.matchesLease(current, requiresLease: false))
            #expect(!oldDecoded.matchesLease(current, requiresLease: true))
        }
        let state = SessionStateMessage(pairId: "old", paneStates: [:], supportsTerminalStreamIdentity: true)
        let decoded = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(state.withPairId("new")))
        #expect(decoded.pairId == "new" && decoded.supportsTerminalStreamIdentity == true)
        let oldState = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(SessionStateMessage(pairId: "old", paneStates: [:])))
        #expect(oldState.supportsTerminalStreamIdentity == nil)
    }
}
