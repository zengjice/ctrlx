import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxFeature

@MainActor
@Suite("iOS device-local custom terminal buttons")
struct TerminalCustomButtonTests {
    @Test("Names, IDs, actions and order survive recreation; deletion only removes its own ID")
    func persistence() throws {
        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let store = TerminalCustomButtonStore()
            #expect(store.buttons.isEmpty)
            try store.add(name: "  Continue  ", action: .text("继续 👩‍💻"))
            try store.add(name: "Stop", action: .key(.ctrlC))
            // Independent buttons can deliberately have the same name.
            try store.add(name: "Stop", action: .key(.escape))
            try store.add(name: "Send", action: .text("继续", sendReturn: true))
            let saved = store.buttons
            #expect(saved.map(\.name) == ["Continue", "Stop", "Stop", "Send"])
            #expect(Set(saved.map(\.id)).count == 4)
            #expect(TerminalCustomButtonStore().buttons == saved)
            try store.remove(saved[1].id)
            #expect(TerminalCustomButtonStore().buttons == [saved[0], saved[2], saved[3]])
            try store.remove(saved[1].id)
            #expect(store.buttons == [saved[0], saved[2], saved[3]])
        }
    }

    @Test("Text defaults to literal input without Return and preserves meaningful spaces")
    func literalText() {
        for text in ["  echo 'hello world' ", "继续 👩‍💻", "$(whoami)", "/model", " "] {
            #expect(TerminalCustomButton.Action.text(text).keys == [.text(text)])
            #expect(TerminalCustomButton.Action.text(text, sendReturn: true).keys == [.text(text), .delay(200), .enter])
        }
    }

    @Test("All special keys use existing tmux key operations and survive persistence")
    func specialKeys() throws {
        let expected: [TmuxKey] = [
            .tab, .backtab, .escape, .enter, .space, .home, .end, .pageUp, .pageDown,
            .up, .down, .left, .right, .backspace, .delete,
            .ctrl("c"), .ctrl("d"), .ctrl("z"), .ctrl("l"), .ctrl("a"), .ctrl("e"), .ctrl("u"), .ctrl("k"), .ctrl("w"),
        ]
        #expect(TerminalCustomButton.Key.allCases.map(\.tmuxKey) == expected)
        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let store = TerminalCustomButtonStore()
            for key in TerminalCustomButton.Key.allCases {
                try store.add(name: key.title, action: .key(key))
            }
            #expect(store.buttons.map { $0.action.keys } == expected.map { [$0] })
            #expect(TerminalCustomButtonStore().buttons == store.buttons)
        }
    }

    @Test("Empty names or payloads and hidden terminal controls cannot be saved")
    func invalidInput() throws {
        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let store = TerminalCustomButtonStore()
            try store.add(name: "Test", action: .key(.tab))
            let saved = store.buttons
            for name in ["", "   ", "a\nb", "a\rb", "a\tb", "a\u{1B}b", "a\u{2028}b", "a\u{85}b"] {
                #expect(throws: (any Error).self) { try store.add(name: name, action: .key(.tab)) }
                #expect(store.buttons == saved)
            }
            for text in ["", "a\nb", "a\rb", "a\tb", "a\u{1B}b", "a\u{7F}b", "a\u{85}b", "a\u{2028}b"] {
                #expect(throws: (any Error).self) { try store.add(name: "Test", action: .text(text)) }
                #expect(store.buttons == saved)
            }
            #expect(TerminalCustomButtonStore().buttons == saved)
        }
    }

    @Test("Unreadable or invalid saved data is reported without being overwritten")
    func corruptStorage() throws {
        let button = TerminalCustomButton(name: "Test", action: .key(.tab))
        for data in [Data("broken".utf8),
                     try JSONEncoder().encode([button, button]),
                     try JSONEncoder().encode([TerminalCustomButton(name: "\n", action: .key(.tab))]),
                     try JSONEncoder().encode([TerminalCustomButton(name: "Test", action: .text("a\nb"))])] {
            let preferences = PreferencesService.inMemory()
            preferences.setData(data, TerminalCustomButtonStore.storageKey)
            withDependencies {
                $0[PreferencesService.self] = preferences
            } operation: {
                let store = TerminalCustomButtonStore()
                #expect(store.buttons.isEmpty)
                #expect(store.loadError != nil)
                #expect(throws: (any Error).self) { try store.add(name: "New", action: .key(.tab)) }
                #expect(preferences.data(TerminalCustomButtonStore.storageKey) == data)
            }
        }
    }

    @Test("Custom buttons are separate from the optionally synchronized phrase library")
    func separateLibrary() throws {
        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let phrases = QuickPhraseStore()
            let buttons = TerminalCustomButtonStore()
            try phrases.add("继续")
            try buttons.add(name: "Tab", action: .key(.tab))
            try buttons.remove(try #require(buttons.buttons.first).id)
            #expect(QuickPhraseStore().phrases == phrases.phrases)
            #expect(TerminalCustomButtonStore().buttons.isEmpty)
        }
    }

    private func context(host: String = "host", pane: String? = "%1", revision: UInt64 = 0,
                         connected: Bool = true, ready: Bool = true,
                         editor: Bool = false, form: Bool = false) -> TerminalPhraseContext {
        TerminalPhraseContext(hostID: host, paneID: pane, inputRevision: revision,
                              isConnected: connected, isInputAvailable: ready,
                              hasExternalEditor: editor, hasBlockingForm: form)
    }

    @Test("Ordinary terminals and agent windows share the same target and readiness checks")
    func sendGuards() {
        let button = TerminalCustomButton(name: "Continue", action: .text("继续", sendReturn: true))
        let request = TerminalCustomButtonRequest(button: button, context: context())
        #expect(request.isValid(in: context(), savedButtons: [button]))
        for invalid in [context(host: "other"), context(pane: "%2"), context(revision: 1),
                        context(pane: nil), context(connected: false), context(ready: false),
                        context(editor: true), context(form: true)] {
            #expect(!request.isValid(in: invalid, savedButtons: [button]))
            let blocked = TerminalCustomButtonRequest(button: button, context: invalid)
            #expect(!blocked.isValid(in: context(), savedButtons: [button]))
        }
        #expect(!request.isValid(in: context(), savedButtons: []))
        #expect(!request.isValid(in: context(), savedButtons: [TerminalCustomButton(name: button.name, action: button.action)]))
        #expect(!request.isValid(in: context(), savedButtons: [TerminalCustomButton(id: button.id, name: button.name, action: .key(.enter))]))
    }
}
