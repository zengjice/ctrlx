import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Observation

@MainActor
@Observable
final class HostSessionTabLayouts {
    @ObservationIgnored @Dependency(PreferencesService.self) private var preferences
    private var layouts: [UUID: SessionTabLayout]
    @ObservationIgnored private var editsInFlight: Set<UUID> = []
    private static let preferenceKey = "sessionTabLayouts"

    init() {
        @Dependency(PreferencesService.self) var preferences
        self.layouts = preferences.data(Self.preferenceKey)
            .flatMap { try? JSONDecoder().decode([UUID: SessionTabLayout].self, from: $0) } ?? [:]
    }

    func snapshot(sessionID: UUID, catalog: [SessionTabID]) -> SessionTabLayout {
        guard let layout = layouts[sessionID] else { return SessionTabLayout().reconciled(with: catalog) }
        return Self.withLiveWindows(layout, catalog: catalog)
    }

    func apply(
        _ request: EditSessionTabLayout, catalog: [SessionTabID], sourcePanes: [SessionTabID: String] = [:], paneOrder: [String] = [],
        confirm: (SessionTabLayout) async throws -> [SessionTabID]?
    ) async throws {
        guard editsInFlight.insert(request.sessionID).inserted else {
            throw FileBrowserError.message("The session's tab layout is already being updated. Try again shortly.")
        }
        defer { editsInFlight.remove(request.sessionID) }
        let stored: SessionTabLayout
        if let existing = layouts[request.sessionID] {
            stored = existing
        } else if case .moveGroup = request.edit {
            // Group initialization merges rows, not individual visible member slots.
            stored = SessionTabLayout(order: catalog)
        } else {
            stored = SessionTabLayout(order: Self.fillSlots(in: catalog, with: request.initialOrder ?? []))
        }
        var layout = Self.withLiveWindows(stored, catalog: catalog)
        if case let .moveGroup(moving, _, _, _) = request.edit, layout.ordersGroups != true, let initialOrder = request.initialOrder {
            guard request.initialOrderRevision == layout.revision else {
                throw FileBrowserError.message("The tab order changed while this group was being dragged. Refresh the tabs and try again.")
            }
            layout = layout.initializingGroupOrder(from: initialOrder, windowOrder: catalog.filter {
                if case .window = $0 {
                    true
                } else {
                    false
                }
            }, moving: moving, sourcePanes: sourcePanes, paneOrder: paneOrder)
        }
        guard layout.apply(request.edit, catalog: catalog, sourcePanes: sourcePanes) else {
            throw FileBrowserError.message("One of these tabs is no longer part of the session.")
        }
        let confirmedWindows = try await confirm(layout)
        guard editsInFlight.contains(request.sessionID) else {
            throw FileBrowserError.message("This session is no longer available. Refresh the session list.")
        }
        if let visibleWindows = request.visibleWindows, let confirmedWindows {
            layout = Self.reinsertingOutsideWindows(in: layout, visible: Set(visibleWindows), confirmed: confirmedWindows)
        }
        var updated = layouts
        updated[request.sessionID] = layout
        try save(updated)
    }

    func remove(_ sessionID: UUID) throws {
        editsInFlight.remove(sessionID)
        var updated = layouts
        guard updated.removeValue(forKey: sessionID) != nil else { return }
        try save(updated)
    }

    private func save(_ updated: [UUID: SessionTabLayout]) throws {
        try preferences.setData(JSONEncoder().encode(updated), Self.preferenceKey)
        layouts = updated
    }

    private static func reinsertingOutsideWindows(
        in layout: SessionTabLayout, visible: Set<SessionTabID>, confirmed: [SessionTabID]
    ) -> SessionTabLayout {
        let windows = Set(confirmed)
        guard layout.order.filter(windows.contains) != confirmed else { return layout }
        let outside = windows.subtracting(visible)
        var remaining = confirmed[...]
        var order: [SessionTabID] = []
        // Preserve the edited order of resources and visible windows. Insert the
        // other windows before their next visible neighbor in confirmed tmux order.
        for tab in layout.order where !outside.contains(tab) {
            if visible.contains(tab) {
                let preceding = remaining.prefix(while: outside.contains)
                order.append(contentsOf: preceding)
                remaining = remaining.dropFirst(preceding.count + 1)
            }
            order.append(tab)
        }
        order.append(contentsOf: remaining)
        return SessionTabLayout(order: order, groups: layout.groups, revision: layout.revision, ordersGroups: layout.ordersGroups)
    }

    private static func withLiveWindows(_ layout: SessionTabLayout, catalog: [SessionTabID]) -> SessionTabLayout {
        let current = layout.reconciled(with: catalog)
        let windows = catalog.filter {
            if case .window = $0 {
                true
            } else {
                false
            }
        }
        return SessionTabLayout(
            order: fillSlots(in: current.order, with: windows),
            groups: current.groups, revision: current.revision, ordersGroups: current.ordersGroups
        )
    }

    private static func fillSlots(in order: [SessionTabID], with preferred: [SessionTabID]) -> [SessionTabID] {
        let members = Set(order)
        var seen = Set<SessionTabID>()
        var replacements = preferred.filter { members.contains($0) && seen.insert($0).inserted }.makeIterator()
        return order.map { seen.contains($0) ? replacements.next() ?? $0 : $0 }
    }
}
