import CtrlxNetworking
import Foundation

/// Coalesces keystrokes that arrive within a single runloop turn into one
/// batch, then hands the batch to `flush` on the next turn.
///
/// The local terminal feeds keys here because SwiftTerm delivers a Meta/Option
/// sequence as **two synchronous `send()` callbacks** — a lone ESC, then the
/// key. Both land in the same runloop turn, so buffering them and flushing once
/// (on the next turn) keeps them in a single downstream `send-keys`, which the
/// app receives as one Meta keypress (e.g. Option-Backspace → ESC DEL → delete
/// word). Sent as two separate `send-keys` calls, tmux delivers a bare Escape
/// then Backspace and the app only deletes a single character.
///
/// Distinct keystrokes arrive in their own runloop turns and flush
/// independently, so this never merges separate presses — unlike a time-based
/// debounce (see `KeystrokeDebouncer`) it adds no perceptible latency to local
/// typing.
///
@MainActor
final class KeystrokeCoalescer {
    struct Batch: Sendable {
        let keys: [TmuxKey]
        let acceptedAt: ContinuousClock.Instant
    }

    private let flush: @MainActor (Batch) -> Void
    private var buffer: [TmuxKey] = []
    private var firstEnqueuedAt: ContinuousClock.Instant?
    private var flushScheduled = false

    /// - Parameter flush: invoked once per coalesced batch, on the main actor.
    init(flush: @escaping @MainActor (Batch) -> Void) {
        self.flush = flush
    }

    var hasPendingKeys: Bool {
        !buffer.isEmpty
    }

    /// Buffer `keys` and schedule a single flush for the next runloop turn.
    /// Calls within the same turn accumulate into that one flush.
    func enqueue(_ keys: [TmuxKey]) {
        guard !keys.isEmpty else { return }
        if buffer.isEmpty {
            firstEnqueuedAt = .now
        }
        buffer.append(contentsOf: keys)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.flushBufferedKeys()
        }
    }

    /// Flush any buffered keys immediately instead of waiting for the scheduled
    /// turn. A no-op when the buffer is empty. Use this when a non-key event
    /// (raw/mouse input, file drop) needs to be ordered *after* keystrokes that
    /// were buffered earlier in the same runloop turn: flushing here chains the
    /// buffered keys' send first, so the caller's send chains after it (FIFO).
    /// The already-scheduled flush still fires but finds an empty buffer and is
    /// a harmless no-op.
    func flushPending() {
        flushBufferedKeys()
    }

    /// Explicit toolbar input is one standalone batch, ordered after buffered
    /// keyboard input and before the next key. In particular, its delayed Return
    /// must not merge with a Meta sequence or an immediately-following key.
    func enqueueImmediately(_ keys: [TmuxKey]) {
        guard !keys.isEmpty else { return }
        flushBufferedKeys()
        flush(Batch(keys: keys, acceptedAt: .now))
    }

    /// Drop any buffered keys and clear the pending-flush flag (teardown).
    ///
    /// Any flush `Task` already scheduled still fires, but the snapshot-then-drain
    /// in `enqueue` plus the `guard !batch.isEmpty` make that a harmless no-op.
    /// Ordering *across* batches is the flush closure's responsibility (it chains
    /// the downstream sends), not the coalescer's.
    func reset() {
        buffer.removeAll()
        firstEnqueuedAt = nil
        flushScheduled = false
    }

    private func flushBufferedKeys() {
        guard !buffer.isEmpty, let acceptedAt = firstEnqueuedAt else { return }
        let batch = Batch(keys: buffer, acceptedAt: acceptedAt)
        buffer.removeAll(keepingCapacity: true)
        firstEnqueuedAt = nil
        flush(batch)
    }
}
