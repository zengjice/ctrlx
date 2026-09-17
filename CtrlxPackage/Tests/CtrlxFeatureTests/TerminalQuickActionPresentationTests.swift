import CtrlxCommon
import CtrlxNetworking
import Testing
@testable import CtrlxFeature

@Suite("Terminal quick action overlay presentation")
struct TerminalQuickActionPresentationTests {
    private func phrase(pane: String = "%1", revision: UInt64 = 0, connected: Bool = true) -> TerminalPhraseContext {
        TerminalPhraseContext(hostID: "host", paneID: pane, inputRevision: revision,
                              isConnected: connected, isInputAvailable: true)
    }

    private func command(pane: String = "%1", revision: UInt64 = 0, plugin: String = "codex",
                         connected: Bool = true) throws -> AgentCommandContext {
        try #require(AgentCommandContext(
            hostID: "host", paneID: pane, session: AgentSession(paneId: pane, pluginID: plugin),
            isConnected: connected, isInputAvailable: true, hasExternalEditor: false, inputRevision: revision
        ))
    }

    @Test("The same toolbar button opens, closes and reopens either panel")
    func toggleSamePanel() throws {
        for panel in [TerminalQuickActionPresentation.Panel.commands(try command()), .phrases(phrase())] {
            var presentation = TerminalQuickActionPresentation()
            for _ in 0 ..< 5 {
                presentation.toggle(panel)
                #expect(presentation.panel == panel)
                #expect(!presentation.suspendsTerminalInput)
                presentation.toggle(panel)
                #expect(!presentation.isPresented)
                #expect(!presentation.isEditingPhrase)
            }
        }
    }

    @Test("Tapping the other toolbar button switches directly and preserves its target")
    func toggleOtherPanel() throws {
        var presentation = TerminalQuickActionPresentation()
        let commands = TerminalQuickActionPresentation.Panel.commands(try command())
        let phrases = TerminalQuickActionPresentation.Panel.phrases(phrase())
        for panel in [commands, phrases, commands, phrases] {
            presentation.toggle(panel)
            #expect(presentation.panel == panel)
            #expect(!presentation.suspendsTerminalInput)
        }
    }

    @Test("Connection changes do not turn the close button into a reopen action")
    func toggleAfterAvailabilityChange() throws {
        var presentation = TerminalQuickActionPresentation()
        presentation.toggle(.commands(try command()))
        presentation.toggle(.commands(try command(connected: false)))
        #expect(!presentation.isPresented)
        presentation.toggle(.phrases(phrase()))
        presentation.toggle(.phrases(phrase(connected: false)))
        #expect(!presentation.isPresented)
    }

    @Test("Toolbar toggles can close or switch out of the phrase editor")
    func toggleOutOfEditor() throws {
        for panel in [TerminalQuickActionPresentation.Panel.phrases(phrase()), .commands(try command())] {
            var presentation = TerminalQuickActionPresentation()
            presentation.toggle(.phrases(phrase()))
            presentation.isEditingPhrase = true
            #expect(presentation.suspendsTerminalInput)
            presentation.toggle(panel)
            #expect(!presentation.isEditingPhrase)
            #expect(!presentation.suspendsTerminalInput)
            if case .phrases = panel {
                #expect(!presentation.isPresented)
            } else {
                #expect(presentation.panel == panel)
            }
        }
    }

    @MainActor
    @Test("Opening, switching and dismissing panels never changes terminal focus", arguments: [false, true])
    func browsingPreservesInput(keyboardRequested: Bool) async throws {
        var presentation = TerminalQuickActionPresentation()
        var applied: [TerminalInputPresentation.State] = []
        let updates = TerminalInputFocusUpdates { applied.append($0); return true }
        let initial = TerminalInputPresentation.resolve(
            keyboardRequested: keyboardRequested, isActive: true, isCopyPresented: false
        )
        updates.setAttached(true)
        updates.request(initial)
        await updates.pendingTask?.value

        for panel in [TerminalQuickActionPresentation.Panel.commands(try command()), .phrases(phrase())] {
            presentation.show(panel)
            #expect(presentation.isPresented)
            #expect(!presentation.suspendsTerminalInput)
            let input = TerminalInputPresentation.resolve(
                keyboardRequested: keyboardRequested, isActive: true, isCopyPresented: false,
                isInputSuspended: presentation.suspendsTerminalInput
            )
            #expect(input == initial)
            updates.request(input)
            #expect(updates.pendingTask == nil)
        }
        presentation.dismiss()
        #expect(!presentation.isPresented)
        #expect(!presentation.suspendsTerminalInput)
        updates.request(TerminalInputPresentation.resolve(
            keyboardRequested: keyboardRequested, isActive: true, isCopyPresented: false,
            isInputSuspended: presentation.suspendsTerminalInput
        ))
        #expect(updates.pendingTask == nil)
        #expect(applied == [initial])
    }

    @Test("Only the phrase editor borrows focus; returning restores the original keyboard intent", arguments: [false, true])
    func editorFocus(keyboardRequested: Bool) {
        var presentation = TerminalQuickActionPresentation()
        presentation.show(.phrases(phrase()))
        presentation.isEditingPhrase = true
        #expect(presentation.suspendsTerminalInput)
        #expect(TerminalInputPresentation.resolve(
            keyboardRequested: keyboardRequested, isActive: true, isCopyPresented: false,
            isInputSuspended: presentation.suspendsTerminalInput
        ) == .init(inputEnabled: false, keyboardRequested: false))
        presentation.isEditingPhrase = false
        #expect(presentation.isPresented)
        #expect(TerminalInputPresentation.resolve(
            keyboardRequested: keyboardRequested, isActive: true, isCopyPresented: false,
            isInputSuspended: presentation.suspendsTerminalInput
        ) == .init(inputEnabled: true, keyboardRequested: keyboardRequested))
    }

    @Test("Closing or switching away from the editor cannot leave terminal input suspended")
    func editorTeardown() throws {
        var presentation = TerminalQuickActionPresentation()
        presentation.show(.phrases(phrase()))
        presentation.isEditingPhrase = true
        presentation.show(.commands(try command()))
        #expect(!presentation.isEditingPhrase)
        #expect(!presentation.suspendsTerminalInput)
        presentation.show(.phrases(phrase()))
        presentation.isEditingPhrase = true
        presentation.dismiss()
        #expect(!presentation.isEditingPhrase)
        #expect(!presentation.suspendsTerminalInput)
    }

    @Test("Availability changes keep panels open, preserving their captured targets")
    func availability() throws {
        for panel in [TerminalQuickActionPresentation.Panel.commands(try command()), .phrases(phrase())] {
            var presentation = TerminalQuickActionPresentation()
            presentation.show(panel)
            for connected in [false, true] {
                presentation.validate(phraseContext: phrase(connected: connected), commandContext: try command(connected: connected))
                #expect(presentation.panel == panel)
                #expect(!presentation.suspendsTerminalInput)
            }
        }
    }

    @Test("Changing pane or local input closes either panel and clears editor state")
    func staleInput() throws {
        for panel in [TerminalQuickActionPresentation.Panel.commands(try command()), .phrases(phrase())] {
            for (pane, revision) in [("%2", UInt64(0)), ("%1", UInt64(1))] {
                var presentation = TerminalQuickActionPresentation()
                presentation.show(panel)
                presentation.isEditingPhrase = true
                presentation.validate(phraseContext: phrase(pane: pane, revision: revision),
                                      commandContext: try command(pane: pane, revision: revision))
                #expect(!presentation.isPresented)
                #expect(!presentation.isEditingPhrase)
            }
        }
    }

    @Test("Agent loss or replacement closes commands but does not prevent shell phrases")
    func agentChange() throws {
        for changed in [nil, try command(plugin: "claude-code")] {
            var presentation = TerminalQuickActionPresentation()
            presentation.show(.commands(try command()))
            presentation.validate(phraseContext: phrase(), commandContext: changed)
            #expect(!presentation.isPresented)
            presentation.show(.phrases(phrase()))
            presentation.validate(phraseContext: phrase(), commandContext: changed)
            #expect(presentation.isPresented)
        }
    }

    @Test("Browsing cannot override an inactive pane or a copy sheet")
    func preservesOtherInputGuards() throws {
        for panel in [TerminalQuickActionPresentation.Panel.commands(try command()), .phrases(phrase())] {
            var presentation = TerminalQuickActionPresentation()
            presentation.show(panel)
            for (active, copy) in [(false, false), (true, true)] {
                #expect(TerminalInputPresentation.resolve(
                    keyboardRequested: true, isActive: active, isCopyPresented: copy,
                    isInputSuspended: presentation.suspendsTerminalInput
                ) == .init(inputEnabled: false, keyboardRequested: false))
            }
        }
    }
}
