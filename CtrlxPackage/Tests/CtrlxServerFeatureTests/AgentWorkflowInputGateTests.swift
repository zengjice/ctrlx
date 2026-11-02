import ConcurrencyExtras
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
    func authorizedHumanInputInvalidatesPreparationBeforeWriting() async throws {
        var events: [String] = []
        let gate = AgentWorkflowInputGate { _ in .init() }
        let prepared = gate.claim(paneID: "%1")
        try await gate.human(paneID: "%1") { _ in events.append("human") }
        await #expect(throws: (any Error).self) {
            try await gate.workflow(prepared) { events.append("unexpected workflow") }
        }
        #expect(events == ["human"])
    }

    @Test
    func humanInputDuringFinalInspectionPreventsAutomaticWrite() async throws {
        var events: [String] = []
        let barrier = Barrier()
        let gate = AgentWorkflowInputGate { _ in .init() }
        let claim = gate.claim(paneID: "%1")
        let automatic = Task {
            try await gate.workflow(claim) {
                await barrier.wait()
                try gate.validate(claim)
                events.append("unexpected workflow")
            }
        }
        await barrier.waitUntilEntered()
        let human = Task { try await gate.human(paneID: "%1") { _ in events.append("human") } }
        while (try? gate.validate(claim)) != nil {
            await Task.yield()
        }
        barrier.release()
        await #expect(throws: (any Error).self) { try await automatic.value }
        try await human.value
        #expect(events == ["human"])
    }

    @Test
    func committedPasteAndEnterCannotInterleaveWithHumanKeys() async throws {
        var events: [String] = []
        let barrier = Barrier()
        let gate = AgentWorkflowInputGate { _ in .init() }
        let claim = gate.claim(paneID: "%1")
        let automatic = Task {
            try await gate.workflow(claim) {
                events.append("paste")
                await barrier.wait()
                events.append("submit")
            }
        }
        await barrier.waitUntilEntered()
        let human = Task { try await gate.human(paneID: "%1") { _ in events.append("human") } }
        await Task.yield()
        #expect(events == ["paste"])
        barrier.release()
        try await automatic.value
        try await human.value
        #expect(events == ["paste", "submit", "human"])
    }

    @Test
    func independentPanesDoNotBlockEachOtherAndScrollDoesNotInvalidate() async throws {
        let gate = AgentWorkflowInputGate { _ in
            Issue.record("Scrolling must not pause")
            return .init()
        }
        let barrier = Barrier()
        let claim = gate.claim(paneID: "%1")
        let first = Task { try await gate.workflow(claim) { await barrier.wait() } }
        await barrier.waitUntilEntered()
        try await gate.human(paneID: "%2", editsInput: false) { _ in }
        barrier.release()
        try await first.value
        try await gate.human(paneID: "%1", editsInput: false) { _ in }
        try gate.validate(claim)
    }

    @Test
    func cancelledQueuedWriteNeverExecutesOrBlocksLaterInput() async throws {
        let gate = AgentWorkflowInputGate { _ in .init() }
        let barrier = Barrier()
        let first = Task { try await gate.human(paneID: "%1") { _ in await barrier.wait() } }
        await barrier.waitUntilEntered()
        let claim = gate.claim(paneID: "%1")
        let cancelled = Task { try await gate.workflow(claim) { Issue.record("Cancelled write executed") } }
        await Task.yield()
        cancelled.cancel()
        barrier.release()
        try await first.value
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await gate.human(paneID: "%1") { _ in }
    }

    @Test
    func rejectedInputDoesNotInvalidatePreparedWorkflow() async throws {
        let gate = AgentWorkflowInputGate { _ in throw AgentWorkflowInputReadOnlyError() }
        let claim = gate.claim(paneID: "%1")
        await #expect(throws: AgentWorkflowInputReadOnlyError.self) {
            try await gate.human(paneID: "%1") { _ in Issue.record("Read-only input was sent") }
        }
        try gate.validate(claim)
        try await gate.workflow(claim) { }
    }

    @Test
    func queuedEditRechecksOwnershipBeforeWriting() async throws {
        let readOnly = LockIsolated(false)
        let gate = AgentWorkflowInputGate { _ in
            if readOnly.value {
                throw AgentWorkflowInputReadOnlyError()
            }
            return .init()
        }
        let barrier = Barrier()
        let claim = gate.claim(paneID: "%1")
        let first = Task { try await gate.workflow(claim) { await barrier.wait() } }
        await barrier.waitUntilEntered()
        let queued = Task {
            try await gate.human(paneID: "%1") { _ in Issue.record("Input was sent after workflow resumed") }
        }
        while gate.claim(paneID: "%1").generation == claim.generation {
            await Task.yield()
        }
        readOnly.setValue(true)
        barrier.release()
        try await first.value
        await #expect(throws: AgentWorkflowInputReadOnlyError.self) { try await queued.value }
    }

    @Test(arguments: [
        "\u{1b}[I", "\u{1b}[O", "\u{1b}[<64;10;20M", "\u{1b}[<65;10;20M", "\u{1b}[<35;10;20M",
        "\u{1b}[<64;10;20M\u{1b}[<65;10;20M", "\u{1b}[I\u{1b}[<35;10;20M\u{1b}[O",
        String(repeating: "\u{1b}[<64;10;20M", count: 12),
    ])
    func passiveReportsAreNotEdits(_ input: String) {
        #expect(!AgentWorkflowInputGate.editsInput(Data(input.utf8)))
    }

    @Test(arguments: [
        "text", "\u{3}", "\u{1b}[<0;10;20M", "\u{1b}[<64;10;20Mextra", "\u{1b}[<64;10;20M\u{1b}[<0;10;20M",
        "\u{1b}[Itext", "text\u{1b}[I", "\u{1b}[<64;10;20M\u{1b}[", "\u{1b}[<-1;10;20M",
    ])
    func clicksAndUnknownReportsAreEdits(_ input: String) {
        #expect(AgentWorkflowInputGate.editsInput(Data(input.utf8)))
    }
}
