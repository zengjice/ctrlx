import Foundation
import Testing
@testable import CtrlxNetworking

struct SessionTabLayoutTests {
    @Test("A source group rejects changed membership and accepts a refreshed whole group", arguments: [false, true])
    func sourceGroupMembership(explicitPane: Bool) {
        let a = SessionTabID.window(UUID()), x = SessionTabID.file(UUID()), y = SessionTabID.file(UUID()), z = SessionTabID.browser(UUID())
        let catalog = [a, x, y, z], sources = [x: "%1", y: "%1", z: "%1"]
        var layout = SessionTabLayout(order: catalog, revision: 2, ordersGroups: true)
        let original = layout
        let stale = layout.apply(.moveGroup([x, y], before: nil, sourcePaneID: explicitPane ? "%1" : nil), catalog: catalog, sourcePanes: sources)
        #expect(!stale && layout == original)
        let fresh = layout.apply(.moveGroup([x, y, z], before: a, sourcePaneID: "%1"), catalog: catalog, sourcePanes: sources)
        #expect(fresh && layout.order == [x, y, z, a])
        #expect(layout.groups.isEmpty)
        let encoded = try? JSONEncoder().encode(SessionTabLayout.Edit.moveGroup([x, y, z], before: a, sourcePaneID: "%1"))
        #expect(encoded.flatMap { try? JSONDecoder().decode(SessionTabLayout.Edit.self, from: $0) } == .moveGroup([x, y, z], before: a, sourcePaneID: "%1"))
    }

    @Test("A stale group move cannot move departed members or a dissolved group", arguments: [2, 3], [false, true])
    func rejectsChangedGroup(size: Int, dissolve: Bool) {
        let a = SessionTabID.file(UUID()), end = SessionTabID.file(UUID()), group = UUID()
        let members = (0..<size).map { _ in SessionTabID.file(UUID()) }
        let catalog = [a] + members + [end]
        var layout = SessionTabLayout(order: catalog, groups: Dictionary(uniqueKeysWithValues: members.map { ($0, group) }))
        let changed = layout.apply(dissolve ? .ungroup(members[0]) : .moveToEnd(members[size - 1], after: end), catalog: catalog)
        #expect(changed)
        let before = layout
        let accepted = layout.apply(.moveGroup(members, before: a, groupID: group), catalog: catalog)
        #expect(!accepted && layout == before)
    }

    @Test("Moving a group preserves current membership and member order")
    func movingWholeGroup() throws {
        let a = SessionTabID.window(UUID()), b = SessionTabID.file(UUID()), c = SessionTabID.browser(UUID())
        let d = SessionTabID.window(UUID()), group = UUID()
        let catalog = [a, b, c, d]
        var layout = SessionTabLayout(order: catalog, groups: [b: group, c: group], revision: 4)
        let moved = layout.apply(.moveGroup([c, b], before: a), catalog: catalog)
        #expect(moved)
        #expect(layout.order == [b, c, a, d])
        #expect(layout.groups == [b: group, c: group])
        #expect(layout.ordersGroups == true)
        #expect(layout.revision == 5)
        let appended = layout.apply(.moveGroup([b, c], before: nil), catalog: catalog)
        #expect(appended)
        #expect(layout.order == [a, d, b, c])
        #expect(try JSONDecoder().decode(SessionTabLayout.self, from: JSONEncoder().encode(layout)) == layout)
    }

    @Test("Group moves reject incomplete membership and stale targets")
    func rejectsStaleGroupMove() {
        let a = SessionTabID.window(UUID()), b = SessionTabID.file(UUID()), c = SessionTabID.browser(UUID())
        let group = UUID(), catalog = [a, b, c]
        let original = SessionTabLayout(order: catalog, groups: [b: group, c: group])
        for edit: SessionTabLayout.Edit in [.moveGroup([b], before: a), .moveGroup([b, c], before: b), .moveGroup([b, c], before: .file(UUID())), .moveGroup([], before: a)] {
            var layout = original
            let applied = layout.apply(edit, catalog: catalog)
            #expect(!applied)
            #expect(layout == original)
        }
    }

    @Test("Older Host layouts do not advertise group ordering")
    func oldGroupOrderingCompatibility() throws {
        let data = try JSONSerialization.data(withJSONObject: ["order": [], "groups": [], "revision": 0])
        let old = try JSONDecoder().decode(SessionTabLayout.self, from: data)
        #expect(old.supportsGroupReordering == nil && old.ordersGroups == nil)
    }

    @Test
    func closingGroupMemberRestoresAutomaticGrouping() {
        let a = SessionTabID.file(UUID()), b = SessionTabID.window(UUID()), c = SessionTabID.file(UUID())
        let group = UUID()
        let layout = SessionTabLayout(order: [b, a, c], groups: [a: group, b: group], revision: 3)
        let visible = layout.reconciled(with: [a, c])
        #expect(visible.order == [a, c])
        #expect(visible.groups.isEmpty)
        #expect(visible.revision == 3)
    }

