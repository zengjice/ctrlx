#if os(iOS)
    import Testing
    import UIKit
    @testable import CtrlxFeature

    @MainActor
    @Suite("Terminal keyboard dismissal viewport")
    struct TerminalKeyboardDismissalViewportTests {
        @Test("Keyboard dismissal rejects queued geometry and reports the final grid before Fit")
        func keyboardDismissalUsesFreshViewport() async {
            let coordinator = TerminalStreamContainerView.Coordinator()
            coordinator.cellSize = CGSize(width: 6, height: 13)
            var events: [String] = []
            coordinator.onViewportGridChange = { grid in events.append("grid:\(grid?.rows ?? 0)") }
            coordinator.onKeyboardDismissed = { events.append("fit") }
            coordinator.reportViewport(CGSize(width: 394, height: 390))
            await coordinator.viewportReportTask?.value

            coordinator.requestKeyboard(false)
            coordinator.reportViewport(CGSize(width: 394, height: 416))
            let staleMeasurement = coordinator.viewportReportTask
            coordinator.keyboardTransitionDidFinish(keyboardRequested: false)
            await staleMeasurement?.value
            #expect(events == ["grid:30"])
            coordinator.reportViewport(nil)
            #expect(events == ["grid:30"])

            coordinator.reportViewport(CGSize(width: 394, height: 780))
            await coordinator.viewportReportTask?.value
            #expect(events == ["grid:30", "grid:60", "fit"])
            coordinator.reportViewport(CGSize(width: 394, height: 793))
            await coordinator.viewportReportTask?.value
            #expect(events == ["grid:30", "grid:60", "fit", "grid:61"])
        }

        @Test("The final grid is refreshed even if its rounded size is unchanged")
        func keyboardDismissalRefreshesSameGrid() async {
            let coordinator = TerminalStreamContainerView.Coordinator()
            coordinator.cellSize = CGSize(width: 6, height: 13)
            let size = CGSize(width: 394, height: 390)
            var fits = 0
            var measurements = 0
            coordinator.onViewportGridChange = { _ in measurements += 1 }
            coordinator.onKeyboardDismissed = { fits += 1 }
            coordinator.reportViewport(size)
            await coordinator.viewportReportTask?.value
            coordinator.requestKeyboard(false)
            coordinator.keyboardTransitionDidFinish(keyboardRequested: false)
            coordinator.reportViewport(size)
            await coordinator.viewportReportTask?.value
            #expect(measurements == 2)
            #expect(fits == 1)
            coordinator.keyboardTransitionDidFinish(keyboardRequested: false)
            coordinator.reportViewport(size)
            await coordinator.viewportReportTask?.value
            #expect(measurements == 2)
            #expect(fits == 1)
        }

        @Test("A completion for visible input cannot finish keyboard dismissal")
        func waitsForHiddenInput() async {
            let coordinator = TerminalStreamContainerView.Coordinator()
            coordinator.cellSize = CGSize(width: 6, height: 13)
            var fits = 0
            coordinator.onKeyboardDismissed = { fits += 1 }
            coordinator.requestKeyboard(false)
            coordinator.keyboardTransitionDidFinish(keyboardRequested: true)
            let size = CGSize(width: 394, height: 780)
            coordinator.reportViewport(size)
            await coordinator.viewportReportTask?.value
            #expect(fits == 0)
            coordinator.keyboardTransitionDidFinish(keyboardRequested: false)
            coordinator.reportViewport(size)
            await coordinator.viewportReportTask?.value
            #expect(fits == 1)
        }

        @Test("Input suspension cancels before or after the animation", arguments: [false, true])
        func inputSuspensionCancels(settled: Bool) async {
            let coordinator = TerminalStreamContainerView.Coordinator()
            coordinator.cellSize = CGSize(width: 6, height: 13)
            var fits = 0
            coordinator.onKeyboardDismissed = { fits += 1 }
            coordinator.requestKeyboard(false)
            if settled {
                coordinator.keyboardTransitionDidFinish(keyboardRequested: false)
            }
            coordinator.updateInteraction(inputEnabled: false, keyboardRequested: false)
            coordinator.keyboardTransitionDidFinish(keyboardRequested: false)
            coordinator.reportViewport(CGSize(width: 394, height: 780))
            await coordinator.viewportReportTask?.value
            #expect(fits == 0)
        }
    }
#endif
