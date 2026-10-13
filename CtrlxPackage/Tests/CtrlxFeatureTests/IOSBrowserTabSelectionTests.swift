import Foundation
import Testing
@testable import CtrlxFeature

@Suite("iOS Host browser close selection")
struct IOSBrowserTabSelectionTests {
    enum CloseEvent: Sendable {
        case reply
        case catalog
    }

    @Test("Closing the selected browser fits once in either message order", arguments: [
        [CloseEvent.catalog, .reply], [.reply, .catalog],
    ])
    func closeMessageOrder(events: [CloseEvent]) {
        let closed = UUID(), remaining = UUID()
        var selection = IOSBrowserTabSelection()
        selection.selectedID = closed
        selection.beginClosing(closed)
        #expect(selection.syncTabs([closed, remaining]) == false)

        var fitCount = 0
        var catalogArrived = false
        for event in events {
            switch event {
            case .reply:
                // Successful completion leaves selection to the catalog observer.
                #expect(selection.selectedID == (catalogArrived ? nil : closed))
                #expect(fitCount == (catalogArrived ? 1 : 0))
            case .catalog:
                if selection.syncTabs([remaining]) {
                    fitCount += 1
                }
                catalogArrived = true
                #expect(selection.selectedID == nil)
            }
        }
        #expect(fitCount == 1)
        #expect(selection.syncTabs([remaining]) == false)
    }

    @Test("Passive browser removal clears selection without fitting")
    func passiveRemoval() {
        var selection = IOSBrowserTabSelection()
        selection.selectedID = UUID()
        #expect(selection.syncTabs([]) == false)
        #expect(selection.selectedID == nil)
    }

    @Test("A failed close cannot grant a later Fit")
    func failedClose() {
        let closed = UUID()
        var selection = IOSBrowserTabSelection()
        selection.selectedID = closed
        selection.beginClosing(closed)
        selection.cancelClosing(closed)
        #expect(selection.selectedID == closed)
        #expect(selection.syncTabs([]) == false)
        #expect(selection.selectedID == nil)
    }

    @Test("Leaving the closing browser preserves the new selection", arguments: [false, true])
    func selectionChanged(selectAnotherBrowser: Bool) {
        let closed = UUID(), remaining = UUID()
        var selection = IOSBrowserTabSelection()
        selection.selectedID = closed
        selection.beginClosing(closed)
        // Selecting either a terminal or Files clears the browser selection.
        let nextSelection = selectAnotherBrowser ? remaining : nil
        selection.selectedID = nextSelection
        #expect(selection.syncTabs([remaining]) == false)
        #expect(selection.selectedID == nextSelection)
    }

    @Test("Closing an unselected browser does not fit or clear the selected one")
    func unselectedClose() {
        let closed = UUID(), selected = UUID()
        var selection = IOSBrowserTabSelection()
        selection.selectedID = selected
        selection.beginClosing(closed)
        #expect(selection.syncTabs([selected]) == false)
        #expect(selection.selectedID == selected)
    }

    @Test("Disconnect, backgrounding or page exit clears all pending close intents")
    func cancelPendingCloses() {
        let first = UUID(), second = UUID()
        var selection = IOSBrowserTabSelection()
        selection.selectedID = first
        selection.beginClosing(first)
        selection.beginClosing(second)
        selection.cancelPendingCloses()
        #expect(selection.syncTabs([second]) == false)
        selection.selectedID = second
        #expect(selection.syncTabs([]) == false)
    }

    @Test("A close intent is consumed even when its browser is no longer selected")
    func consumesUnselectedClose() {
        let closed = UUID()
        var selection = IOSBrowserTabSelection()
        selection.beginClosing(closed)
        #expect(selection.syncTabs([]) == false)
        selection.selectedID = closed
        #expect(selection.syncTabs([closed]) == false)
        #expect(selection.syncTabs([]) == false)
    }
}
