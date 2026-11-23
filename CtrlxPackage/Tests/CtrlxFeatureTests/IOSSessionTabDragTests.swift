import CoreTransferable
import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxFeature

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct IOSSessionTabDragTests {
    @Test("A tab drop commits the expected edit with missing or replaced hover state", arguments: [false, true], [false, true])
    func commitsActualDrop(group: Bool, replacedHover: Bool) async throws {
        let fixture = Fixture()
        let drag = IOSSessionTabDrag.begin(hostID: "host", sessionID: fixture.sessionID, tab: fixture.source)
        defer { IOSSessionTabDrag.active = nil }
        let provider = NSItemProvider()
        provider.register(drag)
        if replacedHover {
            _ = IOSSessionTabDrag.begin(hostID: "host", sessionID: fixture.sessionID, tab: fixture.target)
        } else {
            IOSSessionTabDrag.active = nil
        }
        let hoverID = IOSSessionTabDrag.active?.id

        let result = try await perform(fixture.drop, provider: provider, position: group ? 22 : 40)
        let expected: SessionTabLayout.Edit = group ? .group(fixture.source, with: [fixture.target]) : .moveToEnd(fixture.source, after: fixture.target)
        guard case let .success(.shared(edit)) = result else {
            Issue.record("Expected a shared layout edit, got \(result)")
            return
        }
        #expect(edit == expected)
        #expect(IOSSessionTabDrag.active?.id == hoverID)

        var layout = fixture.drop.layout
        let applied = layout.apply(edit, catalog: [fixture.source, fixture.target])
        #expect(applied)
        #expect(layout.order == [fixture.target, fixture.source])
        if group {
            #expect(layout.groups[fixture.source] != nil && layout.groups[fixture.source] == layout.groups[fixture.target])
        } else {
            #expect(layout.groups.isEmpty)
        }
    }

    @Test("A drop from a different Host or session reports a rejection", arguments: [false, true])
    func rejectsDifferentSession(differentHost: Bool) async throws {
        let fixture = Fixture()
        let drag = IOSSessionTabDrag.begin(
            hostID: differentHost ? "other" : "host", sessionID: differentHost ? fixture.sessionID : UUID(), tab: fixture.source
        )
        IOSSessionTabDrag.active = nil
        let provider = NSItemProvider()
        provider.register(drag)

        let result = try await perform(fixture.drop, provider: provider, position: 22)
        #expect(result == .failure(.differentSession))
    }

    @Test("An outside tab joins on the header and receives guidance on a member row", arguments: [false, true])
    func dropsOnGroup(header: Bool) async throws {
        let fixture = Fixture(destination: header ? .groupHeader : .groupMember)
        let drag = IOSSessionTabDrag.begin(hostID: "host", sessionID: fixture.sessionID, tab: fixture.source)
        IOSSessionTabDrag.active = nil
        let provider = NSItemProvider()
        provider.register(drag)

        let result = try await perform(fixture.drop, provider: provider, position: 22)
        if header {
            let members = fixture.drop.layout.order.filter { $0 != fixture.source }
            #expect(result == .success(.shared(.group(fixture.source, with: members))))
        } else {
            #expect(result == .failure(.outsideGroup))
            #expect(IOSSessionTabDrop.Rejection.outsideGroup.localizedDescription.contains("group header"))
        }
    }

    @Test("Groups containing private Files explain rejection on both the header and member rows", arguments: [false, true])
    func rejectsMixedGroup(header: Bool) async throws {
        let fixture = Fixture()
        let paneID = "%1"
        let sharedFile = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: paneID, initialDirectory: "/Shared"))
        let privateFile = FileBrowserTab(path: "/Private", sourcePaneID: paneID)
        let tabs = IOSPaneLinkedTabs(
            files: [sharedFile, privateFile], browsers: [], simulators: [], windows: fixture.drop.tabs.windows, storedOrder: []
        )
        let group = try #require(tabs.sharedEntries(fixture.drop.layout).first { $0.sourcePaneID == paneID })
        let sharedID = SessionTabID.file(sharedFile.id)
        #expect(Set(group.tabs) == [sharedID, .file(privateFile.id)])
        let drop = IOSSessionTabDrop(
            hostID: "host", sessionID: fixture.sessionID, tabs: tabs, layout: fixture.drop.layout,
            topLevelOrder: [], isConnected: true,
            destination: header ? .group(group.tabs) : .row(sharedID, members: group.tabs)
        )
        let drag = IOSSessionTabDrag.begin(hostID: "host", sessionID: fixture.sessionID, tab: fixture.source)
        defer { IOSSessionTabDrag.active = nil }
        let provider = NSItemProvider()
        provider.register(drag)

        let result = try await perform(drop, provider: provider, position: 22)
        #expect(result == .failure(.privateFiles))
        #expect(IOSSessionTabDrop.Rejection.privateFiles.localizedDescription.contains("private Files tab"))
    }

    @Test("The center of a private Files row explains grouping rejection while its edge allows sorting")
    func dropsOnPrivateFilesRow() async throws {
        let fixture = Fixture()
        let file = FileBrowserTab(path: "/Private")
        let privateID = SessionTabID.file(file.id)
        let tabs = IOSPaneLinkedTabs(files: [file], browsers: [], simulators: [], windows: fixture.drop.tabs.windows, storedOrder: [])
        let layout = fixture.drop.layout
        let drop = IOSSessionTabDrop(
            hostID: "host", sessionID: fixture.sessionID, tabs: tabs, layout: layout, topLevelOrder: [],
            isConnected: true, destination: .row(privateID, members: nil)
        )
        let drag = IOSSessionTabDrag.begin(hostID: "host", sessionID: fixture.sessionID, tab: fixture.target)
        defer { IOSSessionTabDrag.active = nil }
        let provider = NSItemProvider()
        provider.register(drag)

        let center = try await perform(drop, provider: provider, position: 22)
        #expect(center == .failure(.privateFiles))

        let edge = try await perform(drop, provider: provider, position: 40)
        guard case let .success(.moveTopLevel(order)) = edge else {
            Issue.record("Expected an edge drop to reorder tabs, got \(edge)")
            return
        }
        #expect(tabs.sharedEntries(layout, topLevelOrder: order).flatMap(\.tabs) == [fixture.source, privateID, fixture.target])
    }

    @Test("Pane-group members report invalid sorting drops and preserve valid drops")
    func paneGroupDrops() async throws {
        let fixture = Fixture()
        let paneID = "%1"
        let sharedFile = FileBrowserTab(hostTab: .init(sessionName: "work", sourcePaneID: paneID, initialDirectory: "/Shared"))
        let privateFile = FileBrowserTab(path: "/Private", sourcePaneID: paneID)
        let tabs = IOSPaneLinkedTabs(
            files: [sharedFile, privateFile], browsers: [], simulators: [], windows: fixture.drop.tabs.windows, storedOrder: []
        )
        let group = try #require(tabs.sharedEntries(fixture.drop.layout).first { $0.sourcePaneID == paneID })
        let sharedID = SessionTabID.file(sharedFile.id)
        let privateID = SessionTabID.file(privateFile.id)
        #expect(group.tabs == [sharedID, privateID])

        func drop(on destination: IOSSessionTabDrop.Destination) -> IOSSessionTabDrop {
            IOSSessionTabDrop(
                hostID: "host", sessionID: fixture.sessionID, tabs: tabs, layout: fixture.drop.layout,
                topLevelOrder: [], isConnected: true, destination: destination
            )
        }

        let privateProvider = NSItemProvider()
        let privateDrag = IOSSessionTabDrag.begin(hostID: "host", sessionID: fixture.sessionID, tab: privateID)
        defer { IOSSessionTabDrag.active = nil }
        privateProvider.register(privateDrag)
        let outside = drop(on: .row(fixture.source, members: nil))
        for position in [CGFloat(22), 40] {
            let result = try await perform(outside, provider: privateProvider, position: position)
            #expect(result == .failure(.cannotReorder))
        }
        let end = try await perform(drop(on: .end), provider: privateProvider, position: 40)
        #expect(end == .failure(.cannotReorder))

        let member = drop(on: .row(sharedID, members: group.tabs))
        let inside = try await perform(member, provider: privateProvider, position: 4)
        #expect(inside == .success(.moveLinked([.file(privateFile.id), .file(sharedFile.id)])))
        let sameRow = drop(on: .row(privateID, members: group.tabs))
        #expect(sameRow.plan(privateDrag, position: 4, height: 44) == .success(nil))

        let sharedProvider = NSItemProvider()
        let sharedDrag = IOSSessionTabDrag.begin(hostID: "host", sessionID: fixture.sessionID, tab: sharedID)
        sharedProvider.register(sharedDrag)
        let edge = try await perform(outside, provider: sharedProvider, position: 40)
        #expect(edge == .failure(.cannotReorder))
        let center = try await perform(outside, provider: sharedProvider, position: 22)
        #expect(center == .success(.shared(.group(sharedID, with: [fixture.source]))))
    }

    @Test("A decoded payload with the wrong process token cannot commit a layout edit")
    func rejectsForeignProcess() async throws {
        let fixture = Fixture()
        let drag = IOSSessionTabDrag.begin(hostID: "host", sessionID: fixture.sessionID, tab: fixture.source)
        defer { IOSSessionTabDrag.active = nil }
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(drag)) as? [String: Any])
        payload["originToken"] = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: payload)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: IOSSessionTabDrag.contentType.identifier, visibility: .all) { complete in
            complete(data, nil)
            return nil
        }

        let result = try await perform(fixture.drop, provider: provider, position: 40)
        #expect(result == .failure(.foreignProcess))
        #expect(IOSSessionTabDrag.active?.id == drag.id)
    }

    private func perform(
        _ drop: IOSSessionTabDrop, provider: NSItemProvider, position: CGFloat
    ) async throws -> Result<IOSSessionTabDrop.Action, IOSSessionTabDrop.Rejection> {
        let (results, completion) = AsyncStream<Result<IOSSessionTabDrop.Action, IOSSessionTabDrop.Rejection>>.makeStream()
        let target = IOSTabDropTarget(drop: drop, onHover: { _ in }) { action in
            completion.yield(.success(action))
            completion.finish()
        } onFailure: { rejection in
            completion.yield(.failure(rejection))
            completion.finish()
        }
        let proposal = target.dropUpdated(position: position, height: 44)
        try #require(proposal.operation == .copy)
        let accepted = target.performDrop([provider], position: position, height: 44)
        try #require(accepted)
        var iterator = results.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    @MainActor
    private struct Fixture {
        enum Destination {
            case standalone
            case groupMember
            case groupHeader
        }

        let sessionID: UUID
        let source: SessionTabID
        let target: SessionTabID
        let drop: IOSSessionTabDrop

        init(destination: Destination = .standalone) {
            let sessionID = UUID()
            self.sessionID = sessionID
            let ids = (0..<(destination == .standalone ? 2 : 3)).map { _ in UUID() }
            let order = ids.map(SessionTabID.window)
            let source = order[0]
            let target = order[1]
            self.source = source
            self.target = target
            let windows = TmuxWindow.groupPanes(ids.enumerated().map { index, id in
                PaneState(
                    paneId: "%\(index)", sessionName: "work", windowIndex: index, tmuxWindowId: "@\(index)", paneIndex: 0,
                    workspaceIdentity: .init(serverID: "server", sessionID: sessionID, windowID: id, paneID: UUID())
                )
            })
            let group = UUID()
            let members = Array(order.dropFirst())
            let groups = destination == .standalone ? [:] : Dictionary(uniqueKeysWithValues: members.map { ($0, group) })
            let dropDestination: IOSSessionTabDrop.Destination
            switch destination {
            case .standalone: dropDestination = .row(target, members: nil)
            case .groupMember: dropDestination = .row(target, members: members)
            case .groupHeader: dropDestination = .group(members)
            }
            self.drop = IOSSessionTabDrop(
                hostID: "host", sessionID: sessionID,
                tabs: .init(files: [], browsers: [], simulators: [], windows: windows, storedOrder: []),
                layout: .init(order: order, groups: groups), topLevelOrder: [], isConnected: true, destination: dropDestination
            )
        }
    }
}
