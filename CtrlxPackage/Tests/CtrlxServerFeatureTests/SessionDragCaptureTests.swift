#if os(macOS)
    import AppKit
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite("Session drag capture")
    struct SessionDragCaptureTests {
        @Test("Clicking or moving less than two points does not reorder")
        func clickIsNotDrag() throws {
            let view = SessionDragCaptureView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
            var callbacks = 0
            view.onChanged = { _ in callbacks += 1 }
            view.onEnded = { _ in callbacks += 1 }
            try send(.leftMouseDown, at: CGPoint(x: 5, y: 5), to: view)
            try send(.leftMouseDragged, at: CGPoint(x: 6, y: 5), to: view)
            try send(.leftMouseUp, at: CGPoint(x: 6, y: 5), to: view)
            #expect(callbacks == 0)
        }

        @Test("Release is delivered once in the same global coordinate space as the row frames")
        func completeMouseSequence() throws {
            let view = SessionDragCaptureView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
            view.globalOrigin = CGPoint(x: 400, y: 100)
            var changes: [CGPoint] = []
            var releases: [CGPoint] = []
            view.onChanged = { changes.append($0) }
            view.onEnded = { releases.append($0) }
            try send(.leftMouseDown, at: CGPoint(x: 5, y: 5), to: view)
            try send(.leftMouseDragged, at: CGPoint(x: 5, y: 30), to: view)
            try send(.leftMouseUp, at: CGPoint(x: 5, y: 60), to: view)
            try send(.leftMouseUp, at: CGPoint(x: 5, y: 60), to: view)
            #expect(changes == [CGPoint(x: 405, y: 130)])
            #expect(releases == [CGPoint(x: 405, y: 160)])
        }

        @Test("Dismantling cancels without submitting a move and the next drag remains usable")
        func cancelsAndRestarts() throws {
            let view = SessionDragCaptureView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
            var cancelled = 0
            var ended = 0
            view.onCancelled = { cancelled += 1 }
            view.onEnded = { _ in ended += 1 }
            try send(.leftMouseDown, at: .zero, to: view)
            try send(.leftMouseDragged, at: CGPoint(x: 0, y: 40), to: view)
            view.cancelDrag()
            view.cancelDrag()
            try send(.leftMouseUp, at: CGPoint(x: 0, y: 40), to: view)
            #expect(cancelled == 1)
            #expect(ended == 0)
            try send(.leftMouseDown, at: .zero, to: view)
            try send(.leftMouseDragged, at: CGPoint(x: 0, y: 40), to: view)
            try send(.leftMouseUp, at: CGPoint(x: 0, y: 40), to: view)
            #expect(ended == 1)
        }

        @Test("Updating callbacks during rendering does not lose a pending mouse release")
        func callbackUpdates() throws {
            let view = SessionDragCaptureView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
            var ended = 0
            try send(.leftMouseDown, at: .zero, to: view)
            try send(.leftMouseDragged, at: CGPoint(x: 0, y: 40), to: view)
            view.onEnded = { _ in ended += 1 }
            try send(.leftMouseUp, at: CGPoint(x: 0, y: 40), to: view)
            #expect(ended == 1)
        }

        private func send(_ type: NSEvent.EventType, at location: CGPoint, to view: NSView) throws {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: view.convert(location, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
    }
#endif
