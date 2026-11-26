import CoreTransferable
import CtrlxCommon
import CtrlxNetworking
import Foundation
import UniformTypeIdentifiers

struct IOSSessionTabDrag: Codable, Sendable, Transferable {
    // DropInfo only exposes the item provider to the drop callback. Keep a
    // shared drag for highlighting targets in both iPad scenes.
    @MainActor static var active: Self?
    static let contentType = UTType(exportedAs: "com.jicezeng.ctrlx.session-tab", conformingTo: .data)
    private static let processToken = UUID()

    let id: UUID
    let hostID: String
    let sessionID: UUID
    let tab: SessionTabID
    var group: [SessionTabID]? = nil
    private let originToken: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType).visibility(.ownProcess)
    }

    @MainActor
    static func begin(hostID: String, sessionID: UUID, tab: SessionTabID, group: [SessionTabID]? = nil) -> Self {
        let drag = Self(id: UUID(), hostID: hostID, sessionID: sessionID, tab: tab, group: group, originToken: processToken)
        active = drag
        return drag
    }

    @MainActor
    static func provider(hostID: String, sessionID: UUID, tab: SessionTabID, group: [SessionTabID]? = nil) -> NSItemProvider {
        let drag = begin(hostID: hostID, sessionID: sessionID, tab: tab, group: group)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: contentType.identifier, visibility: .ownProcess) { completion in
            do { try completion(JSONEncoder().encode(drag), nil) }
            catch { completion(nil, error) }
            return nil
        }
        return provider
    }

    fileprivate var originatedHere: Bool {
        originToken == Self.processToken
    }

    fileprivate func belongs(to hostID: String, sessionID: UUID?) -> Bool {
        self.hostID == hostID && self.sessionID == sessionID
    }
}

@MainActor
struct IOSSessionTabDrop {
    enum Destination {
        case row(SessionTabID, members: [SessionTabID]?)
        case group([SessionTabID])
        case end
    }

    enum Action: Equatable, Sendable {
        case moveTopLevel([IOSTopLevelTabID])
        case moveLinked([PaneLinkedTabID])
        case moveGroup(SessionTabLayout.Edit?, [IOSTopLevelTabID])
        case shared(SessionTabLayout.Edit)

        var groupsTabs: Bool {
            if case .shared(.group) = self {
                return true
            }
            return false
        }
    }

    enum Rejection: LocalizedError, Equatable {
        case unreadable
        case foreignProcess
        case differentSession
        case outsideGroup
        case privateFiles
        case groupUnavailable
        case cannotReorder

        var errorDescription: String? {
            switch self {
            case .unreadable: "Could not read the dragged tab. Try dragging it again."
            case .foreignProcess: "Start the drag from a Tabs panel in CtrlX."
            case .differentSession: "Tabs can only be dragged within the same Host session."
            case .outsideGroup: "Member rows sort tabs within the group. Drop on the group header to join it."
            case .privateFiles: "Adding tabs to a group requires Host-owned tabs. The dragged tab or group contains a private Files tab."
            case .groupUnavailable: "Joining a group requires a connected Host and tabs that are still in the session."
            case .cannotReorder: "This tab can’t be reordered here. To reorder tabs in a pane group, drag them within that group."
            }
        }
    }

    let hostID: String
    let sessionID: UUID?
    let tabs: IOSPaneLinkedTabs
    let layout: SessionTabLayout
    let topLevelOrder: [IOSTopLevelTabID]
    let isConnected: Bool
    let destination: Destination

    func plan(_ drag: IOSSessionTabDrag, position: CGFloat, height: CGFloat) -> Result<Action?, Rejection> {
        guard drag.belongs(to: hostID, sessionID: sessionID) else { return .failure(.differentSession) }
        if let group = drag.group {
            return planGroup(group, position: position, height: height)
        }
        let source = drag.tab
        let targets: [SessionTabID]
        let members: [SessionTabID]?
        let side: InsertionSide?
        switch destination {
        case let .row(target, group):
            if let group, !group.contains(source) {
                return .failure(groupingRejection(for: source, with: group) ?? .outsideGroup)
            }
            targets = [target]
            members = group
            side = group == nil ? .tabEdge(position: position, length: height) : .init(position: position, length: height)
        case let .group(group):
            targets = group
            members = nil
            side = nil
        case .end:
            targets = []
            members = nil
            side = .after
        }
        guard !targets.contains(source) else { return .success(nil) }
        if tabs.isPrivateFile(source) || (side != nil && targets.count == 1 && targets.contains(where: tabs.isPrivateFile)) {
            guard contains(source) else { return .failure(.cannotReorder) }
            if members != nil, let target = targets.first {
                guard let order = tabs.movingPrivateMember(source, before: target, side: side ?? .before, layout: layout) else {
                    return .failure(.cannotReorder)
                }
                return .success(.moveLinked(order))
            }
            guard let order = tabs.movingPrivateTab(source, before: targets, side: side ?? .before, layout: layout, stored: topLevelOrder) else {
                if case .group = destination {
                    return .failure(.privateFiles)
                }
                return .failure(.cannotReorder)
            }
            return .success(.moveTopLevel(order))
        }
        guard let side else {
            if let rejection = groupingRejection(for: source, with: targets) {
                return .failure(rejection)
            }
            return .success(.shared(.group(source, with: targets)))
        }
        guard
            contains(source), isConnected, tabs.isShareable(source), targets.allSatisfy(tabs.isShareable),
            let edit = tabs.sharedMove(source, before: targets.first, side: side, layout: layout, topLevelOrder: topLevelOrder) else {
            return .failure(.cannotReorder)
        }
        return .success(.shared(edit))
    }

