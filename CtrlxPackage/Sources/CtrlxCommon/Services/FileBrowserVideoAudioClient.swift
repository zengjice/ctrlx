import Dependencies
import DependenciesMacros
import Foundation

#if os(iOS)
import AVFoundation
#endif

@DependencyClient
struct FileBrowserVideoAudioClient: Sendable {
    var acquire: @MainActor @Sendable (_ owner: UUID) throws -> Void
    var release: @MainActor @Sendable (_ owner: UUID) throws -> Void
}

extension FileBrowserVideoAudioClient: DependencyKey {
    static let liveValue = Self(
        acquire: { owner in
            #if os(iOS)
            try FileBrowserVideoAudioLeases.shared.acquire(owner)
            #endif
        },
        release: { owner in
            #if os(iOS)
            try FileBrowserVideoAudioLeases.shared.release(owner)
            #endif
        }
    )

    static let testValue = Self(acquire: { _ in }, release: { _ in })
}

@MainActor
final class FileBrowserVideoAudioLeases {
    private(set) var owners: Set<UUID> = []
    private let activate: @MainActor @Sendable () throws -> Void
    private let deactivate: @MainActor @Sendable () throws -> Void

    init(activate: @escaping @MainActor @Sendable () throws -> Void,
         deactivate: @escaping @MainActor @Sendable () throws -> Void) {
        self.activate = activate
        self.deactivate = deactivate
    }

    func acquire(_ owner: UUID) throws {
        guard !owners.contains(owner) else { return }
        try activate()
        owners.insert(owner)
    }

    func release(_ owner: UUID) throws {
        guard owners.remove(owner) != nil, owners.isEmpty else { return }
        try deactivate()
    }

    #if os(iOS)
    fileprivate static let shared = FileBrowserVideoAudioLeases(
        activate: {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        },
        deactivate: {
            let session = AVAudioSession.sharedInstance()
            // A recording may have taken over the app-wide session meanwhile.
            guard session.category == .playback, session.mode == .moviePlayback else { return }
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    )
    #endif
}
