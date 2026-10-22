import CtrlxCommon
import CtrlxNetworking
import Foundation
import Observation

/// Service managing state and logic for a single Claude session detail view.
///
/// This service encapsulates business logic for displaying and interacting with a session,
/// including terminal snapshots, response state management, and command sending.
/// It provides a live view of the session data from SessionStore, avoiding staleness issues.
///
/// The service uses `withObservationTracking` to reactively observe changes in `SessionStore`
/// and automatically update response state when the session's latest event changes.
@Observable
@MainActor
final public class SessionDetailService {
    // MARK: - Dependencies

    /// The pane ID for this session
    public let paneId: String

    /// The pair ID of the host this pane belongs to. Required to disambiguate
    /// panes with the same tmux ID (`%0`, `%1`, ...) coming from different hosts.
    public let hostId: String

    /// Reference to the session store for live session data
    private let sessionStore: SessionStore

    /// Reference to the relay client for communication
    private let relayClient: ViewerRelayClient
    private let onDraftChange: (@MainActor (UUID, String) -> Void)?
    private let onDraftSubmitted: (@MainActor (UUID, String) -> Void)?
    private let inputBinding: ViewerWorkspaceInputBinding

    // MARK: - Private State

    /// Tracks the last request ID we built response state for.
    private var lastProcessedRequestID: String?

    /// Task handling observation tracking (allows cancellation if needed)
    private var observationTask: Task<Void, Never>?

    // MARK: - Computed Properties

    /// Live session from store (always up-to-date via observation tracking)
    public var session: AgentSession? {
        sessionStore.session(for: paneId, hostId: hostId)
    }

    /// Whether the pane is currently active
    public var isPaneActive: Bool {
        sessionStore.isPaneActive(paneId: paneId, hostId: hostId)
    }

    /// Live OTEL telemetry for this pane (issue #597), or `nil` if none has
    /// arrived yet.
    public var telemetry: SessionTelemetry? {
        sessionStore.paneState(for: paneId, hostId: hostId)?.telemetry
    }

    /// Live permission mode for this pane (issue #597), or `nil` if no mode
    /// change has been observed.
    public var permissionMode: String? {
        sessionStore.paneState(for: paneId, hostId: hostId)?.permissionMode
    }

    /// What triggered the latest permission-mode change, if known.
    public var permissionModeTrigger: String? {
        sessionStore.paneState(for: paneId, hostId: hostId)?.permissionModeTrigger
    }

    /// End-of-turn recap for this pane (issue #598), or `nil` when the agent is
    /// mid-turn or has produced no telemetry.
    public var recap: SessionRecap? {
        sessionStore.paneState(for: paneId, hostId: hostId)?.recap
    }

    /// Whether the host is connected to the relay
    public var isHostConnected: Bool {
        relayClient.isHostConnected
    }

    /// Whether yolo mode is enabled for this pane (as reported by the host)
    public var isYoloModeEnabled: Bool {
        sessionStore.isYoloModeEnabled(paneId: paneId, hostId: hostId)
    }

    /// The relay client for this session (needed for environment injection)
    public var client: ViewerRelayClient {
        relayClient
    }

    // MARK: - Observable State

    /// Response state for the current event
    public var responseState: ResponseState?

    // MARK: - Initialization

    public init(
        paneId: String,
        hostId: String,
        sessionStore: SessionStore,
        relayClient: ViewerRelayClient,
        onDraftChange: (@MainActor (UUID, String) -> Void)? = nil,
        onDraftSubmitted: (@MainActor (UUID, String) -> Void)? = nil
    ) {
        self.paneId = paneId
        self.hostId = hostId
        self.sessionStore = sessionStore
        self.relayClient = relayClient
        self.onDraftChange = onDraftChange
        self.onDraftSubmitted = onDraftSubmitted
        self.inputBinding = relayClient.workspaceInputState.binding(paneID: paneId)

        // Perform initial update and start observation
        updateResponseState()
        startObservingSessionStore()
    }

    // MARK: - Observation

