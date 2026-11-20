import Foundation
import Testing
@testable import CtrlxNetworking

struct SessionTabLayoutTests {
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
