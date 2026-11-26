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
    public private(set) var ordersGroups: Bool?
    public let supportsGroupReordering: Bool?

    public init(order: [SessionTabID] = [], groups: [SessionTabID: UUID] = [:], revision: UInt64 = 0, ordersGroups: Bool? = nil, supportsGroupReordering: Bool? = true) {
        self.order = order
        self.groups = groups
        self.revision = revision
        self.ordersGroups = ordersGroups
        self.supportsGroupReordering = supportsGroupReordering
    }

    public func ordered(_ catalog: [SessionTabID]) -> [SessionTabID] {
        let live = Set(catalog)
        var seen = Set<SessionTabID>()
        return (order + catalog).filter { live.contains($0) && seen.insert($0).inserted }
    }

    public func reconciled(with catalog: [SessionTabID]) -> Self {
        let live = Set(catalog)
        return Self(order: ordered(catalog), groups: Self.validGroups(groups.filter { live.contains($0.key) }), revision: revision, ordersGroups: ordersGroups, supportsGroupReordering: supportsGroupReordering)
    }

    public func initializingGroupOrder(from visible: [SessionTabID], windowOrder: [SessionTabID] = [], moving: [SessionTabID] = [], sourcePanes: [SessionTabID: String] = [:], paneOrder: [String] = []) -> Self {
        guard ordersGroups != true else { return self }
        let live = Set(order)
        var visibleTabs = Set<SessionTabID>()
        let visible = visible.filter { live.contains($0) && visibleTabs.insert($0).inserted }
        let grouped = Dictionary(grouping: order, by: { groups[$0] })
        let automatic = Dictionary(grouping: order.filter { groups[$0] == nil }, by: { sourcePanes[$0] })
        var seenRows = Set<SessionTabID>()
        let topLevel = order.compactMap { tab -> [SessionTabID]? in
            let members: [SessionTabID]
            if let group = groups[tab] {
                members = grouped[group] ?? [tab]
            } else if sourcePanes[tab] != nil {
                return nil
            } else {
                members = [tab]
            }
            return seenRows.insert(members[0]).inserted ? members : nil
        }
        var seenPanes = Set<String>()
        let panes = (paneOrder + order.compactMap { groups[$0] == nil ? sourcePanes[$0] : nil })
            .filter { automatic[$0] != nil && seenPanes.insert($0).inserted }
        let sourceRows = panes.compactMap { automatic[$0] }
        let allRows = topLevel + sourceRows
        let rowsByID = Dictionary(uniqueKeysWithValues: allRows.map { ($0[0], $0) })
        let owners = Dictionary(uniqueKeysWithValues: allRows.flatMap { row in row.map { ($0, row[0]) } })
        var seen = Set<SessionTabID>()
        let visibleRows = visible.compactMap { owners[$0] }.filter { seen.insert($0).inserted }
        let visibleIDs = Set(visibleRows), sourceIDs = Set(sourceRows.map { $0[0] })
        // Source groups follow top-level rows even before a layout has been saved.
        let baseline = allRows.filter { visibleIDs.contains($0[0]) || !sourceIDs.contains($0[0]) }
        // Saved top-level rows stay fixed; source rows follow the strip's visible pane order.
        let seededRows = revision > 0
            ? topLevel.map { $0[0] } + visibleRows.filter { sourceIDs.contains($0) }
            : visibleRows.filter { visibleTabs.contains($0) || sourceIDs.contains($0) }
        let seededIDs = Set(seededRows), movingRows = Set(moving.compactMap { owners[$0] })
        let anchors = seededIDs.subtracting(movingRows)
        var initialized = seededRows.compactMap { rowsByID[$0] }
        // A partial manual group's first visible member is not its global row position.
        for (index, row) in baseline.enumerated() where !seededIDs.contains(row[0]) {
            let next = baseline.dropFirst(index + 1).first { anchors.contains($0[0]) && !sourceIDs.contains($0[0]) }
            let previous = baseline.prefix(index).last { candidate in
                !movingRows.contains(candidate[0]) && initialized.contains { $0[0] == candidate[0] }
            }
            let slot = next.flatMap { next in initialized.firstIndex { $0[0] == next[0] } }
                ?? previous.flatMap { previous in initialized.firstIndex { $0[0] == previous[0] }.map { $0 + 1 } }
                ?? initialized.firstIndex { sourceIDs.contains($0[0]) } ?? initialized.endIndex
            initialized.insert(row, at: slot)
        }
        // Preserve hidden top-level anchors; missing source groups retain their pane order.
        for (index, row) in sourceRows.enumerated() where !seededIDs.contains(row[0]) {
            let next = sourceRows.dropFirst(index + 1).first { visibleIDs.contains($0[0]) }
            let slot = next.flatMap { next in initialized.firstIndex { $0[0] == next[0] } } ?? initialized.endIndex
            initialized.insert(row, at: slot)
        }
        seen = []
        let windows = windowOrder.filter { live.contains($0) && seen.insert($0).inserted }
        let windowIDs = Set(windows), moving = Set(moving)
        var rows = initialized.map { row in
            let members = Set(row)
            var preferred = visible.filter(members.contains).makeIterator()
            // A saved Host order remains authoritative when local groups split its members.
            let ordered = row.map { revision == 0 && visibleTabs.contains($0) ? preferred.next() ?? $0 : $0 }
            var currentWindows = windows.filter(members.contains).makeIterator()
            return ordered.map { windowIDs.contains($0) ? currentWindows.next() ?? $0 : $0 }
        }
        let remainingWindows = windows.filter { !moving.contains($0) }
        let ranks = Dictionary(uniqueKeysWithValues: remainingWindows.enumerated().map { ($0.element, $0.offset) })
        var windowRows = rows.compactMap { row in row.first.flatMap { ranks[$0] }.map { ($0, row) } }
            .sorted { $0.0 < $1.0 }.map(\.1).makeIterator()
        rows = rows.map { row in row.first.flatMap { ranks[$0] } == nil ? row : windowRows.next() ?? row }

        // A group's later windows can remain interleaved in tmux without moving its visible row.
        var before: [Int: [SessionTabID]] = [:]
        for (rowIndex, row) in rows.enumerated() {
            let futureWindows = rows.dropFirst(rowIndex + 1).flatMap { $0 }.compactMap { ranks[$0] }
            var previousWindow = -1
            for (index, tab) in row.enumerated() {
                if let rank = ranks[tab] {
                    previousWindow = rank
                    continue
                }
                let ownNext = row.dropFirst(index + 1).compactMap { ranks[$0] }.first
                let next = [ownNext, futureWindows.filter { $0 > previousWindow }.min()].compactMap { $0 }.min()
                before[next ?? remainingWindows.count, default: []].append(tab)
            }
        }
        let result = remainingWindows.enumerated().flatMap { before[$0.offset, default: []] + [$0.element] } + before[remainingWindows.count, default: []]
        return Self(order: result, groups: groups, revision: revision, ordersGroups: ordersGroups, supportsGroupReordering: supportsGroupReordering)
    }

    private static func validGroups(_ membership: [SessionTabID: UUID]) -> [SessionTabID: UUID] {
        let counts = Dictionary(grouping: membership.values, by: { $0 })
        return membership.filter { (counts[$0.value]?.count ?? 0) > 1 }
    }

    /// Apply a single edit to the latest Host order, preserving concurrent
    /// edits to unrelated tabs and ignoring stale/missing targets.
    public mutating func apply(_ edit: Edit, catalog: [SessionTabID], sourcePanes: [SessionTabID: String] = [:]) -> Bool {
        let live = Set(catalog)
        let current = reconciled(with: catalog)
        var next = current.order
        var membership = current.groups
        switch edit {
        case let .moveGroup(sources, target, groupID, sourcePaneID):
            let moving = Set(sources)
            guard
                !moving.isEmpty, moving.count == sources.count, moving.isSubset(of: live),
                target.map({ live.contains($0) && !moving.contains($0) }) ?? true else { return false }
            let inferredPane = groupID == nil && membership[sources[0]] == nil ? sourcePanes[sources[0]] : nil
            if let pane = sourcePaneID ?? inferredPane {
                guard groupID == nil, Set(catalog.filter { sourcePanes[$0] == pane && membership[$0] == nil }) == moving else { return false }
            } else if let group = groupID ?? sources.lazy.compactMap({ membership[$0] }).first {
                guard Set(membership.filter { $0.value == group }.keys) == moving else { return false }
            }
            let members = next.filter(moving.contains)
            next.removeAll(where: moving.contains)
            let anchor = target.flatMap { target in
                if let group = membership[target] {
                    return next.first { membership[$0] == group }
                }
                if let pane = sourcePanes[target] {
                    return next.first { membership[$0] == nil && sourcePanes[$0] == pane }
                }
                return target
            }
            next.insert(contentsOf: members, at: anchor.flatMap { next.firstIndex(of: $0) } ?? next.endIndex)
            ordersGroups = true
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
        case moveGroup([SessionTabID], before: SessionTabID?, groupID: UUID? = nil, sourcePaneID: String? = nil)
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
    public let initialOrderRevision: UInt64?

    public init(sessionID: UUID, edit: SessionTabLayout.Edit, initialOrder: [SessionTabID]? = nil, visibleWindows: [SessionTabID]? = nil, initialOrderRevision: UInt64? = nil) {
        self.sessionID = sessionID
        self.edit = edit
        self.initialOrder = initialOrder
        self.visibleWindows = visibleWindows
        self.initialOrderRevision = initialOrderRevision
    }

    public var commandType: CommandType {
        .editSessionTabLayout(self)
    }
}
