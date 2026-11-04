enum TerminalInputPresentation {
    struct State: Equatable {
        let inputEnabled: Bool
        let keyboardRequested: Bool

        var allowsKeyboardDismissalFit: Bool {
            inputEnabled && !keyboardRequested
        }
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

/// An editor borrows focus without making its own captured terminal input stale.
struct TerminalInputSuspension: Equatable {
    let external: Bool
    let quickActionEditor: Bool

    var suspendsInput: Bool {
        external || quickActionEditor
    }

    var invalidatesQuickActions: Bool {
        external
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

/// Only an explicit keyboard dismissal can arm Fit. Its final viewport must
/// be measured after UIKit finishes hiding the keyboard.
struct TerminalKeyboardDismissalFit {
    private enum Phase {
        case idle
        case waitingForKeyboard
        case waitingForViewport
    }

    private var phase = Phase.idle

    mutating func requestKeyboard(_ requested: Bool) {
        phase = requested ? .idle : .waitingForKeyboard
    }

    mutating func keyboardDidHide() -> Bool {
        guard phase == .waitingForKeyboard else { return false }
        phase = .waitingForViewport
        return true
    }

    mutating func consumeIfReady(hasViewport: Bool) -> Bool {
        guard phase == .waitingForViewport, hasViewport else { return false }
        phase = .idle
        return true
    }

    mutating func cancel() {
        phase = .idle
    }
}
