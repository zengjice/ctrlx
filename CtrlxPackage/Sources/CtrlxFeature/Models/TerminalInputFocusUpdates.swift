/// Keeps UIKit responder changes out of SwiftUI's synchronous view updates.
/// Each terminal owns one instance; a queued update reads the latest intent,
/// never the active-pane state captured by an earlier render.
@MainActor
final class TerminalInputFocusUpdates {
    typealias State = TerminalInputPresentation.State

    private var requested = State(inputEnabled: false, keyboardRequested: false)
    private var applied: State?
    private var isAttached = false
    private var isApplying = false
    private(set) var isInvalidated = false
    private var generation: UInt64 = 0
    private let apply: @MainActor (State) -> Bool
    private(set) var pendingTask: Task<Void, Never>?

    init(apply: @escaping @MainActor (State) -> Bool) {
        self.apply = apply
    }

    deinit {
        pendingTask?.cancel()
    }

    func request(_ state: State) {
        guard !isInvalidated else { return }
        requested = state
        scheduleIfNeeded()
    }

    func setAttached(_ attached: Bool) {
        guard !isInvalidated, isAttached != attached else { return }
        isAttached = attached
        applied = nil
        cancelPending()
        scheduleIfNeeded()
    }

    /// Dismantled representables must never reclaim focus, even if UIKit has
    /// not removed their native views from the window yet.
    func invalidate() {
        isInvalidated = true
        cancelPending()
    }

    private func cancelPending() {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
    }

    private func scheduleIfNeeded() {
        guard !isApplying else { return }
        guard isAttached, !isInvalidated, requested != applied else {
            cancelPending()
            return
        }
        guard pendingTask == nil else { return }
        let token = generation
        pendingTask = Task { @MainActor [weak self] in
            // Explicit suspension also protects callers if task execution is
            // eager. No fixed delay, polling, or terminal-output dependency.
            await Task.yield()
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.pendingTask = nil
            guard self.isAttached, !self.isInvalidated, self.requested != self.applied else { return }
            let state = self.requested
            self.isApplying = true
            let succeeded = self.apply(state)
            self.isApplying = false
            // UIKit may call back into lifecycle methods during focus changes.
            // A failed acquisition or detached view is not an applied request.
            if succeeded, self.generation == token, !self.isInvalidated {
                self.applied = state
            }
            if self.requested != state || self.generation != token {
                self.scheduleIfNeeded()
            }
        }
    }
}
