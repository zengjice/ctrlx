import Foundation

/// Tracks which paired viewers own a terminal stream subscription.
///
/// A viewer may retry `StartTerminalStream`; ownership must remain idempotent
/// instead of behaving like a reference count.
struct TerminalStreamOwnership: Equatable, Sendable {
    enum Removal: Equatable, Sendable {
        case notSubscribed
        case staleLease
        case retained(Int)
        case empty
    }

    private enum Lease: Equatable, Sendable {
        case legacy
        case identified(UUID)

        init(_ id: UUID?) {
            self = id.map(Lease.identified) ?? .legacy
        }
    }

    private var viewerLeases: [String: Lease]

    init(viewerId: String, leaseId: UUID? = nil) {
        self.viewerLeases = [viewerId: Lease(leaseId)]
    }

    var leaseIDs: [String: UUID] {
        viewerLeases.compactMapValues { lease in
            if case let .identified(id) = lease {
                return id
            }
            return nil
        }
    }

    var count: Int {
        viewerLeases.count
    }

    var subscribers: Set<String> {
        Set(viewerLeases.keys)
    }

    func contains(_ viewerId: String) -> Bool {
        viewerLeases[viewerId] != nil
    }

    func contains(_ viewerId: String, leaseId: UUID?) -> Bool {
        viewerLeases[viewerId] == Lease(leaseId)
    }

    /// Installs the viewer's latest lease. Returns true when ownership changed.
    @discardableResult
    mutating func subscribe(_ viewerId: String, leaseId: UUID? = nil) -> Bool {
        let lease = Lease(leaseId)
        let changed = viewerLeases[viewerId] != lease
        viewerLeases[viewerId] = lease
        return changed
    }

    /// Releases a user-requested subscription only when its lease still owns it.
    mutating func unsubscribe(_ viewerId: String, leaseId: UUID? = nil) -> Removal {
        guard let currentLease = viewerLeases[viewerId] else {
            return .notSubscribed
        }
        guard currentLease == Lease(leaseId) else { return .staleLease }
        return removeViewer(viewerId)
    }

    /// Connection loss invalidates every lease owned by that viewer.
    mutating func unsubscribeViewer(_ viewerId: String) -> Removal {
        guard viewerLeases[viewerId] != nil else { return .notSubscribed }
        return removeViewer(viewerId)
    }

    private mutating func removeViewer(_ viewerId: String) -> Removal {
        viewerLeases.removeValue(forKey: viewerId)
        return viewerLeases.isEmpty ? .empty : .retained(viewerLeases.count)
    }
}