    /// Starts observing SessionStore for changes using withObservationTracking
    private func startObservingSessionStore() {
        // Cancel any existing observation task
        observationTask?.cancel()

        observationTask = Task { [weak self] in
            guard let self else { return }

            withObservationTracking {
                // Observe the session; its `state` carries the open response form.
                _ = self.sessionStore.session(for: self.paneId, hostId: self.hostId)
            } onChange: {
                // Schedule update on main actor when store changes
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.updateResponseState()
                    // Re-register for next change (withObservationTracking is single-shot)
                    self.startObservingSessionStore()
                }
            }
        }
    }

    /// Stable request id for the synthesized reply-after-stop box (see
    /// `updateResponseState`). Keyed per `(host, pane)` so it survives the brief
    /// `doneWorking → idle` flip that viewing triggers — keeping the reply field,
    /// its summary, and any typed text in place — and resets only when the agent
    /// resumes working.
    private var replyAfterStopRequestID: String {
        "\(hostId):\(paneId):reply-after-stop"
    }

    /// Updates response state from the session's `state`. Blocking forms ride the
    /// `awaiting*` cases' `openForm` (spec §5/§7.2). When the agent is stopped
    /// (`doneWorking`) or idle at the prompt, we synthesize a non-blocking
    /// reply-after-stop box so a remote user can reply or send a prompt — this is
    /// iOS-side only and deliberately does NOT ride `openForm`, which is reserved
    /// for blocking forms that gate host-side attention.
    private func updateResponseState() {
        let session = sessionStore.session(for: paneId, hostId: hostId)
        if let open = session?.state.openForm {
            applyForm(open.request, requestID: open.requestID, pluginID: session?.pluginID ?? "")
        } else if let session, let reply = replyForm(for: session.state) {
            applyForm(.replyAfterStop(reply), requestID: replyAfterStopRequestID, pluginID: session.pluginID)
        } else {
            clearResponseState()
        }
    }

    /// Builds the reply-after-stop box for the states that wait at the prompt.
    /// `doneWorking` carries the agent's last-message summary live; once the
    /// session has been viewed (`doneWorking → idle`) that summary is gone from
    /// the state, so we fall back to the persisted copy — keeping the agent's last
    /// message visible after navigating away and back (issue #707). A truly fresh
    /// `idle` session with no persisted summary has none. Working and
    /// blocking-form states get no reply box.
    private func replyForm(for state: AgentState) -> ReplyAfterStopRequest? {
        switch state {
        case let .doneWorking(summary):
            return ReplyAfterStopRequest(title: "Reply", summary: summary ?? persistedSummary)
        case .idle:
            return ReplyAfterStopRequest(title: "Reply", summary: persistedSummary)
        case .working,
             .awaitingPlanApproval,
             .awaitingPermission,
             .awaitingReplies:
            return nil
        }
    }

    /// The agent's last-turn summary that survives the handled-flip and
    /// navigation (issue #707): the per-pane cache first — freshest and
    /// independent of telemetry — then the end-of-turn recap, which covers a
    /// fresh reconnect where the cache hasn't been populated yet.
    private var persistedSummary: String? {
        sessionStore.lastTurnSummary(for: paneId, hostId: hostId) ?? recap?.summary
    }

    /// Builds `ResponseState` for a form, but only when the request id changes so
    /// the view (and its per-request `@State`) is preserved across no-op updates.
    private func applyForm(_ request: AgentResponseRequest, requestID: String, pluginID: String) {
        guard requestID != lastProcessedRequestID else { return }
        lastProcessedRequestID = requestID
        #if os(iOS)
            // reply-after-stop is a live composer, not a completed response.
            // Clear legacy optimistic feedback so navigating back never replaces
            // the composer with a stale "Prompt submitted" row.
            if case .replyAfterStop = request {
                sessionStore.setResponse(nil, forRequestID: requestID)
            }
        #endif
        // Pass sessionStore so ResponseState can persist/restore responses.
        responseState = ResponseState(
            request: request,
            pluginID: pluginID,
            requestID: requestID,
            sessionStore: sessionStore
        )
        if let state = responseState {
            state.onReplyDraftChange = { [onDraftChange, id = state.recoveryDraftID] text in onDraftChange?(id, text) }
        }
    }

    /// Clears the open form (the agent advanced to `working`, or the session is
    /// gone). Also drops any persisted reply for the synthesized box so the next
    /// stop starts with a fresh, empty reply field rather than the prior "sent"
    /// state.
    private func clearResponseState() {
        guard lastProcessedRequestID != nil else { return }
        // A Host transition invalidates the form, not the user's unsent text.
        responseState?.onReplyDraftChange = nil
        responseState?.replyDraft = ""
        #if os(iOS)
            sessionStore.setResponse(nil, forRequestID: replyAfterStopRequestID)
        #endif
        lastProcessedRequestID = nil
        responseState = nil
    }

    // MARK: - Actions

    /// Marks the session as handled locally and notifies the host
    public func markHandledIfNeeded() async {
        guard session?.needsAttention == true else { return }
        do {
            _ = try inputBinding.expectedPane(current: relayClient.workspaceInputState.binding(paneID: paneId))
        } catch { return }
        sessionStore.markSessionHandled(paneId: paneId, hostId: hostId)
        _ = await relayClient.sendCommand(MarkHandled(), paneId: paneId, inputBinding: inputBinding)
    }

    /// Send a command to the host for this pane (fire-and-forget style)
    public func sendCommand(_ command: CommandType) async {
        await relayClient.send(command, paneId: paneId, inputBinding: inputBinding)
    }

    /// Agent-agnostic keys for the synthesized reply composer. Empty text keeps
    /// the existing interrupt behavior; non-empty text gives the TUI one input
    /// cycle to commit its draft before Enter.
    static func replyAfterStopKeystrokes(for text: String) -> [TmuxKey] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? [.escape]
            : [.text(trimmed), .delay(200), .enter]
    }

    /// Clear only the draft whose command succeeded. A late response must not
    /// erase a newer composer that replaced the submitted state meanwhile.
    static func finishReplySubmission(
        succeeded: Bool,
        submittedState: ResponseState?,
        submittedDraft: String?,
        currentState: ResponseState?
    ) {
        guard
            succeeded, let submittedState, currentState === submittedState,
            submittedState.replyDraft == submittedDraft else { return }
        submittedState.replyDraft = ""
    }

    /// Submit a response for the open request. The synthesized reply-after-stop
    /// composer is agent-agnostic, so it uses the command channel directly: the
    /// viewer then waits for the host's tmux result instead of treating a socket
    /// write as success. Blocking plugin forms still use structured delivery.
    @discardableResult
    public func submitResponse(
        _ response: AgentResponse,
        pluginID: String,
        requestID: String
    ) async -> Bool {
        do {
            _ = try inputBinding.expectedPane(current: relayClient.workspaceInputState.binding(paneID: paneId))
        } catch { return false }
        guard responseState?.requestID == requestID, responseState?.pluginID == pluginID else { return false }
        if case let .replyAfterStop(text) = response {
            let submittedState = responseState
            let submittedDraft = submittedState?.replyDraft
            let keys = Self.replyAfterStopKeystrokes(for: text)
            let acknowledge: Bool? = if case .pane = inputBinding {
                true
            } else {
                nil
            }
            let result = await relayClient.sendCommand(SendKeystroke(keys, acknowledgeCompletion: acknowledge), paneId: paneId, inputBinding: inputBinding)
            let succeeded: Bool
            switch result {
            case let .success(response): succeeded = response.success
            case .failure: succeeded = false
            }
            if succeeded, let submittedState, let submittedDraft {
                onDraftSubmitted?(submittedState.recoveryDraftID, submittedDraft)
            }
            Self.finishReplySubmission(
                succeeded: succeeded,
                submittedState: submittedState,
                submittedDraft: submittedDraft,
                currentState: responseState
            )
            return succeeded
        } else {
            // The plugin channel confirms only transport, not native delivery.
            // Keep its authored text until explicitly discarded; never restore
            // the old request or guess that a disappearing form was submitted.
            return await relayClient.submitAgentResponse(
                sessionId: paneId,
                pluginId: pluginID,
                requestId: requestID,
                response: response,
                inputBinding: inputBinding
            )
        }
    }
}
