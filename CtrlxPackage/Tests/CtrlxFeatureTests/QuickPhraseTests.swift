import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxFeature

@MainActor
@Suite("Device-local quick phrases")
struct QuickPhraseTests {
    @Test("Phrases persist with stable IDs and order across store recreation")
    func persistence() throws {
        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let store = QuickPhraseStore()
            #expect(store.phrases.isEmpty)
            try store.add("  继续检查 👩‍💻  ")
            try store.add("git status")
            let saved = store.phrases
            #expect(saved.map(\.text) == ["继续检查 👩‍💻", "git status"])
            #expect(QuickPhraseStore().phrases == saved)
            try store.remove(saved[0].id)
            #expect(QuickPhraseStore().phrases == [saved[1]])
        }
    }

    @Test("Empty, duplicate and embedded control input cannot be saved")
    func invalidInput() throws {
        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let store = QuickPhraseStore()
            try store.add("继续")
            let saved = store.phrases
            for text in ["", " \n ", "继续", " 继续 ", "a\nb", "a\rb", "a\tb", "a\u{1b}b", "a\u{2028}b"] {
                #expect(throws: (any Error).self) { try store.add(text) }
                #expect(store.phrases == saved)
            }
            #expect(QuickPhraseStore().phrases == saved)
        }
    }

    @Test("Unreadable data is reported and preserved, never silently overwritten")
    func corruptStorage() throws {
        let duplicate = QuickPhrase(text: "hello")
        for data in [Data("broken".utf8),
                     try JSONEncoder().encode([duplicate, duplicate]),
                     try JSONEncoder().encode([QuickPhrase(text: "hello\n")])] {
            let preferences = PreferencesService.inMemory()
            preferences.setData(data, QuickPhraseStore.storageKey)
            withDependencies {
                $0[PreferencesService.self] = preferences
            } operation: {
                let store = QuickPhraseStore()
                #expect(store.loadError != nil)
                #expect(store.phrases.isEmpty)
                #expect(throws: (any Error).self) { try store.add("new") }
                #expect(preferences.data(QuickPhraseStore.storageKey) == data)
            }
        }
    }

    private func context(
        host: String = "host-a", pane: String? = "%1", revision: UInt64 = 0,
        connected: Bool = true, ready: Bool = true, editor: Bool = false, form: Bool = false
    ) -> TerminalPhraseContext {
        TerminalPhraseContext(hostID: host, paneID: pane, inputRevision: revision,
                              isConnected: connected, isInputAvailable: ready,
                              hasExternalEditor: editor, hasBlockingForm: form)
    }

    @Test("Ordinary shell panes need no AgentSession or slash-command catalog")
    func genericPanes() {
        let phrase = QuickPhrase(text: "pwd")
        for pane in ["%1", "%2", "%3"] {
            let current = context(pane: pane)
            let request = TerminalPhraseRequest(phrase: phrase, context: current)
            #expect(request.isValid(in: current, savedPhrases: [phrase]))
            #expect(request.phrase.keys == [.text("pwd"), .delay(200), .enter])
        }
    }

    @Test("Unavailable terminals remain browsable, but cannot submit")
    func availability() {
        let phrase = QuickPhrase(text: "继续")
        for blocked in [context(pane: nil), context(connected: false), context(ready: false),
                        context(editor: true), context(form: true)] {
            #expect(blocked.unavailableReason != nil)
            #expect(!blocked.canSend)
            let request = TerminalPhraseRequest(phrase: phrase, context: blocked)
            #expect(!request.isValid(in: blocked, savedPhrases: [phrase]))
        }
        #expect(context(connected: false).hasSameInput(as: context()))
        #expect(context(ready: false).hasSameInput(as: context()))
        #expect(context().canSend)
    }

    @Test("Stale pane, host, draft, deleted phrase and duplicate send actions are rejected")
    func staleSubmission() {
        let phrase = QuickPhrase(text: "继续")
        let request = TerminalPhraseRequest(phrase: phrase, context: context())
        #expect(request.isValid(in: context(), savedPhrases: [phrase]))
        for changed in [context(host: "host-b"), context(pane: "%2"), context(revision: 1),
                        context(connected: false), context(ready: false), context(form: true),
                        context(editor: true), context(pane: nil)] {
            #expect(!request.isValid(in: changed, savedPhrases: [phrase]))
        }
        #expect(!request.isValid(in: context(), savedPhrases: []))
        #expect(!request.isValid(in: context(), savedPhrases: [QuickPhrase(text: phrase.text)]))
        #expect(!request.isValid(in: context(), savedPhrases: [QuickPhrase(id: phrase.id, text: "changed")]))
    }

    @Test("One phrase queues literal text, host-side pause and one Return without clearing the draft")
    func keys() {
        for text in ["继续", "请检查这个改动 🙂", "/status", "echo 'hello world'"] {
            #expect(QuickPhrase(text: text).keys == [.text(text), .delay(200), .enter])
        }
    }
}
