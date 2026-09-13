import Testing
@testable import CtrlxFeature

@MainActor
@Suite("Terminal deferred focus updates")
struct TerminalInputFocusUpdatesTests {
    private let active = TerminalInputPresentation.State(inputEnabled: true, keyboardRequested: false)
    private let keyboard = TerminalInputPresentation.State(inputEnabled: true, keyboardRequested: true)
    private let inactive = TerminalInputPresentation.State(inputEnabled: false, keyboardRequested: false)

    @Test("Mounting and updating never change focus synchronously")
    func defersFocus() async {
        var calls: [TerminalInputPresentation.State] = []
        let updates = TerminalInputFocusUpdates { calls.append($0); return true }
        updates.request(active)
        #expect(updates.pendingTask == nil)
        updates.setAttached(true)
        #expect(calls.isEmpty)
        await updates.pendingTask?.value
        #expect(calls == [active])
    }

    @Test("An update burst applies only its final pane and keyboard intent")
    func coalesces() async {
        var calls: [TerminalInputPresentation.State] = []
        let updates = TerminalInputFocusUpdates { calls.append($0); return true }
        updates.setAttached(true)
        updates.request(active)
        updates.request(inactive)
        updates.request(keyboard)
        #expect(calls.isEmpty)
        await updates.pendingTask?.value
        #expect(calls == [keyboard])
        updates.request(keyboard)
        #expect(updates.pendingTask == nil)
        #expect(calls == [keyboard])
    }

    @Test("Returning to the applied state cancels an obsolete request")
    func cancelsObsoleteRequest() async {
        var calls: [TerminalInputPresentation.State] = []
        let updates = TerminalInputFocusUpdates { calls.append($0); return true }
        updates.setAttached(true)
        updates.request(active)
        await updates.pendingTask?.value
        updates.request(keyboard)
        let obsolete = updates.pendingTask
        updates.request(active)
        await obsolete?.value
        #expect(calls == [active])
        #expect(updates.pendingTask == nil)
    }

    @Test("Detaching cancels acquisition; reattaching uses the latest state")
    func detachesAndReattaches() async {
        var calls: [TerminalInputPresentation.State] = []
        let updates = TerminalInputFocusUpdates { calls.append($0); return true }
        updates.setAttached(true)
        updates.request(active)
        let detachedTask = updates.pendingTask
        updates.setAttached(false)
        updates.request(keyboard)
        await detachedTask?.value
        #expect(calls.isEmpty)
        updates.setAttached(true)
        #expect(calls.isEmpty)
        await updates.pendingTask?.value
        #expect(calls == [keyboard])
    }

    @Test("Reattachment reapplies even unchanged intent")
    func reattachmentInvalidatesAppliedState() async {
        var calls: [TerminalInputPresentation.State] = []
        let updates = TerminalInputFocusUpdates { calls.append($0); return true }
        updates.request(active)
        updates.setAttached(true)
        await updates.pendingTask?.value
        updates.setAttached(false)
        updates.setAttached(true)
        await updates.pendingTask?.value
        #expect(calls == [active, active])
    }

    @Test("Dismantling permanently prevents delayed focus acquisition")
    func dismantles() async {
        var calls: [TerminalInputPresentation.State] = []
        let updates = TerminalInputFocusUpdates { calls.append($0); return true }
        updates.setAttached(true)
        updates.request(active)
        let obsolete = updates.pendingTask
        updates.invalidate()
        updates.setAttached(false)
        updates.setAttached(true)
        updates.request(keyboard)
        await obsolete?.value
        #expect(calls.isEmpty)
        #expect(updates.pendingTask == nil)
    }

    @Test("A failed acquisition may retry on a later request, never in a loop")
    func failedAcquisition() async {
        var calls = 0
        let updates = TerminalInputFocusUpdates { _ in calls += 1; return calls > 1 }
        updates.setAttached(true)
        updates.request(active)
        await updates.pendingTask?.value
        #expect(calls == 1)
        #expect(updates.pendingTask == nil)
        updates.request(active)
        await updates.pendingTask?.value
        #expect(calls == 2)
        updates.request(active)
        #expect(updates.pendingTask == nil)
    }

    @Test("Two panes hand focus over without applying intermediate selections")
    func multiPaneHandoff() async {
        var firstStates: [TerminalInputPresentation.State] = []
        var secondStates: [TerminalInputPresentation.State] = []
        let first = TerminalInputFocusUpdates { firstStates.append($0); return true }
        let second = TerminalInputFocusUpdates { secondStates.append($0); return true }
        first.setAttached(true)
        second.setAttached(true)
        first.request(active)
        second.request(inactive)
        await first.pendingTask?.value
        await second.pendingTask?.value
        first.request(inactive)
        second.request(active)
        first.request(active)
        second.request(inactive)
        first.request(inactive)
        second.request(keyboard)
        #expect(firstStates == [active])
        #expect(secondStates == [inactive])
        await first.pendingTask?.value
        await second.pendingTask?.value
        #expect(firstStates == [active, inactive])
        #expect(secondStates == [inactive, keyboard])
    }

