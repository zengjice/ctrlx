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
        guard let layout = layouts[sessionID] else { return .init() }
        return Self.withLiveWindows(layout, catalog: catalog)
    }

    func apply(
        _ request: EditSessionTabLayout, catalog: [SessionTabID],
        confirm: (SessionTabLayout) async throws -> [SessionTabID]?
    ) async throws {
        guard editsInFlight.insert(request.sessionID).inserted else {
            throw FileBrowserError.message("The session's tab layout is already being updated. Try again shortly.")
        }
        defer { editsInFlight.remove(request.sessionID) }
        let stored = layouts[request.sessionID] ?? SessionTabLayout(
            order: Self.fillSlots(in: catalog, with: request.initialOrder ?? [])
        )
        var layout = Self.withLiveWindows(stored, catalog: catalog)
        guard layout.apply(request.edit, catalog: catalog) else {
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
        return SessionTabLayout(order: order, groups: layout.groups, revision: layout.revision)
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
            groups: current.groups, revision: current.revision
        )
    }

    private static func fillSlots(in order: [SessionTabID], with preferred: [SessionTabID]) -> [SessionTabID] {
        let members = Set(order)
        var seen = Set<SessionTabID>()
        var replacements = preferred.filter { members.contains($0) && seen.insert($0).inserted }.makeIterator()
        return order.map { seen.contains($0) ? replacements.next() ?? $0 : $0 }
    }
}
