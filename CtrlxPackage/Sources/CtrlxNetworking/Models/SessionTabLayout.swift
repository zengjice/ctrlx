import Foundation

/// Stable IDs for tabs advertised by the Host. A Browser and a Simulator both
/// occupy a resource tab with its own UUID.
public enum SessionTabID: Codable, Hashable, Sendable {
    case window(UUID)
    case file(UUID)
    case browser(UUID)
}

public struct SessionTabLayout: Codable, Equatable, Sendable {
    public private(set) var order: [SessionTabID]
    public private(set) var groups: [SessionTabID: UUID]
    public private(set) var revision: UInt64

    public init(order: [SessionTabID] = [], groups: [SessionTabID: UUID] = [:], revision: UInt64 = 0) {
        self.order = order
        self.groups = groups
        self.revision = revision
    }

    public func ordered(_ catalog: [SessionTabID]) -> [SessionTabID] {
        let live = Set(catalog)
        var seen = Set<SessionTabID>()
        return (order + catalog).filter { live.contains($0) && seen.insert($0).inserted }
    }

    public func reconciled(with catalog: [SessionTabID]) -> Self {
        let live = Set(catalog)
        return Self(order: ordered(catalog), groups: Self.validGroups(groups.filter { live.contains($0.key) }), revision: revision)
    }

    private static func validGroups(_ membership: [SessionTabID: UUID]) -> [SessionTabID: UUID] {
        let counts = Dictionary(grouping: membership.values, by: { $0 })
        return membership.filter { (counts[$0.value]?.count ?? 0) > 1 }
    }

    /// Apply a single edit to the latest Host order, preserving concurrent
    /// edits to unrelated tabs and ignoring stale/missing targets.
    public mutating func apply(_ edit: Edit, catalog: [SessionTabID]) -> Bool {
        let live = Set(catalog)
        let current = reconciled(with: catalog)
        var next = current.order
        var membership = current.groups
        switch edit {
        case let .move(source, target, groupMembership):
            guard
                let index = next.firstIndex(of: source), target != source,
                target.map(live.contains) ?? true else { return false }
            next.remove(at: index)
            next.insert(source, at: target.flatMap { next.firstIndex(of: $0) } ?? next.endIndex)
            if groupMembership == .leave || (groupMembership == nil && membership[source] != target.flatMap { membership[$0] }) {
                membership.removeValue(forKey: source)
            }
        case let .moveToEnd(source, after: anchor, groupMembership):
            guard live.contains(source), anchor != source, anchor.map(live.contains) ?? true else { return false }
            next.removeAll { $0 == source }
            let index = anchor.flatMap { next.firstIndex(of: $0) }.map { $0 + 1 } ?? next.endIndex
            next.insert(source, at: index)
            if groupMembership != .keep {
                membership.removeValue(forKey: source)
            }
        case let .group(source, targets):
            guard
                live.contains(source), let target = targets.first, !targets.contains(source),
                targets.allSatisfy(live.contains) else { return false }
            let group = membership[target] ?? UUID()
            for tab in targets + [source] {
                membership[tab] = group
            }
            next.removeAll { $0 == source }
            if let destination = next.lastIndex(where: { membership[$0] == group }) {
                next.insert(source, at: destination + 1)
            }
        case let .ungroup(source):
            guard live.contains(source), let group = membership[source] else { return false }
            membership = membership.filter { $0.value != group }
        }
        order = next
        groups = Self.validGroups(membership)
        revision += 1
        return true
    }

    public enum GroupMembership: String, Codable, Sendable {
        case keep
        case leave
    }

    public enum Edit: Codable, Equatable, Sendable {
        case move(SessionTabID, before: SessionTabID?, groupMembership: GroupMembership? = nil)
        case moveToEnd(SessionTabID, after: SessionTabID?, groupMembership: GroupMembership? = nil)
        case group(SessionTabID, with: [SessionTabID])
        case ungroup(SessionTabID)
    }
}

public struct EditSessionTabLayout: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage
    public let sessionID: UUID
    public let edit: SessionTabLayout.Edit
    public let initialOrder: [SessionTabID]?
    public let visibleWindows: [SessionTabID]?

    public init(sessionID: UUID, edit: SessionTabLayout.Edit, initialOrder: [SessionTabID]? = nil, visibleWindows: [SessionTabID]? = nil) {
        self.sessionID = sessionID
        self.edit = edit
        self.initialOrder = initialOrder
        self.visibleWindows = visibleWindows
    }

    public var commandType: CommandType {
        .editSessionTabLayout(self)
    }
}