    @Test
    func movingToSectionEndUsesAnchorAndExtractsSingleMember() {
        let a = SessionTabID.file(UUID()), b = SessionTabID.window(UUID()), c = SessionTabID.file(UUID())
        let d = SessionTabID.browser(UUID())
        let group = UUID()
        let catalog = [a, b, c, d]
        var layout = SessionTabLayout(order: catalog, groups: [a: group, b: group, c: group])
        let moved = layout.apply(.moveToEnd(a, after: b), catalog: catalog)
        #expect(moved)
        #expect(layout.order == [b, a, c, d])
        #expect(layout.groups == [b: group, c: group])
    }

    @Test
    func mixedTabGroupsSurviveRoundTripAndMoveAsExpected() throws {
        let terminal = SessionTabID.window(UUID())
        let shell = SessionTabID.window(UUID())
        let file = SessionTabID.file(UUID())
        let browser = SessionTabID.browser(UUID())
        let catalog = [terminal, shell, file, browser]
        var layout = SessionTabLayout()

        let grouped = layout.apply(.group(terminal, with: [file, browser]), catalog: catalog)
        #expect(grouped)
        #expect(layout.order == [shell, file, browser, terminal])
        let group = try #require(layout.groups[terminal])
        #expect(layout.groups == [terminal: group, file: group, browser: group])

        let reordered = layout.apply(.move(terminal, before: browser), catalog: catalog)
        #expect(reordered)
        #expect(layout.groups[terminal] == group)
        #expect(layout.order == [shell, file, terminal, browser])
        let extracted = layout.apply(.move(terminal, before: shell), catalog: catalog)
        #expect(extracted)
        #expect(layout.groups[terminal] == nil)
        let dissolved = layout.apply(.ungroup(browser), catalog: catalog)
        #expect(dissolved)
        #expect(layout.groups.isEmpty)
        #expect(layout.revision == 4)
        #expect(try JSONDecoder().decode(SessionTabLayout.self, from: JSONEncoder().encode(layout)) == layout)
    }

    @Test
    func staleOrForeignIDsCannotChangeLayout() {
        let window = SessionTabID.window(UUID())
        let file = SessionTabID.file(UUID())
        let foreign = SessionTabID.window(UUID())
        let catalog = [window, file]
        var layout = SessionTabLayout(order: [file, window, foreign])
        let original = layout
        let grouped = layout.apply(.group(window, with: [file, foreign]), catalog: catalog)
        #expect(!grouped)
        let movedForeign = layout.apply(.move(foreign, before: file), catalog: catalog)
        #expect(!movedForeign)
        let movedBeforeForeign = layout.apply(.move(file, before: foreign), catalog: catalog)
        #expect(!movedBeforeForeign)
        #expect(layout == original)
        #expect(layout.ordered(catalog) == [file, window])
    }

    @Test
    func tabLayoutEditScopeIsOptionalOnTheWire() throws {
        let sessionID = UUID()
        let a = SessionTabID.window(UUID()), b = SessionTabID.window(UUID())
        let edit = SessionTabLayout.Edit.move(b, before: a)
        let request = EditSessionTabLayout(sessionID: sessionID, edit: edit, visibleWindows: [a, b])
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(EditSessionTabLayout.self, from: encoder.encode(request)) == request)
        let unscoped = EditSessionTabLayout(sessionID: sessionID, edit: edit)
        #expect(try decoder.decode(EditSessionTabLayout.self, from: encoder.encode(unscoped)).visibleWindows == nil)
    }

    @Test
    func moveGroupMembershipIsOptionalOnTheWire() throws {
        enum LegacyEdit: Codable, Equatable {
            case moveToEnd(SessionTabID, after: SessionTabID?)
        }

        let a = SessionTabID.file(UUID()), b = SessionTabID.file(UUID())
        let legacy = LegacyEdit.moveToEnd(a, after: b)
        let edit = SessionTabLayout.Edit.moveToEnd(a, after: b, groupMembership: .keep)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(SessionTabLayout.Edit.self, from: encoder.encode(legacy)) == .moveToEnd(a, after: b))
        let encoded = try encoder.encode(edit)
        #expect(try decoder.decode(SessionTabLayout.Edit.self, from: encoded) == edit)
        #expect(try decoder.decode(LegacyEdit.self, from: encoded) == legacy)
    }

    @Test
    func pairedSnapshotCarriesTheHostLayoutAndOlderSnapshotsDecode() throws {
        let id = UUID()
        let layout = SessionTabLayout(order: [.window(UUID())], revision: 3)
        let state = SessionStateMessage(pairId: "", paneStates: [:], sessionTabLayouts: [id: layout])
        let paired = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(state.withPairId("viewer")))
        #expect(paired.pairId == "viewer")
        #expect(paired.sessionTabLayouts == [id: layout])
        let older = SessionStateMessage(pairId: "older", paneStates: [:])
        #expect(try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(older)).sessionTabLayouts == nil)
    }
}