    @Test("Opening and closing the copy page defers both focus transitions")
    func copyPage() async {
        var calls: [TerminalInputPresentation.State] = []
        let updates = TerminalInputFocusUpdates { calls.append($0); return true }
        updates.setAttached(true)
        updates.request(keyboard)
        await updates.pendingTask?.value
        updates.request(.init(inputEnabled: false, keyboardRequested: false))
        #expect(calls == [keyboard])
        await updates.pendingTask?.value
        updates.request(keyboard)
        #expect(calls == [keyboard, inactive])
        await updates.pendingTask?.value
        #expect(calls == [keyboard, inactive, keyboard])
    }

    @Test("A lifecycle callback during acquisition cannot mark a detached state applied")
    func reentrantDetach() async {
        var calls = 0
        var updates: TerminalInputFocusUpdates?
        updates = TerminalInputFocusUpdates { _ in
            calls += 1
            if calls == 1 { updates?.setAttached(false) }
            return true
        }
        updates?.request(active)
        updates?.setAttached(true)
        await updates?.pendingTask?.value
        updates?.setAttached(true)
        await updates?.pendingTask?.value
        #expect(calls == 2)
        updates = nil
    }

    @Test("A focus callback's newer request is applied on a separate turn")
    func reentrantRequest() async {
        var calls: [TerminalInputPresentation.State] = []
        var updates: TerminalInputFocusUpdates?
        updates = TerminalInputFocusUpdates { state in
            calls.append(state)
            if state == active { updates?.request(inactive) }
            return true
        }
        updates?.setAttached(true)
        await updates?.pendingTask?.value
        updates?.request(active)
        await updates?.pendingTask?.value
        await updates?.pendingTask?.value
        #expect(calls == [inactive, active, inactive])
        updates = nil
    }
}

#if os(iOS)
    import UIKit

    @MainActor
    @Suite("Terminal native multi-pane focus", .serialized)
    struct TerminalNativeFocusTests {
        @Test("Pane handoff defers UIKit focus and immediately drops old-pane input")
        func handoff() async throws {
            let fixture = TerminalSelectionRoutingTests()
            let (window, first) = await fixture.makeView()
            defer { fixture.close(window, first) }
            let viewport = try #require(first.superview as? UIScrollView)
            let firstProxy = try #require(viewport.subviews.compactMap { $0 as? TerminalInputProxyView }.first)
            let second = InteractiveTerminalView(frame: first.frame, font: nil)
            viewport.addSubview(second)
            second.attachInputProxy(to: viewport)
            defer { second.invalidateInput(); second.updateUiClosed() }
            let secondProxy = try #require(viewport.subviews.compactMap { $0 as? TerminalInputProxyView }
                .first { $0 !== firstProxy })
            #expect(firstProxy.isFirstResponder)
            #expect(!secondProxy.isFirstResponder)

            var firstKeyBatches = 0
            var secondKeyBatches = 0
            first.onInput = { _ in firstKeyBatches += 1 }
            second.onInput = { _ in secondKeyBatches += 1 }
            first.updateInput(isEnabled: false, keyboardRequested: false)
            second.updateInput(isEnabled: true, keyboardRequested: false)
            #expect(firstProxy.isFirstResponder)
            #expect(!secondProxy.isFirstResponder)
            firstProxy.insertText("stale")
            first.send(source: first, data: [0x1B]) // A stale accessory event.
            #expect(firstKeyBatches == 0)
            await first.inputFocusUpdates.pendingTask?.value
            await second.inputFocusUpdates.pendingTask?.value
            #expect(!firstProxy.isFirstResponder)
            #expect(secondProxy.isFirstResponder)
            secondProxy.insertText("ok")
            #expect(secondKeyBatches > 0)

            // A fast switch back and forth must not leave the old pane focused.
            second.updateInput(isEnabled: false, keyboardRequested: false)
            first.updateInput(isEnabled: true, keyboardRequested: false)
            let obsolete = first.inputFocusUpdates.pendingTask
            first.updateInput(isEnabled: false, keyboardRequested: false)
            second.updateInput(isEnabled: true, keyboardRequested: false)
            await obsolete?.value
            await second.inputFocusUpdates.pendingTask?.value
            #expect(secondProxy.isFirstResponder)
            #expect(!firstProxy.isFirstResponder)
        }

        @Test("Dismantling while still mounted prevents delayed acquisition")
        func dismantlesBeforeRemoval() async {
            let fixture = TerminalSelectionRoutingTests()
            let (window, view) = await fixture.makeView()
            defer { fixture.close(window, view) }
            view.updateInput(isEnabled: false, keyboardRequested: false)
            await view.inputFocusUpdates.pendingTask?.value
            view.updateInput(isEnabled: true, keyboardRequested: false)
            let obsolete = view.inputFocusUpdates.pendingTask
            view.invalidateInput()
            view.updateInput(isEnabled: true, keyboardRequested: true)
            await obsolete?.value
            #expect(!view.inputEnabled)
            #expect(view.inputFocusUpdates.pendingTask == nil)
        }
    }
#endif
