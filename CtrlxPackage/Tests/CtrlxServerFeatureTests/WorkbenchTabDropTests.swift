import Foundation
import Testing
@testable import CtrlxServerFeature

@Suite
@MainActor
struct WorkbenchTabDropTests {
    @Test(arguments: ["session", "host", "both"], [TabDragPayload.window("@1"), .file(UUID()), .browser(UUID())])
    func incompatibleDropIsConsumedWithoutMovingOrReordering(scope: String, tab: TabDragPayload) {
        var rejected = 0
        var transfers = 0
        var reorders = 0
        let destination = WorkbenchTabContext(
            workspaceID: UUID(), hostID: "host-a", sessionName: "work",
            onRejected: { rejected += 1 },
            receive: { _, _, _ in transfers += 1
                return true
            }
        )
        let drag = WorkbenchTabDrag(
            workspaceID: UUID(), hostID: scope == "session" ? "host-a" : "host-b",
            sessionName: scope == "host" ? "work" : "other", tab: tab
        )

        #expect(destination.drop(drag, before: nil, rightSide: false) {
            reorders += 1
            return true
        })
        #expect(rejected == 1)
        #expect(transfers == 0 && reorders == 0)
    }

    @Test(arguments: [nil, "viewer-host"] as [String?])
    func rejectedSessionMergePreservesBothWorkspaces(hostID: String?) throws {
        let manager = DetachedTerminalWindows()
        let first = try #require(DetachedTerminalTarget(hostID: hostID, windowID: "@1"))
        let second = try #require(DetachedTerminalTarget(hostID: hostID, windowID: "@2"))
        let session: (DetachedTerminalTarget) -> String? = { $0 == first ? "one" : "two" }
        let source = try #require(manager.detach(first, position: nil, session: session))
        let target = try #require(manager.detach(second, position: nil, session: session))
        var notices = 0
        let destination = WorkbenchTabContext(
            workspaceID: target.id, hostID: hostID, sessionName: "two", onRejected: { notices += 1 },
            receive: { drag, _, _ in manager.transfer(drag, to: target.id, session: session) }
        )
        let drag = WorkbenchTabDrag(workspaceID: source.id, hostID: hostID, sessionName: "one", tab: .window("@1"))

        #expect(destination.drop(drag, before: .window("@2"), rightSide: true) { false })
        #expect(notices == 1)
        #expect(manager.workspaces.count == 2)
        #expect(source.members == [first] && target.members == [second])
        #expect(source.selection == .window("@1") && target.selection == .window("@2"))
    }

    @Test(arguments: [false, true])
    func matchingSessionStillTransfersToRequestedPosition(succeeded: Bool) {
        var transfers = 0
        let sourceID = UUID()
        let destination = WorkbenchTabContext(
            workspaceID: UUID(), hostID: nil, sessionName: "work",
            onRejected: { Issue.record("Valid transfer was rejected") },
            receive: { drag, before, right in
                transfers += 1
                #expect(drag.workspaceID == sourceID && drag.tab == .window("@1"))
                #expect(before == .window("@2") && right)
                return succeeded
            }
        )
        let drag = WorkbenchTabDrag(workspaceID: sourceID, hostID: nil, sessionName: "work", tab: .window("@1"))
        #expect(destination.drop(drag, before: .window("@2"), rightSide: true) {
            Issue.record("Cross-window transfer reached local reordering")
            return false
        } == succeeded)
        #expect(transfers == 1)
    }

    @Test(arguments: [nil, UUID()] as [UUID?])
    func sameWorkspaceKeepsLocalReordering(workspaceID: UUID?) {
        var reorders = 0
        let context = WorkbenchTabContext(
            workspaceID: workspaceID, hostID: nil, sessionName: "work",
            onRejected: { Issue.record("Local reordering was rejected") },
            receive: { _, _, _ in Issue.record("Local reordering reached transfer")
                return false
            }
        )
        #expect(context.drop(context.drag(.window("@1")), before: .window("@2"), rightSide: false) {
            reorders += 1
            return true
        })
        #expect(reorders == 1)
    }
}
