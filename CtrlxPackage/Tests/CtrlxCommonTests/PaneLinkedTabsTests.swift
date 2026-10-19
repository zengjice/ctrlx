import Testing
@testable import CtrlxCommon

struct PaneLinkedTabsTests {
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
