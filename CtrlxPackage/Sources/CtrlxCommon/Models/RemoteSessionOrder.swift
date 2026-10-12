import Foundation

/// Device-local ranking for local or remote tmux session lists.
///
/// The caller supplies the automatic base order. A saved preference only ranks
/// session names it has seen; new sessions retain their relative base order
/// and are appended after the ranked sessions.
public enum RemoteSessionOrder {
    public static func normalized(_ sessionNames: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for name in sessionNames where !name.isEmpty && seen.insert(name).inserted {
            result.append(name)
        }
        return result
    }

    public static func applying<Element>(
        _ preferredSessionNames: [String],
        to elements: [Element],
        sessionName: (Element) -> String
    ) -> [Element] {
        guard !preferredSessionNames.isEmpty else { return elements }

        var rankByName: [String: Int] = [:]
        for name in preferredSessionNames where rankByName[name] == nil {
            rankByName[name] = rankByName.count
        }

        return elements.enumerated().sorted { lhs, rhs in
            let lhsRank = rankByName[sessionName(lhs.element)]
            let rhsRank = rankByName[sessionName(rhs.element)]

            switch (lhsRank, rhsRank) {
            case let (lhsRank?, rhsRank?):
                return lhsRank < rhsRank
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// Applies SwiftUI's `onMove` coordinates without depending on SwiftUI.
    public static func moving(
        _ sessionNames: [String],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [String] {
        let validSource = source.filter(sessionNames.indices.contains).sorted()
        guard !validSource.isEmpty else { return sessionNames }

        let moved = validSource.map { sessionNames[$0] }
        let sourceSet = Set(validSource)
        var remaining = sessionNames.enumerated().compactMap { index, name in
            sourceSet.contains(index) ? nil : name
        }
        let removedBeforeDestination = validSource.count { $0 < destination }
        let insertionIndex = min(
            max(destination - removedBeforeDestination, 0),
            remaining.count
        )
        remaining.insert(contentsOf: moved, at: insertionIndex)
        return remaining
    }

    /// Migrates a persisted rank after a successful remote tmux rename.
    public static func replacing(
        _ oldName: String,
        with newName: String,
        in sessionNames: [String]
    ) -> [String] {
        normalized(sessionNames.map { $0 == oldName ? newName : $0 })
    }
}
