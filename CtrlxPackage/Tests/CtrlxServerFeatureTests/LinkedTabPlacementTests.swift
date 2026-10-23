#if os(macOS)
    import CtrlxNetworking
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Linked tab placement") @MainActor
    struct LinkedTabPlacementTests {
        @Test
        func reusedSimulatorStaysOnTheLeft() {
            let tabs = SessionFileTabsState()
            let simulatorID = UUID()
            tabs.rightSide = [.window("@1")]
            tabs.selectedBrowserTabId = simulatorID

            tabs.placeNewLinkedBrowserTab(simulatorID, sourceWindowID: "@1", isNew: false)
            let selectedLeft = tabs.selectLinkedBrowserTab(simulatorID)

            #expect(selectedLeft)
            #expect(tabs.rightSide == [.window("@1")])
            #expect(tabs.selectedBrowserTabId == simulatorID)
            #expect(tabs.selectedRight == nil)
        }

        @Test
        func newSimulatorFollowsSourceWithoutDuplicatingSelection() {
            let tabs = SessionFileTabsState()
            let simulatorID = UUID()
            tabs.rightSide = [.window("@1")]
            tabs.selectedBrowserTabId = simulatorID

            tabs.placeNewLinkedBrowserTab(simulatorID, sourceWindowID: "@1", isNew: true)
            let selectedLeft = tabs.selectLinkedBrowserTab(simulatorID)

            #expect(!selectedLeft)
            #expect(tabs.rightSide == [.window("@1"), .browser(simulatorID)])
            #expect(tabs.selectedBrowserTabId == nil)
            #expect(tabs.selectedRight == .browser(simulatorID))
        }

        @Test
        func preOpenSnapshotSeparatesAdditionalAndNewDevices() {
            let current = SessionFileTabsState()
            let extraID = UUID()
            let openedID = UUID()
            let extra = simulator(id: extraID, sourcePaneID: "%1")

            current.remoteSimulatorTabs[extraID] = extra
            let known = SessionFileTabsState.simulatorIDsBeforeOpening(
                current: current,
                hostSimulators: [extra],
                sessionName: "work"
            )

            current.remoteSimulatorTabs[openedID] = simulator(id: openedID, sourcePaneID: "%1")

            #expect(known == [extraID])
            #expect(!known.contains(openedID))
        }

        private func simulator(id: UUID, sourcePaneID: String) -> RemoteSimulatorTab {
            RemoteSimulatorTab(
                id: id,
                sessionName: "work",
                windowID: "@1",
                sourcePaneID: sourcePaneID,
                title: "iPhone",
                runtime: "iOS 27",
                isPrimary: false
            )
        }
    }
#endif
