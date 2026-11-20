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

    public static func grouped(_ order: [Tab], paneOrder: [String] = [], groupID: (Tab) -> SessionTabGroup?) -> [Self] {
        let groups = Dictionary(grouping: order.compactMap { tab in groupID(tab).map { ($0, tab) } }, by: \.0)
        let entries: [Self] = order.compactMap { tab in
            guard let id = groupID(tab), let members = groups[id] else { return .tab(tab) }
            if case .manual = id, members.count < 2 {
                return .tab(tab)
            }
            return members.first?.1 == tab ? .group(id, members.map(\.1)) : nil
        }
        let panes = entries.compactMap(\.sourcePaneID)
        let automatic = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            entry.sourcePaneID.map { ($0, entry) }
        })
        return entries.filter { $0.sourcePaneID == nil }
            + PaneLinkedTabs.ordered(panes, stored: paneOrder).compactMap { automatic[$0] }
    }
}
