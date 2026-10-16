#if os(macOS)
    import Foundation

    /// Persists in-progress edits for remote viewer editor overlays.
    ///
    /// Keyed by Host pairing and editor session UUID so a new Ctrl-G session on the same pane
    /// naturally starts fresh (different UUID → no stored entry → falls back
    /// to the original file content from the host).
    @Observable
    @MainActor
    final public class RemoteEditorContentStore {
        public struct Key: Hashable, Sendable {
            public var hostID: String
            public var sessionID: UUID

            public init(hostID: String, sessionID: UUID) {
                self.hostID = hostID
                self.sessionID = sessionID
            }
        }

        public var editedContents: [Key: String] = [:]
        @ObservationIgnored var onClear: ((Key, String?) -> Void)?

        public init() { }

        public func clear(_ key: Key, submittedText: String? = nil) {
            if let submittedText, let current = editedContents[key], current != submittedText {
                return
            }
            onClear?(key, submittedText)
            editedContents.removeValue(forKey: key)
        }

        /// Drops any stored edits whose `sessionId` is no longer in `activeSessionIds`.
        /// Call after each session-state update from the remote host so that entries
        /// for sessions ended by the host (not the local viewer) don't linger.
        public func retainOnly(activeSessionIds: Set<Key>, hostID: String) {
            editedContents = editedContents.filter { $0.key.hostID != hostID || activeSessionIds.contains($0.key) }
        }

        func invalidate(hostID: String) {
            editedContents = editedContents.filter { $0.key.hostID != hostID }
        }
    }
#endif
