import Foundation

public enum SessionTabGroup: Hashable, Sendable {
    case pane(String)
    case manual(UUID)

    public var paneID: String? {
        if case let .pane(id) = self {
            return id
        }
        return nil
    }
}

public enum SessionTabEntry<Tab: Hashable>: Identifiable {
    public enum ID: Hashable {
        case tab(Tab)
        case group(SessionTabGroup)
    }

    case tab(Tab)
    case group(SessionTabGroup, [Tab])

    public var id: ID {
        switch self {
        case let .tab(tab): .tab(tab)
        case let .group(group, _): .group(group)
        }
    }

    public var tabs: [Tab] {
        switch self {
        case let .tab(tab): [tab]
        case let .group(_, tabs): tabs
        }
    }

    public var sourcePaneID: String? {
        guard case let .group(group, _) = self else { return nil }
        return group.paneID
    }

    public static func grouped(_ order: [Tab], paneOrder: [String] = [], preserveGroupPositions: Bool = false, groupID: (Tab) -> SessionTabGroup?) -> [Self] {
        let groups = Dictionary(grouping: order.compactMap { tab in groupID(tab).map { ($0, tab) } }, by: \.0)
        let entries: [Self] = order.compactMap { tab in
            guard let id = groupID(tab), let members = groups[id] else { return .tab(tab) }
            if case .manual = id, members.count < 2 {
                return .tab(tab)
            }
            return members.first?.1 == tab ? .group(id, members.map(\.1)) : nil
        }
        if preserveGroupPositions {
            return entries
        }
        let panes = entries.compactMap(\.sourcePaneID)
        let automatic = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            entry.sourcePaneID.map { ($0, entry) }
        })
        return entries.filter { $0.sourcePaneID == nil }
            + PaneLinkedTabs.ordered(panes, stored: paneOrder).compactMap { automatic[$0] }
    }

    public static func movingGroup(_ members: [Tab], before target: Tab?, in entries: [Self]) -> [Self]? {
        let moving = Set(members)
        guard
            !moving.isEmpty, moving.count == members.count,
            let source = entries.first(where: { Set($0.tabs) == moving }),
            case .group = source, target.map({ !moving.contains($0) }) ?? true else { return nil }
        var result = entries.filter { $0.id != source.id }
        let index: Int
        if let target {
            guard let found = result.firstIndex(where: { $0.tabs.contains(target) }) else { return nil }
            index = found
        } else {
            index = result.endIndex
        }
        result.insert(source, at: index)
        return result
    }

    package static func insertionAnchor(for source: Tab, from current: [Self], to projected: [Self]) -> (row: ID, side: InsertionSide)? {
        guard let slot = projected.firstIndex(where: { $0.tabs.contains(source) }) else { return nil }
        let retained = Set(current.map(\.id)).intersection(projected.map(\.id)).subtracting([projected[slot].id])
        let projectedMembers = Dictionary(uniqueKeysWithValues: projected.map { ($0.id, $0.tabs) })
        // A surviving group is an anchor only if it stays on the same side of unchanged rows.
        let unchanged = Set(current.filter { projectedMembers[$0.id] == $0.tabs }.map(\.id)).intersection(retained)
        let anchors = retained.filter { row in
            Set(current.prefix { $0.id != row }.map(\.id)).intersection(unchanged)
                == Set(projected.prefix { $0.id != row }.map(\.id)).intersection(unchanged)
        }
        if let previous = projected[..<slot].last(where: { anchors.contains($0.id) }) {
            return (previous.id, .after)
        }
        if let next = projected.dropFirst(slot + 1).first(where: { anchors.contains($0.id) }) {
            return (next.id, .before)
        }
        return current.first(where: { $0.tabs.contains(source) }).map { ($0.id, slot == 0 ? .before : .after) }
    }

    package static func positionChanged(of row: ID, from current: [Self], to projected: [Self]) -> Bool {
        let retained = Set(current.map(\.id)).intersection(projected.map(\.id))
        guard retained.contains(row) else { return true }
        return Set(current.prefix { $0.id != row }.map(\.id)).intersection(retained)
            != Set(projected.prefix { $0.id != row }.map(\.id)).intersection(retained)
    }
}
