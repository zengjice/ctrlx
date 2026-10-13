import Foundation
import Testing
@testable import CtrlxFeature

@Suite("Terminal link presentation")
struct TerminalLinkPresentationTests {
    @Test("Repeated taps keep the original URL until dismissal finishes")
    func repeatedTaps() throws {
        var presentation = TerminalLinkPresentation()
        let first = try #require(URL(string: "https://example.com/first"))
        let second = try #require(URL(string: "https://example.com/second"))
        let opened = presentation.present(first)
        #expect(opened)
        let id = try #require(presentation.item?.id)
        let replaced = presentation.present(second)
        #expect(!replaced)
        #expect(presentation.item?.id == id && presentation.item?.url == first)

        presentation.item = nil
        #expect(presentation.suspendsTerminalInput)
        let openedDuringDismissal = presentation.present(second)
        #expect(!openedDuringDismissal)
        presentation.didDismiss()
        #expect(!presentation.suspendsTerminalInput)
        let reopened = presentation.present(second)
        #expect(reopened)
        #expect(presentation.item?.id != id && presentation.item?.url == second)
    }

    @Test("File URLs do not open the browser picker")
    func rejectsFileURL() {
        var presentation = TerminalLinkPresentation()
        let opened = presentation.present(URL(fileURLWithPath: "/tmp/report.txt"))
        #expect(!opened)
        #expect(presentation.item == nil)
        #expect(!presentation.suspendsTerminalInput)
    }

    @Test("The picker suspends input through dismissal without losing keyboard intent", arguments: [false, true])
    func inputLifecycle(keyboardRequested: Bool) throws {
        var presentation = TerminalLinkPresentation()
        let url = try #require(URL(string: "https://example.com"))
        let opened = presentation.present(url)
        #expect(opened)
        for itemCleared in [false, true] {
            if itemCleared {
                presentation.item = nil
            }
            #expect(TerminalInputPresentation.resolve(
                keyboardRequested: keyboardRequested, isActive: true, isCopyPresented: false,
                isInputSuspended: presentation.suspendsTerminalInput
            ) == .init(inputEnabled: false, keyboardRequested: false))
        }
        presentation.didDismiss()
        #expect(TerminalInputPresentation.resolve(
            keyboardRequested: keyboardRequested, isActive: true, isCopyPresented: false,
            isInputSuspended: presentation.suspendsTerminalInput
        ) == .init(inputEnabled: true, keyboardRequested: keyboardRequested))
        #expect(TerminalInputPresentation.resolve(
            keyboardRequested: keyboardRequested, isActive: false, isCopyPresented: false,
            isInputSuspended: presentation.suspendsTerminalInput
        ) == .init(inputEnabled: false, keyboardRequested: false))
    }
}
