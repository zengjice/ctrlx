#if os(macOS)
    import AppKit
    import CtrlxNetworking
    import Foundation
    import Logging

    /// An active editor session, tracking the file being edited and how to signal completion.
    public struct EditorSession: Identifiable, Sendable {
        public let id: UUID
        /// The tmux pane ID this editor session belongs to
        public let paneId: String
        /// Path to the temp file on the host (only meaningful on the host)
        public let filePath: String
        /// The content of the file when the editor was opened
        public let originalContent: String
        public let workspaceIdentity: WorkspacePaneIdentity?
    }

    public enum EditorSessionError: LocalizedError {
        case requestChanged

        public var errorDescription: String? {
            "The editor request changed or ended. Your text has been kept."
        }
    }

    /// Manages active prompt editor sessions across all panes.
    ///
    /// When the CtrlX CLI sends an `editor.open` request via the API socket,
    /// this manager:
    /// 1. Reads the file content
    /// 2. Creates an EditorSession
    /// 3. Notifies the UI to show the editor overlay
    /// 4. Blocks the API response until the user submits or cancels
    ///
    /// When the user submits or cancels, it:
    /// 1. Optionally writes the edited content back to the file
    /// 2. Resumes the continuation (unblocking the API response to the CLI)
    /// 3. Removes the session from active sessions
    @Observable
    @MainActor
    final public class EditorSessionManager {
        /// Active editor sessions keyed by pane ID.
        /// Only one editor session per pane is supported.
        public private(set) var activeSessions: [String: EditorSession] = [:]

        /// Current edited content per pane. Persisted here so that edits survive
        /// SwiftUI view teardown/recreation (e.g., when switching tabs).
        public var editedContents: [String: String] = [:]

        /// Per-session continuations that block the API response until editing completes.
        private var completionContinuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
        private var pendingReads: [String: UUID] = [:]
        private let readFile: @Sendable (String) async throws -> String

        private let logger = Logger(label: "com.jicezeng.ctrlx.editorsessionmanager")

        /// Called when an editor session opens or closes, to push state to viewers.
        public var onSessionChanged: (@MainActor @Sendable () async -> Void)?
        public var currentPaneIdentity: (@MainActor @Sendable (String) -> WorkspacePaneIdentity?)?
        public var onSessionInvalidated: (@MainActor @Sendable (EditorSession, String) -> Void)?

        public init(readFile: @escaping @Sendable (String) async throws -> String = { path in
            try await Task.detached { try String(contentsOfFile: path, encoding: .utf8) }.value
        }) {
            self.readFile = readFile
        }

        /// Resumes all pending continuations on shutdown to avoid leaked continuation warnings.
        public func cancelAll() {
            for (paneId, _) in activeSessions {
                logger.info("Cleaning up editor session for pane \(paneId) on shutdown")
            }
            for (_, continuation) in completionContinuations {
                continuation.resume(throwing: EditorSessionError.requestChanged)
            }
            completionContinuations.removeAll()
            activeSessions.removeAll()
            editedContents.removeAll()
            pendingReads.removeAll()
        }

        // MARK: - Public API

        /// Handles an editor.open API request. Blocks until the user submits or cancels.
        ///
        /// Called by the API request router. The router's response is held until
        /// this method returns, which happens when `submitSession` or `cancelSession`
        /// resumes the stored continuation.
        public func handleAPIEditRequest(paneId: String, filePath: String, expectedWorkspacePane: WorkspacePaneIdentity? = nil) async throws {
            let sessionId = UUID()
            pendingReads[paneId] = sessionId
            defer {
                if pendingReads[paneId] == sessionId {
                    pendingReads.removeValue(forKey: paneId)
                }
            }
            let content = try await readFile(filePath)
            try Task.checkCancellation()
            guard
                pendingReads[paneId] == sessionId,
                expectedWorkspacePane.map({ $0.isSamePane(as: currentPaneIdentity?(paneId)) }) ?? true else {
                throw EditorSessionError.requestChanged
            }

            // If there's already a session for this pane, complete the old one first
            if let existing = activeSessions[paneId] {
                logger.warning("Replacing existing editor session for pane \(paneId)")
                completionContinuations.removeValue(forKey: existing.id)?.resume(returning: ())
            }

            let session = EditorSession(
                id: sessionId,
                paneId: paneId,
                filePath: filePath,
                originalContent: content,
                workspaceIdentity: expectedWorkspacePane
            )
            activeSessions[paneId] = session
            editedContents[paneId] = content

            logger.info("Opened editor session for pane \(paneId)")

            // Bring app to front
            NSApplication.shared.activate(ignoringOtherApps: true)

            // Register completion before publishing: a Viewer can submit while
            // the state broadcast is suspended.
            try await withCheckedThrowingContinuation { continuation in
                completionContinuations[sessionId] = continuation
                Task { await onSessionChanged?() }
            }
        }

        /// Submits edited content, writes it to the file, and unblocks the API response.
        @discardableResult
        public func submitSession(paneId: String, content: String) -> Bool {
            do {
                try submit(session: currentSession(paneId: paneId, expectedSessionID: nil), content: content)
                return true
            } catch {
                logger.error("Failed to write edited content: \(error)")
                return false
            }
        }

        private func submit(session: EditorSession, content: String) throws {
            // Validation and writing do not suspend: replacement requests cannot
            // interleave, and a failed write leaves the request open for retry.
            try content.write(toFile: session.filePath, atomically: true, encoding: .utf8)
            let paneId = session.paneId
            activeSessions.removeValue(forKey: paneId)

            // Resume the continuation, which unblocks the API response
            completionContinuations.removeValue(forKey: session.id)?.resume(returning: ())
            editedContents.removeValue(forKey: paneId)
            logger.info("Submitted editor session for pane \(paneId)")

            // Notify viewers
            Task { await onSessionChanged?() }
        }

        /// Cancels an editor session without saving changes.
        /// The original content remains in the file, so Claude Code sees no change.
        public func cancelSession(paneId: String) {
            guard let session = activeSessions.removeValue(forKey: paneId) else {
                logger.warning("No active editor session for pane \(paneId)")
                return
            }

            // Resume the continuation, which unblocks the API response
            completionContinuations.removeValue(forKey: session.id)?.resume(returning: ())
            editedContents.removeValue(forKey: paneId)
            logger.info("Cancelled editor session for pane \(paneId)")

            // Notify viewers
            Task { await onSessionChanged?() }
        }

        /// Handles a remote viewer submitting editor content for a pane.
        public func handleRemoteSubmit(paneId: String, content: String, expectedSessionID: UUID? = nil) throws {
            try submit(session: currentSession(paneId: paneId, expectedSessionID: expectedSessionID), content: content)
        }

        /// Handles a remote viewer cancelling an editor session.
        public func handleRemoteCancel(paneId: String, expectedSessionID: UUID? = nil) throws {
            _ = try currentSession(paneId: paneId, expectedSessionID: expectedSessionID)
            cancelSession(paneId: paneId)
        }

        private func currentSession(paneId: String, expectedSessionID: UUID?) throws -> EditorSession {
            guard let session = session(for: paneId), expectedSessionID.map({ $0 == session.id }) ?? true else {
                throw EditorSessionError.requestChanged
            }
            return session
        }

        /// End old requests before publishing replacement panes, retaining only text.
        public func reconcilePaneIdentities() {
            for session in activeSessions.values {
                guard
                    let identity = session.workspaceIdentity,
                    !identity.isSamePane(as: currentPaneIdentity?(session.paneId)) else { continue }
                onSessionInvalidated?(session, editedContents[session.paneId] ?? session.originalContent)
                activeSessions.removeValue(forKey: session.paneId)
                editedContents.removeValue(forKey: session.paneId)
                completionContinuations.removeValue(forKey: session.id)?.resume(throwing: EditorSessionError.requestChanged)
            }
        }

        /// Returns the active editor session for a pane, if any.
        public func session(for paneId: String) -> EditorSession? {
            guard
                let session = activeSessions[paneId],
                session.workspaceIdentity.map({ $0.isSamePane(as: currentPaneIdentity?(paneId)) }) ?? true else { return nil }
            return session
        }

        /// Returns info about active editor sessions for inclusion in PaneState sync.
        public func editorSessionInfo(for paneId: String) -> EditorSessionInfo? {
            guard let session = session(for: paneId) else { return nil }
            return EditorSessionInfo(
                sessionId: session.id,
                content: session.originalContent
            )
        }
    }
#endif
