#if os(iOS)
    import Testing
    import UIKit
    import UIKit.UIGestureRecognizerSubclass
    @testable import CtrlxFeature
    @testable import SwiftTerm

    @MainActor
    @Suite("Terminal selection navigation", .serialized)
    struct TerminalSelectionNavigationTests {
        @Test("Selection drags block native Back while retaining handles and scrolling", arguments: [false, true], [false, true])
        func selectionReservesNavigation(hasAdjacentWindow: Bool, fullscreen: Bool) async throws {
            let fixture = TerminalSelectionRoutingTests()
            let (window, terminal) = await fixture.makeView()
            defer { fixture.close(window, terminal) }
            let viewport = try #require(terminal.superview as? UIScrollView)
            let root = try #require(window.rootViewController)
            window.rootViewController = nil
            let navigation = UINavigationController()
            navigation.setViewControllers([UIViewController(), root], animated: false)
            window.rootViewController = navigation
            window.layoutIfNeeded()
            try #require(viewport.window === window)
            let swipe = TerminalWindowSwipeGesture(viewport: viewport, terminal: terminal)
            if hasAdjacentWindow {
                swipe.onSwitchWindow = { _ in }
            }
            let selectionGuard = TerminalSelectionNavigationGuard(terminal: terminal)
            viewport.addGestureRecognizer(selectionGuard)
            let edgeBack = try #require(navigation.interactivePopGestureRecognizer)
            let originalEnabled = edgeBack.isEnabled
            let originalDelegate = edgeBack.delegate
            var navigationGestures = [edgeBack]
            if #available(iOS 26.0, *), let contentBack = navigation.interactiveContentPopGestureRecognizer {
                navigationGestures.append(contentBack)
            }
            #expect(!selectionGuard.gestureRecognizer(selectionGuard, shouldReceive: UITouch()))
            #expect(!selectionGuard.gestureRecognizerShouldBegin(selectionGuard))
            terminal.feedTerminalData(Array(((fullscreen ? "\u{1b}[?1049h\u{1b}[?1000h" : "") + "selected text").utf8)[...])
            terminal.selectAll(nil)
            let handles = try #require(terminal.panSelectionGesture)
            #expect(handles.isEnabled && terminal.isScrollEnabled == !fullscreen)
            #expect(selectionGuard.gestureRecognizer(selectionGuard, shouldReceive: UITouch()))
            #expect(selectionGuard.gestureRecognizerShouldBegin(selectionGuard))
            for back in navigationGestures {
                #expect(selectionGuard.shouldBeRequiredToFail(by: back))
                #expect(selectionGuard.canPrevent(back))
            }
            for local in [handles, terminal.panGestureRecognizer, viewport.panGestureRecognizer, swipe.recognizer] {
                #expect(!selectionGuard.canPrevent(local))
                #expect(!selectionGuard.canBePrevented(by: local))
                #expect(!selectionGuard.shouldBeRequiredToFail(by: local))
            }
            #expect(!selectionGuard.cancelsTouchesInView && !selectionGuard.delaysTouchesBegan && !selectionGuard.delaysTouchesEnded)
            #expect(!swipe.canStart(at: CGPoint(x: 180, y: 200)))
            terminal.clearSelection()
            // Output clearing the selection cannot turn this drag into navigation.
            #expect(selectionGuard.gestureRecognizerShouldBegin(selectionGuard))
            selectionGuard.reset()
            #expect(!selectionGuard.gestureRecognizer(selectionGuard, shouldReceive: UITouch()))
            #expect(!selectionGuard.gestureRecognizerShouldBegin(selectionGuard))
            #expect(swipe.canStart(at: CGPoint(x: 180, y: 200)) == hasAdjacentWindow)
            #expect(terminal.isScrollEnabled == !fullscreen)
            #expect(edgeBack.isEnabled == originalEnabled && edgeBack.delegate === originalDelegate)
        }
    }
#endif
