import Testing
@testable import CtrlxPluginProtocol

struct PluginIngressPeerTests {
    private func process(_ pid: Int32, parent: Int32, start: UInt64, user: UInt32 = 501) -> PluginIngressPeer.Process {
        .init(processID: pid, parentProcessID: parent, userID: user, startSeconds: start, startMicroseconds: 1)
    }

    @Test
    func validatesAncestorsWithPIDStartTimeAndUser() throws {
        let table: [Int32: PluginIngressPeer.Process] = [
            13: process(13, parent: 12, start: 300), 12: process(12, parent: 11, start: 200), 11: process(11, parent: 1, start: 100),
        ]
        let peer = try #require(PluginIngressPeer.capture(peerPID: 13, userID: 501, inspect: { table[$0] }))
        #expect(peer.contains(processID: 11, runtimeID: "501:11:100:1"))
        #expect(!peer.contains(processID: 11, runtimeID: "501:11:101:1"))
        #expect(!peer.contains(processID: 99, runtimeID: "501:99:100:1"))
    }

    @Test
    func rejectsReusedParentPIDAndForeignPeer() {
        let table: [Int32: PluginIngressPeer.Process] = [
            13: process(13, parent: 12, start: 200), 12: process(12, parent: 1, start: 300),
        ]
        #expect(PluginIngressPeer.capture(peerPID: 13, userID: 501, inspect: { table[$0] }) == nil)
        #expect(PluginIngressPeer.capture(peerPID: 13, userID: 502, inspect: { table[$0] }) == nil)
    }

    @Test
    func rejectsExitedOrReparentedHookDuringCapture() {
        var reads = 0
        let peer = PluginIngressPeer.capture(peerPID: 13, userID: 501) { pid in
            guard pid == 13 else { return nil }
            reads += 1
            return reads == 1 ? process(13, parent: 1, start: 200) : nil
        }
        #expect(peer == nil)
    }
}
