enum TerminalInputPresentation {
    struct State: Equatable {
        let inputEnabled: Bool
        let keyboardRequested: Bool
    }

    static func resolve(
        keyboardRequested: Bool,
        isActive: Bool,
        isCopyPresented: Bool,
        isInputSuspended: Bool = false
    ) -> State {
        guard isActive, !isCopyPresented, !isInputSuspended else {
            return State(inputEnabled: false, keyboardRequested: false)
        }
        return State(inputEnabled: true, keyboardRequested: keyboardRequested)
    }
}

/// Defers the one-time initial tail reveal until UIKit has attached the native
/// terminal hierarchy and assigned it a real viewport. A run-loop yield is not
/// a layout-completion signal: input accessories can change the viewport again
/// after the representable returns.
struct TerminalInitialTailPresentationPolicy: Equatable {
    private var isPending = false

    mutating func request() {
        isPending = true
    }

    mutating func consumeIfReady(
        isAttachedToWindow: Bool,
        hasUsableBounds: Bool
    ) -> Bool {
        guard isPending, isAttachedToWindow, hasUsableBounds else { return false }
        isPending = false
        return true
    }
}
