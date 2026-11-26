import Foundation
import Testing
@testable import CtrlxCommon

struct PaneLinkedTabsTests {
    @Test("A shrinking manual group remains an anchor when it stays between unchanged rows")
    func shrinkingGroupRemainsStableAnchor() {
        let group = SessionTabGroup.manual(UUID())
        let current: [SessionTabEntry<String>] = [.tab("A"), .group(group, ["X", "Y", "Z"]), .tab("B")]
        let after: [SessionTabEntry<String>] = [.tab("A"), .group(group, ["Y", "Z"]), .group(.pane("P"), ["X"]), .tab("B")]
        let anchor = SessionTabEntry.insertionAnchor(for: "X", from: current, to: after)
        #expect(anchor?.row == .group(group) && anchor?.side == .after)
    }

    @Test("Restored groups can cross a terminal without changing their retained numeric slot")
    func dissolvedGroupsWithEqualIndex() {
        let current: [SessionTabEntry<String>] = [.group(.manual(UUID()), ["X", "Y"]), .tab("B"), .group(.pane("P"), ["S"]), .group(.pane("Q"), ["T"])]
        let after: [SessionTabEntry<String>] = [.group(.pane("Q"), ["Y", "T"]), .group(.pane("P"), ["X", "S"]), .tab("B")]
        #expect(SessionTabEntry.positionChanged(of: .group(.pane("P")), from: current, to: after))
        let anchor = SessionTabEntry.insertionAnchor(for: "X", from: current, to: after)
        #expect(anchor?.row == .tab("B") && anchor?.side == .before)
    }

    @Test("Dissolving the only row places a restored group on the corresponding side", arguments: [false, true])
    func insertionWithoutRetainedRows(toEnd: Bool) {
        let group = SessionTabGroup.manual(UUID())
        let current: [SessionTabEntry<String>] = [.group(group, ["X", "Y"])]
        let x = SessionTabEntry<String>.group(.pane("%1"), ["X"]), y = SessionTabEntry<String>.group(.pane("%2"), ["Y"])
        let projected = toEnd ? [y, x] : [x, y]
        let anchor = SessionTabEntry.insertionAnchor(for: "X", from: current, to: projected)
        #expect(anchor?.row == .group(group))
        #expect(anchor?.side == (toEnd ? .after : .before))
    }

    private let sources = ["fileA": "%1", "webA": "%1", "simA": "%1", "webB": "%2"]

    @Test("Mixed types stay adjacent, source order follows terminals, unbound tabs remain last")
    func groups() {
        let groups = PaneLinkedTabs.groups(items: ["fileA", "webB", "legacy", "simA", "webA", "fileA"], paneOrder: ["%2", "%1"]) { sources[$0] }
        #expect(groups.map(\.id) == ["%2", "%1", nil])
        #expect(groups.map(\.items) == [["webB"], ["fileA", "simA", "webA"], ["legacy"]])
    }

    @Test("Both boundaries return the exact source, never the neighboring group")
    func boundaries() {
        let groups = PaneLinkedTabs.groups(items: ["fileA", "webA", "simA", "webB"], paneOrder: ["%1", "%2"]) { sources[$0] }
        #expect(PaneLinkedTabs.adjacent(to: "fileA", direction: -1, groups: groups) == .sourcePane("%1"))
        #expect(PaneLinkedTabs.adjacent(to: "fileA", direction: 1, groups: groups) == .tab("webA"))
        #expect(PaneLinkedTabs.adjacent(to: "webA", direction: -1, groups: groups) == .tab("fileA"))
        #expect(PaneLinkedTabs.adjacent(to: "webA", direction: 1, groups: groups) == .tab("simA"))
        #expect(PaneLinkedTabs.adjacent(to: "simA", direction: 1, groups: groups) == .sourcePane("%1"))
        #expect(PaneLinkedTabs.adjacent(to: "webB", direction: -1, groups: groups) == .sourcePane("%2"))
        #expect(PaneLinkedTabs.adjacent(to: "webB", direction: 1, groups: groups) == .sourcePane("%2"))
    }

    @Test("Split columns use only visible group members; missing sources and legacy tabs are not rebound")
    func splitAndClosedSources() {
        let groups = PaneLinkedTabs.groups(items: ["webA", "legacy"], paneOrder: ["%2"]) { sources[$0] }
        #expect(groups.map(\.id) == ["%1", nil])
        #expect(PaneLinkedTabs.adjacent(to: "webA", direction: 1, groups: groups) == .sourcePane("%1"))
        #expect(PaneLinkedTabs.adjacent(to: "legacy", direction: 1, groups: groups) == nil)
        #expect(PaneLinkedTabs.adjacent(to: "removed", direction: 1, groups: groups) == nil)
    }

    @Test("Catalog arrival preserves cross-type order and appends new children")
    func catalogOrder() {
        #expect(PaneLinkedTabs.ordered(["fileA", "webA", "simA"], stored: ["webA", "missing", "fileA", "webA"]) == ["webA", "fileA", "simA"])
    }
}
