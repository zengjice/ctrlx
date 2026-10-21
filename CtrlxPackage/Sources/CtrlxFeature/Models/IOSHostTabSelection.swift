import Foundation

struct IOSHostTabSelection: Sendable {
    var selectedID: UUID?
    private var closingIDs: Set<UUID> = []

    func isClosing(_ id: UUID) -> Bool {
        closingIDs.contains(id)
    }

    mutating func beginClosing(_ id: UUID) {
        closingIDs.insert(id)
    }

    mutating func cancelClosing(_ id: UUID) {
        closingIDs.remove(id)
    }

    mutating func cancelPendingCloses() {
        closingIDs.removeAll()
    }

    /// Only catalog removal consumes a close intent; a successful reply may arrive on either side of it.
    /// Returns whether closing the selected tab should fit the revealed terminal.
    mutating func syncTabs(_ liveIDs: Set<UUID>) -> Bool {
        let closedIDs = closingIDs.subtracting(liveIDs)
        closingIDs.formIntersection(liveIDs)
        guard let selectedID, !liveIDs.contains(selectedID) else { return false }
        self.selectedID = nil
        return closedIDs.contains(selectedID)
    }
}
