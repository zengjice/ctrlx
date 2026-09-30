import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxFeature

@Suite("Agent background monitoring policy")
struct AgentBackgroundMonitoringPolicyTests {
    @Test("A stale idle state does not complete a newly observed turn")
    func staleIdleDoesNotComplete() {
        #expect(
            AgentBackgroundMonitoringPolicy.decision(
                for: .idle,
                phase: .waitingForAgent
            ) == .keep(.waitingForAgent)
        )
    }

    @Test("Working then idle yields a terminal card update")
    func workingThenIdleCompletes() {
        let started = AgentBackgroundMonitoringPolicy.decision(
            for: .working,
            phase: .waitingForAgent
        )
        #expect(started == .keep(.working))
        #expect(
            AgentBackgroundMonitoringPolicy.decision(
                for: .idle,
                phase: .working
            ) == .terminal(.completed)
        )
    }

    @Test("Live terminal states remain authoritative when working was missed", arguments: [
        AgentState.doneWorking(summary: "done"),
        AgentState.awaitingPermission(
            PermissionRequest(title: "Shell", description: "Run pwd"),
            requestID: "permission"
        ),
    ])
    func terminalStateFinishes(_ state: AgentState) {
        guard case .terminal = AgentBackgroundMonitoringPolicy.decision(
            for: state,
            phase: .waitingForAgent
        ) else {
            Issue.record("Expected a terminal Agent presentation decision")
            return
        }
    }

    @Test("Meaningful foreground responses start monitoring")
    func eligibleResponses() {
        #expect(AgentBackgroundMonitoringPolicy.shouldStart(for: .prompt(text: "run tests")))
        #expect(AgentBackgroundMonitoringPolicy.shouldStart(for: .replyAfterStop(text: "continue")))
        #expect(!AgentBackgroundMonitoringPolicy.shouldStart(for: .prompt(text: " \n ")))
        #expect(!AgentBackgroundMonitoringPolicy.shouldStart(for: .replyAfterStop(text: "")))
        #expect(AgentBackgroundMonitoringPolicy.shouldStart(for: .approvePlan(
            decision: .approve,
            editedPlan: nil
        )))
    }

    @Test("Terminal input starts only after a meaningful line is submitted")
    func terminalInputAccumulation() {
        var input = AgentPromptInputAccumulator()

        let empty = input.consume([.space, .enter])
        let draft = input.consume([.text("run tests")])
        let submitted = input.consume([.enter])
        let repeatedEnter = input.consume([.enter])
        let cleared = input.consume([.text("discard me"), .ctrl("u")])
        let clearedEnter = input.consume([.enter])
        let embeddedNewline = input.consume([.text("continue\n")])
        let recalled = input.consume([.up, .enter])
        let cancelledRecall = input.consume([.up, .ctrl("u"), .enter])

        #expect(!empty)
        #expect(!draft)
        #expect(submitted)
        #expect(!repeatedEnter)
        #expect(!cleared)
        #expect(!clearedEnter)
        #expect(embeddedNewline)
        #expect(recalled)
        #expect(!cancelledRecall)
    }

    @Test("Clipboard newlines do not submit a prompt or consume the later Send")
    func pasteOnlyEditsDraft() {
        var input = AgentPromptInputAccumulator()
        input.recordPaste("first\r\nsecond\n")
        let navigation = input.consume([.left])
        let submitted = input.consume([.enter])
        let repeated = input.consume([.enter])
        #expect(!navigation)
        #expect(submitted)
        #expect(!repeated)
        input.recordPaste("discard\n")
        let cancelled = input.consume([.ctrl("u"), .enter])
        #expect(!cancelled)
        input.recordPaste(" \n\r\n")
        let whitespace = input.consume([.enter])
        #expect(!whitespace)
    }

    @Test("Non-blocking Agent states accept terminal prompts")
    func terminalPromptStates() {
        #expect(AgentBackgroundMonitoringPolicy.canSubmitPrompt(from: .idle))
        #expect(AgentBackgroundMonitoringPolicy.canSubmitPrompt(from: .doneWorking(summary: nil)))
        #expect(AgentBackgroundMonitoringPolicy.canSubmitPrompt(from: .working))
        #expect(!AgentBackgroundMonitoringPolicy.canSubmitPrompt(
            from: .awaitingPermission(
                PermissionRequest(title: "Shell", description: "Run pwd"),
                requestID: "permission"
            )
        ))
    }

    @Test("Monitoring activity has a finite two-hour budget")
    func finiteActivityBudget() {
        #expect(AgentBackgroundMonitoringPolicy.initialActivityUnits == 1)
        #expect(AgentBackgroundMonitoringPolicy.maximumActivityUnits == 720)
        #expect(AgentBackgroundMonitoringPolicy.nextActivityUnit(after: 0) == 1)
        #expect(AgentBackgroundMonitoringPolicy.nextActivityUnit(after: 718) == 719)
        #expect(AgentBackgroundMonitoringPolicy.nextActivityUnit(after: 719) == nil)
    }

    @Test("Foreground renewal restores a full activity window")
    func renewedActivityBudget() {
        let renewedLimit = AgentBackgroundMonitoringPolicy.renewedActivityUnitLimit(after: 360)

        #expect(renewedLimit == 1_080)
        #expect(AgentBackgroundMonitoringPolicy.nextActivityUnit(
            after: 719,
            limit: renewedLimit
        ) == 720)
        #expect(AgentBackgroundMonitoringPolicy.nextActivityUnit(
            after: 1_079,
            limit: renewedLimit
        ) == nil)
        #expect(
            AgentBackgroundMonitoringPolicy.renewedActivityUnitLimit(
                after: Int64.max - 1
            ) == Int64.max
        )
    }

    @Test("Snapshots avoid stale terminal state and remain host-throttled")
    func snapshotCadence() {
        let submittedAt = Date(timeIntervalSince1970: 1_000)

        #expect(!AgentBackgroundMonitoringPolicy.shouldRequestSnapshot(
            sessionStartedAt: submittedAt,
            lastSnapshotAt: nil,
            now: submittedAt.addingTimeInterval(4)
        ))
        #expect(AgentBackgroundMonitoringPolicy.shouldRequestSnapshot(
            sessionStartedAt: submittedAt,
            lastSnapshotAt: nil,
            now: submittedAt.addingTimeInterval(5)
        ))
        #expect(!AgentBackgroundMonitoringPolicy.shouldRequestSnapshot(
            sessionStartedAt: submittedAt,
            lastSnapshotAt: submittedAt.addingTimeInterval(10),
            now: submittedAt.addingTimeInterval(39)
        ))
        #expect(AgentBackgroundMonitoringPolicy.shouldRequestSnapshot(
            sessionStartedAt: submittedAt,
            lastSnapshotAt: submittedAt.addingTimeInterval(10),
            now: submittedAt.addingTimeInterval(40)
        ))
    }

    @Test("Delivery delay ignores negative wall-clock skew")
    func deliveryDelay() {
        let eventAt = Date(timeIntervalSince1970: 100)

        #expect(AgentBackgroundMonitoringPolicy.deliveryDelay(
            eventAt: eventAt,
            receivedAt: eventAt.addingTimeInterval(4)
        ) == 4)
        #expect(AgentBackgroundMonitoringPolicy.deliveryDelay(
            eventAt: eventAt,
            receivedAt: eventAt.addingTimeInterval(-1)
        ) == 0)
    }

    @Test("Terminal notification frames are deduplicated inside the race window")
    func notificationDeduplication() {
        let deliveredAt = Date(timeIntervalSince1970: 100)

        #expect(!AgentBackgroundMonitoringPolicy.isDuplicateNotification(
            lastDeliveredAt: nil,
            now: deliveredAt
        ))
        #expect(AgentBackgroundMonitoringPolicy.isDuplicateNotification(
            lastDeliveredAt: deliveredAt,
            now: deliveredAt.addingTimeInterval(4.999)
        ))
        #expect(!AgentBackgroundMonitoringPolicy.isDuplicateNotification(
            lastDeliveredAt: deliveredAt,
            now: deliveredAt.addingTimeInterval(5)
        ))
        #expect(!AgentBackgroundMonitoringPolicy.isDuplicateNotification(
            lastDeliveredAt: deliveredAt,
            now: deliveredAt.addingTimeInterval(-1)
        ))
    }

    @Test("Terminal updates emit notifications independently of task lifetime")
    func terminalNotificationOwnership() {
        #expect(AgentBackgroundMonitoringPolicy.shouldEmitTerminalNotification(
            reason: .completed,
            recoveredFromSnapshot: false
        ))
        #expect(!AgentBackgroundMonitoringPolicy.shouldEmitTerminalNotification(
            reason: .waitingForInput,
            recoveredFromSnapshot: false
        ))
        #expect(AgentBackgroundMonitoringPolicy.shouldEmitTerminalNotification(
            reason: .waitingForInput,
            recoveredFromSnapshot: true
        ))
    }
}
