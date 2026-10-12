import Foundation

/// Keep ownership until asynchronous audio cleanup has finished, including a
/// cancelled preparation. A second window must not overlap the old recorder.
@MainActor
final class VoiceInputRecordingOwnership {
    static let shared = VoiceInputRecordingOwnership()
    private var owner: UUID?

    func acquire() -> UUID? {
        guard owner == nil else { return nil }
        let id = UUID()
        owner = id
        return id
    }

    func release(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
    }
}
