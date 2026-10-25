import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentWorkflowInputGateTests {
    @MainActor
    final private class Barrier {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }

        func waitUntilEntered() async {
            while !entered {
                await Task.yield()
            }
        }
    }

    @Test
    func humanInputInvalidatesPreparationAndPausesBeforeWriting() async throws {
        var events: [String] = []
        let gate = AgentWorkflowInputGate { _ in events.append("pause") }
        let prepared = gate.claim(paneID: "%1")
        try await gate.human(paneID: "%1") { events.append("human") }
        await #expect(throws: (any Error).self) {
            try await gate.workflow(prepared) { events.append("unexpected workflow") }
        }
        #expect(events == ["pause", "human"])
    }

    @Test
    func humanInputDuringFinalInspectionPreventsAutomaticWrite() async throws {
        var events: [String] = []
        let barrier = Barrier()
        let gate = AgentWorkflowInputGate { _ in events.append("pause") }
        let claim = gate.claim(paneID: "%1")
        let automatic = Task {
            try await gate.workflow(claim) {
                await barrier.wait()
                try gate.validate(claim)
                events.append("unexpected workflow")
            }
        }
        await barrier.waitUntilEntered()
        let human = Task { try await gate.human(paneID: "%1") { events.append("human") } }
        while (try? gate.validate(claim)) != nil {
            await Task.yield()
        }
        barrier.release()
        await #expect(throws: (any Error).self) { try await automatic.value }
        try await human.value
        #expect(events == ["pause", "human"])
    }

    @Test
    func committedPasteAndEnterCannotInterleaveWithHumanKeys() async throws {
        var events: [String] = []
        let barrier = Barrier()
        let gate = AgentWorkflowInputGate { _ in events.append("pause") }
        let claim = gate.claim(paneID: "%1")
        let automatic = Task {
            try await gate.workflow(claim) {
                events.append("paste")
                await barrier.wait()
                events.append("submit")
            }
        }
        await barrier.waitUntilEntered()
        let human = Task { try await gate.human(paneID: "%1") { events.append("human") } }
        await Task.yield()
        #expect(events == ["paste"])
        barrier.release()
        try await automatic.value
        try await human.value
        #expect(events == ["paste", "submit", "pause", "human"])
    }

    @Test
    func independentPanesDoNotBlockEachOtherAndScrollDoesNotInvalidate() async throws {
        let gate = AgentWorkflowInputGate { _ in Issue.record("Scrolling must not pause") }
        let barrier = Barrier()
        let claim = gate.claim(paneID: "%1")
        let first = Task { try await gate.workflow(claim) { await barrier.wait() } }
        await barrier.waitUntilEntered()
        try await gate.human(paneID: "%2", editsInput: false) { }
        barrier.release()
        try await first.value
        try await gate.human(paneID: "%1", editsInput: false) { }
        try gate.validate(claim)
    }

    @Test
    func cancelledQueuedWriteNeverExecutesOrBlocksLaterInput() async throws {
        let gate = AgentWorkflowInputGate { _ in }
        let barrier = Barrier()
        let first = Task { try await gate.human(paneID: "%1") { await barrier.wait() } }
        await barrier.waitUntilEntered()
        let claim = gate.claim(paneID: "%1")
        let cancelled = Task { try await gate.workflow(claim) { Issue.record("Cancelled write executed") } }
        await Task.yield()
        cancelled.cancel()
        barrier.release()
        try await first.value
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await gate.human(paneID: "%1") { }
    }

    @Test(arguments: ["\u{1b}[I", "\u{1b}[O", "\u{1b}[<64;10;20M", "\u{1b}[<65;10;20M", "\u{1b}[<35;10;20M"])
    func passiveReportsAreNotEdits(_ input: String) {
        #expect(!AgentWorkflowInputGate.editsInput(Data(input.utf8)))
    }

    @Test(arguments: ["text", "\u{3}", "\u{1b}[<0;10;20M", "\u{1b}[<64;10;20Mextra", "\u{1b}[<64;10;20M\u{1b}[<0;10;20M"])
    func clicksAndUnknownReportsAreEdits(_ input: String) {
        #expect(AgentWorkflowInputGate.editsInput(Data(input.utf8)))
    }
}