    private func planGroup(_ members: [SessionTabID], position: CGFloat, height: CGFloat) -> Result<Action?, Rejection> {
        let entries = tabs.sharedEntries(layout, topLevelOrder: topLevelOrder)
        let target: SessionTabID?
        let side = InsertionSide(position: position, length: height)
        switch destination {
        case let .row(tab, nil): target = tab
        case let .group(group): target = group.first
        case .end: target = nil
        case .row: return .failure(.cannotReorder)
        }
        if let target, members.contains(target) {
            return .success(nil)
        }
        guard target.map({ target in entries.contains { $0.tabs.contains(target) } }) ?? true else { return .failure(.cannotReorder) }
        let anchor: SessionTabID?
        if let target, let index = entries.firstIndex(where: { $0.tabs.contains(target) }) {
            anchor = side == .before ? entries[index].tabs.first : entries.dropFirst(index + 1).first?.tabs.first
        } else {
            anchor = nil
        }
        if anchor.map(members.contains) == true {
            return .success(nil)
        }
        guard let reordered = SessionTabEntry.movingGroup(members, before: anchor, in: entries) else { return .failure(.cannotReorder) }
        guard reordered.map(\.id) != entries.map(\.id) else { return .success(nil) }
        let shared = members.filter(tabs.isShareable)
        let order = tabs.topLevelOrder(for: reordered.flatMap(\.tabs), stored: topLevelOrder)
        if shared.isEmpty {
            return .success(.moveGroup(nil, order))
        }
        guard isConnected, layout.supportsGroupReordering == true else { return .failure(.groupUnavailable) }
        // A private row is a local anchor, never part of the Host's tab catalog.
        let nextShared = anchor.flatMap { anchor in
            reordered.drop { !$0.tabs.contains(anchor) }.flatMap(\.tabs).first(where: tabs.isShareable)
        }
        let origin = entries.first { Set($0.tabs) == Set(members) }
        return .success(.moveGroup(.moveGroup(shared, before: nextShared, groupID: shared.lazy.compactMap { layout.groups[$0] }.first, sourcePaneID: origin?.sourcePaneID), order))
    }

    private func contains(_ tab: SessionTabID) -> Bool {
        tabs.windows.contains { $0.sessionTabID == tab } || tabs.items.contains { $0.sessionTabID == tab }
    }

    private func groupingRejection(for source: SessionTabID, with members: [SessionTabID]) -> Rejection? {
        if tabs.isPrivateFile(source) || members.contains(where: tabs.isPrivateFile) {
            return .privateFiles
        }
        guard
            isConnected, contains(source), !members.isEmpty, !members.contains(source),
            tabs.isShareable(source), members.allSatisfy(tabs.isShareable) else { return .groupUnavailable }
        return nil
    }

    func perform(
        _ providers: [NSItemProvider], position: CGFloat, height: CGFloat,
        completion: @escaping @MainActor @Sendable (Result<Action?, Rejection>) -> Void
    ) -> Bool {
        guard providers.count == 1, let provider = providers.first else { return false }
        provider.loadTransferable(type: IOSSessionTabDrag.self) { result in
            Task { @MainActor in
                guard case let .success(drag) = result else {
                    completion(.failure(.unreadable))
                    return
                }
                guard drag.originatedHere else {
                    completion(.failure(.foreignProcess))
                    return
                }
                if IOSSessionTabDrag.active?.id == drag.id {
                    IOSSessionTabDrag.active = nil
                }
                completion(plan(drag, position: position, height: height))
            }
        }
        return true
    }
}

extension IOSPaneLinkedTabs {
    func isShareable(_ tab: SessionTabID) -> Bool {
        if case let .file(id) = tab {
            return files.contains { $0.id == id && $0.hostTab != nil }
        }
        return true
    }
}
