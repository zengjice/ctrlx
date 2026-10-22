import Foundation

/// Presentation only. Callers scope a layout to one Host/session and supply
/// sources from its current catalog; no runtime pane identity is persisted here.
public enum PaneLinkedTabs {
    public struct Group<Item: Hashable>: Identifiable {
        public let id: String?
        public var items: [Item]
    }

    public enum Destination<Item: Hashable>: Equatable {
        case tab(Item)
        case sourcePane(String)
    }

    public static func groups<Item: Hashable>(
        items: [Item], paneOrder: [String], sourcePane: (Item) -> String?
    ) -> [Group<Item>] {
        var order: [String?] = []
        var members: [String?: [Item]] = [:]
        var seen = Set<Item>()
        for item in items where seen.insert(item).inserted {
            let source = sourcePane(item)
            if members[source] == nil {
                order.append(source)
            }
            members[source, default: []].append(item)
        }
        // Live sources follow terminal order. Closed sources retain their group;
        // legacy unbound tabs are kept together at the end.
        let live = paneOrder.filter { members[$0] != nil }
        let ids: [String?] = live.map(Optional.some) + order.filter { id in id.map { !live.contains($0) } ?? false }
            + (members[nil] == nil ? [] : [nil])
        return ids.map { Group(id: $0, items: members[$0] ?? []) }
    }

    public static func adjacent<Item: Hashable>(
        to current: Item, direction: Int, groups: [Group<Item>]
    ) -> Destination<Item>? {
        guard
            abs(direction) == 1,
            let group = groups.first(where: { $0.items.contains(current) }),
            let index = group.items.firstIndex(of: current) else { return nil }
        let next = index + direction
        if group.items.indices.contains(next) {
            return .tab(group.items[next])
        }
        return group.id.map(Destination.sourcePane)
    }

    /// Saved order may precede catalog arrival; only the rendered result is pruned.
    public static func ordered<Item: Hashable>(_ live: [Item], stored: [Item]) -> [Item] {
        let valid = Set(live)
        var seen = Set<Item>()
        return (stored + live).filter { valid.contains($0) && seen.insert($0).inserted }
    }
}

/// Cross-type order for iOS; IDs are Host catalog IDs, scoped by the workspace.
public enum PaneLinkedTabID: Codable, Hashable, Sendable {
    case file(UUID)
    case browser(UUID)
    case simulator(UUID)
}
