import CtrlxCommon
import Dependencies

/// Event-driven, pane-local stability check. No observable state or output polling:
/// UIKit supplies the eligible live prompt; the Host remains the authority on
/// whether an intent may actually send Shift+Left (including cross-viewer dedup).
@MainActor
final class TerminalCodexQuestionExpansion {
    @Dependency(\.continuousClock) private var clock
    private let readPrompt: @MainActor () -> CodexQuestionPrompt?
    private let enqueue: @MainActor (Int) -> Bool
    private var lastEnqueuedCount: Int?
    private var candidate: CodexQuestionPrompt?
    private var generation: UInt64 = 0
    private var isInvalidated = false
    private var pendingTask: Task<Void, Never>?

    init(
        readPrompt: @escaping @MainActor () -> CodexQuestionPrompt?,
        enqueue: @escaping @MainActor (Int) -> Bool
    ) {
        self.readPrompt = readPrompt
        self.enqueue = enqueue
    }

    deinit { pendingTask?.cancel() }

    func schedule() {
        guard !isInvalidated else { return }
        guard let prompt = readPrompt(), prompt.count != lastEnqueuedCount else {
            cancelPending()
            return
        }
        guard candidate != prompt else { return }
        cancelPending()
        candidate = prompt
        let token = generation
        let clock = clock
        pendingTask = Task { @MainActor [weak self] in
            do { try await clock.sleep(for: .milliseconds(350)) }
            catch { return }
            guard let self, !Task.isCancelled, generation == token else { return }
            pendingTask = nil
            candidate = nil
            guard readPrompt() == prompt else {
                schedule()
                return
            }
            // Reductions/zero must also reach the Host to update its baseline.
            // A temporarily unavailable stream must not consume this attempt.
            if enqueue(prompt.count) { lastEnqueuedCount = prompt.count }
        }
    }

    func cancelPending() {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
        candidate = nil
    }

    func invalidate() {
        isInvalidated = true
        cancelPending()
    }
}
