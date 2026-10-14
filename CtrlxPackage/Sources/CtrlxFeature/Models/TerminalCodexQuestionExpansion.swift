import CtrlxCommon
import Dependencies
import Foundation

/// Event-driven, pane-local stability check. No observable state or output polling:
/// UIKit supplies the eligible live prompt; the Host remains the authority on
/// whether an intent may actually send Shift+Left (including cross-viewer dedup).
@MainActor
final class TerminalCodexQuestionExpansion {
    @Dependency(\.continuousClock) private var clock
    private let readPrompt: @MainActor () -> CodexQuestionPrompt?
    private let enqueue: @MainActor (Int, @escaping @MainActor (Bool) -> Void) -> Bool
    private var lastHandledCount: Int?
    private var questionID: String?
    private var inFlightID: UUID?
    private var candidate: CodexQuestionPrompt?
    private var generation: UInt64 = 0
    private var isInvalidated = false
    private var pendingTask: Task<Void, Never>?

    init(
        readPrompt: @escaping @MainActor () -> CodexQuestionPrompt?,
        enqueue: @escaping @MainActor (Int, @escaping @MainActor (Bool) -> Void) -> Bool
    ) {
        self.readPrompt = readPrompt
        self.enqueue = enqueue
    }

    deinit { pendingTask?.cancel() }

    func updateQuestionID(_ newID: String?) {
        guard questionID != newID else { return }
        questionID = newID
        lastHandledCount = nil
        inFlightID = nil
        cancelPending()
    }

    func schedule() {
        guard !isInvalidated else { return }
        guard let prompt = readPrompt(), prompt.count != lastHandledCount else {
            cancelPending()
            return
        }
        guard inFlightID == nil else { return }
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
            let requestID = UUID()
            inFlightID = requestID
            let queued = enqueue(prompt.count) { [weak self] handled in
                guard let self, !isInvalidated, inFlightID == requestID else { return }
                inFlightID = nil
                if handled {
                    lastHandledCount = prompt.count
                }
                // A failed attempt waits for a later native event, rather than
                // polling the same footer. Observe a changed queue immediately.
                if handled || readPrompt()?.count != prompt.count {
                    schedule()
                }
            }
            if !queued {
                inFlightID = nil
            }
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
        inFlightID = nil
        cancelPending()
    }
}
