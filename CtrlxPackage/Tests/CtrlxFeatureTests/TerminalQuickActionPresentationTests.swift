import CtrlxCommon
import CtrlxNetworking
import Testing
@testable import CtrlxFeature

@Suite("Terminal quick action overlay presentation")
struct TerminalQuickActionPresentationTests {
    private func phrase(host: String = "host", pane: String? = "%1", revision: UInt64 = 0, connected: Bool = true) -> TerminalPhraseContext {
        TerminalPhraseContext(
            hostID: host,
            paneID: pane,
            inputRevision: revision,
            isConnected: connected,
            isInputAvailable: true
        )
    }

    private func command(
        host: String = "host",
        pane: String = "%1",
        revision: UInt64 = 0,
        plugin: String = "codex",
        connected: Bool = true
    ) throws -> AgentCommandContext {
        try #require(AgentCommandContext(
            hostID: host, paneID: pane, session: AgentSession(paneId: pane, pluginID: plugin),
            isConnected: connected, isInputAvailable: true, hasExternalEditor: false, inputRevision: revision
        ))
    }

    @Test("Model controls open independently from slash commands and keep terminal input available")
    func independentModelPanel() {
        let pane = WorkspacePaneIdentity(serverID: "server", sessionID: .init(), windowID: .init(), paneID: .init())
        let captured = TerminalAgentModelPresentation(context: phrase(), pluginID: "other-agent", pane: pane)
        var presentation = TerminalQuickActionPresentation()
        presentation.toggle(.models(captured))
        presentation.validate(phraseContext: phrase(), commandContext: nil, modelPane: pane, modelPluginID: "other-agent")
        #expect(presentation.panel == .models(captured))
        #expect(!presentation.suspendsTerminalInput)
        presentation.toggleCommands(context: nil, terminal: phrase())
        #expect(presentation.panel == .commandsUnavailable(phrase()))
        presentation.toggle(.models(captured))
        #expect(presentation.panel == .models(captured))
        presentation.toggle(.models(.init(context: phrase(connected: false), pluginID: "other-agent", pane: pane)))
        #expect(!presentation.isPresented)
    }

    @Test("A model panel survives availability changes, but not a replaced Host, pane, agent or local input")
    func modelTargetValidation() {
        let pane = WorkspacePaneIdentity(serverID: "server", sessionID: .init(), windowID: .init(), paneID: .init())
        let captured = TerminalAgentModelPresentation(context: phrase(), pluginID: "codex", pane: pane)
        var presentation = TerminalQuickActionPresentation()
        presentation.show(.models(captured))
        presentation.validate(phraseContext: phrase(connected: false), commandContext: nil, modelPane: pane, modelPluginID: "codex")
        #expect(presentation.panel == .models(captured))
        for (context, identity, plugin) in [
            (phrase(host: "other"), Optional(pane), Optional("codex")),
            (phrase(pane: "%2"), pane, "codex"),
            (phrase(revision: 1), pane, "codex"),
            (phrase(), .init(serverID: "replacement", sessionID: pane.sessionID, windowID: pane.windowID, paneID: pane.paneID), "codex"),
            (phrase(), .init(serverID: pane.serverID, sessionID: pane.sessionID, windowID: pane.windowID, paneID: .init()), "codex"),
            (phrase(), pane, "claude-code"),
            (phrase(), nil, "codex"),
            (phrase(), pane, nil),
        ] {
            presentation.show(.models(captured))
            presentation.validate(phraseContext: context, commandContext: nil, modelPane: identity, modelPluginID: plugin)
            #expect(!presentation.isPresented)
        }
    }

    @Test("Reopening model controls creates a new owner for asynchronous completions")
    func modelPanelOwnership() {
        let pane = WorkspacePaneIdentity(serverID: "server", sessionID: .init(), windowID: .init(), paneID: .init())
        let previous = TerminalAgentModelPresentation(context: phrase(), pluginID: "codex", pane: pane)
        let reopened = TerminalAgentModelPresentation(context: phrase(), pluginID: "codex", pane: pane)
        var presentation = TerminalQuickActionPresentation()
        presentation.show(.models(previous))
        presentation.dismiss()
        presentation.show(.models(reopened))
        #expect(previous.id != reopened.id)
        #expect(presentation.panel != .models(previous))
        #expect(presentation.panel == .models(reopened))
    }

    @Test("Commands remain openable without an agent, connection, or selected pane")
    func unknownAgentPanel() {
        for terminal in [phrase(), phrase(connected: false), phrase(pane: nil)] {
            var presentation = TerminalQuickActionPresentation()
            presentation.toggleCommands(context: nil, terminal: terminal)
            #expect(presentation.panel == .commandsUnavailable(terminal))
            #expect(!presentation.suspendsTerminalInput)
            presentation.validate(phraseContext: terminal, commandContext: nil)
            #expect(presentation.isPresented)
            presentation.toggleCommands(context: nil, terminal: terminal)
            #expect(!presentation.isPresented)
        }
    }

    @Test("Agent identity changes do not prevent the command toolbar toggle from closing")
    func toggleCommandsAcrossIdentityChange() throws {
        var presentation = TerminalQuickActionPresentation()
        presentation.toggleCommands(context: nil, terminal: phrase())
        try presentation.toggleCommands(context: command(), terminal: phrase())
        #expect(!presentation.isPresented)
        try presentation.toggleCommands(context: command(), terminal: phrase())
        presentation.toggleCommands(context: nil, terminal: phrase())
        #expect(!presentation.isPresented)

        presentation.toggle(.phrases(phrase()))
        presentation.isEditingPhrase = true
        presentation.toggleCommands(context: nil, terminal: phrase())
        #expect(presentation.panel == .commandsUnavailable(phrase()))
        #expect(!presentation.isEditingPhrase)
        #expect(!presentation.suspendsTerminalInput)
        presentation.toggle(.phrases(phrase()))
        #expect(presentation.panel == .phrases(phrase()))
    }

    @Test("Host metadata restores the correct catalog without granting send permission", arguments: ["codex", "claude-code"])
    func identityRecovery(plugin: String) throws {
        var presentation = TerminalQuickActionPresentation()
        presentation.toggleCommands(context: nil, terminal: phrase())
        let recovered = try command(plugin: plugin, connected: false)
        presentation.validate(phraseContext: phrase(connected: false), commandContext: recovered)
        #expect(presentation.panel == .commands(recovered))
        #expect(!recovered.canSend)
        #expect(AgentCommandRequest(.model, in: recovered) == nil)
        #expect(!presentation.suspendsTerminalInput)
    }

    @Test("Missing-identity panels never borrow metadata from another terminal or input revision")
    func unrelatedIdentityIsIgnored() throws {
        for unrelated in try [command(host: "other"), command(pane: "%2"), command(revision: 1)] {
            var presentation = TerminalQuickActionPresentation()
            presentation.toggleCommands(context: nil, terminal: phrase())
            presentation.validate(phraseContext: phrase(), commandContext: unrelated)
            #expect(presentation.panel == .commandsUnavailable(phrase()))
        }
    }

    @Test("Missing-identity panels close when host, pane, or local input changes")
    func unknownAgentTargetChanges() {
        for changed in [phrase(host: "other"), phrase(pane: "%2"), phrase(revision: 1)] {
            var presentation = TerminalQuickActionPresentation()
            presentation.toggleCommands(context: nil, terminal: phrase())
            presentation.validate(phraseContext: changed, commandContext: nil)
            #expect(!presentation.isPresented)
        }
    }

    @Test("The same toolbar button opens, closes and reopens either panel")
    func toggleSamePanel() throws {
        for panel in try [TerminalQuickActionPresentation.Panel.commands(command()), .commandsUnavailable(phrase()), .phrases(phrase())] {
            var presentation = TerminalQuickActionPresentation()
            for _ in 0..<5 {
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
        let commands = try TerminalQuickActionPresentation.Panel.commands(command())
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
        try presentation.toggle(.commands(command()))
        try presentation.toggle(.commands(command(connected: false)))
        #expect(!presentation.isPresented)
        presentation.toggle(.phrases(phrase()))
        presentation.toggle(.phrases(phrase(connected: false)))
        #expect(!presentation.isPresented)
    }

    @Test("Toolbar toggles can close or switch out of the phrase editor")
    func toggleOutOfEditor() throws {
        for panel in try [TerminalQuickActionPresentation.Panel.phrases(phrase()), .commands(command())] {
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
        let updates = TerminalInputFocusUpdates { applied.append($0)
            return true
        }
        let initial = TerminalInputPresentation.resolve(
            keyboardRequested: keyboardRequested, isActive: true, isCopyPresented: false
        )
        updates.setAttached(true)
        updates.request(initial)
        await updates.pendingTask?.value

        let models = TerminalQuickActionPresentation.Panel.models(.init(
            context: phrase(), pluginID: "codex",
            pane: .init(serverID: "server", sessionID: .init(), windowID: .init(), paneID: .init())
        ))
        for panel in try [models, .commands(command()), .commandsUnavailable(phrase()), .phrases(phrase())] {
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
        try presentation.show(.commands(command()))
        #expect(!presentation.isEditingPhrase)
        #expect(!presentation.suspendsTerminalInput)
        presentation.show(.phrases(phrase()))
        presentation.isEditingPhrase = true
        presentation.dismiss()
        #expect(!presentation.isEditingPhrase)
        #expect(!presentation.suspendsTerminalInput)
    }

    @Test("Embedded editors borrow the keyboard without invalidating their captured panel", arguments: [false, true], [false, true])
    func embeddedEditorKeepsItsCapture(keyboardRequested: Bool, customButton: Bool) {
        var presentation = TerminalQuickActionPresentation()
        presentation.show(customButton ? .addCustomButton(phrase()) : .phrases(phrase()))
        presentation.isEditingPhrase = !customButton
        let captured = presentation.panel
        let suspension = TerminalInputSuspension(external: false, quickActionEditor: presentation.suspendsTerminalInput)

        let revision: UInt64 = suspension.invalidatesQuickActions ? 1 : 0
        presentation.validate(phraseContext: phrase(revision: revision), commandContext: nil)

        #expect(presentation.panel == captured)
        #expect(suspension.suspendsInput)
        #expect(TerminalInputPresentation.resolve(
            keyboardRequested: keyboardRequested, isActive: true, isCopyPresented: false,
            isInputSuspended: suspension.suspendsInput
        ) == .init(inputEnabled: false, keyboardRequested: false))

        presentation.dismiss()
        let restored = TerminalInputSuspension(external: false, quickActionEditor: presentation.suspendsTerminalInput)
        #expect(TerminalInputPresentation.resolve(
            keyboardRequested: keyboardRequested, isActive: true, isCopyPresented: false,
            isInputSuspended: restored.suspendsInput
        ) == .init(inputEnabled: true, keyboardRequested: keyboardRequested))
    }

    @Test("External suspension still invalidates an editor that has already borrowed focus")
    func externalSuspensionInvalidatesEditingCapture() {
        var presentation = TerminalQuickActionPresentation()
        presentation.show(.phrases(phrase()))
        presentation.isEditingPhrase = true
        let editing = TerminalInputSuspension(external: false, quickActionEditor: true)
        let external = TerminalInputSuspension(external: true, quickActionEditor: true)

        #expect(editing.suspendsInput == external.suspendsInput)
        #expect(editing.invalidatesQuickActions != external.invalidatesQuickActions)
        let revision: UInt64 = external.invalidatesQuickActions ? 1 : 0
        presentation.validate(phraseContext: phrase(revision: revision), commandContext: nil)
        #expect(!presentation.isPresented && !presentation.isEditingPhrase)
    }

    @Test("Availability changes keep panels open, preserving their captured targets")
    func availability() throws {
        for panel in try [TerminalQuickActionPresentation.Panel.commands(command()), .phrases(phrase())] {
            var presentation = TerminalQuickActionPresentation()
            presentation.show(panel)
            for connected in [false, true] {
                try presentation.validate(phraseContext: phrase(connected: connected), commandContext: command(connected: connected))
                #expect(presentation.panel == panel)
                #expect(!presentation.suspendsTerminalInput)
            }
        }
    }

    @Test("Changing pane or local input closes either panel and clears editor state")
    func staleInput() throws {
        for panel in try [TerminalQuickActionPresentation.Panel.commands(command()), .phrases(phrase())] {
            for (pane, revision) in [("%2", UInt64(0)), ("%1", UInt64(1))] {
                var presentation = TerminalQuickActionPresentation()
                presentation.show(panel)
                presentation.isEditingPhrase = true
                try presentation.validate(
                    phraseContext: phrase(pane: pane, revision: revision),
                    commandContext: command(pane: pane, revision: revision)
                )
                #expect(!presentation.isPresented)
                #expect(!presentation.isEditingPhrase)
            }
        }
    }

    @Test("Agent loss or replacement closes commands but does not prevent shell phrases")
    func agentChange() throws {
        for changed in try [nil, command(plugin: "claude-code")] {
            var presentation = TerminalQuickActionPresentation()
            try presentation.show(.commands(command()))
            presentation.validate(phraseContext: phrase(), commandContext: changed)
            #expect(!presentation.isPresented)
            presentation.show(.phrases(phrase()))
            presentation.validate(phraseContext: phrase(), commandContext: changed)
            #expect(presentation.isPresented)
        }
    }

    @Test("Browsing cannot override an inactive pane or a copy sheet")
    func preservesOtherInputGuards() throws {
        for panel in try [TerminalQuickActionPresentation.Panel.commands(command()), .phrases(phrase())] {
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

    @Test("Custom button editor suspends input and restores existing keyboard intent", arguments: [false, true])
    func customButtonEditorFocus(keyboardRequested: Bool) {
        var presentation = TerminalQuickActionPresentation()
        presentation.toggle(.addCustomButton(phrase()))
        #expect(presentation.isPresented)
        #expect(presentation.suspendsTerminalInput)
        #expect(TerminalInputPresentation.resolve(
            keyboardRequested: keyboardRequested, isActive: true, isCopyPresented: false,
            isInputSuspended: presentation.suspendsTerminalInput
        ) == .init(inputEnabled: false, keyboardRequested: false))
        presentation.toggle(.addCustomButton(phrase()))
        #expect(!presentation.isPresented)
        #expect(!presentation.suspendsTerminalInput)
        #expect(TerminalInputPresentation.resolve(
            keyboardRequested: keyboardRequested, isActive: true, isCopyPresented: false,
            isInputSuspended: presentation.suspendsTerminalInput
        ) == .init(inputEnabled: true, keyboardRequested: keyboardRequested))
    }

    @Test("Custom editor permits offline management but closes on a changed target or draft")
    func customButtonEditorContext() {
        var presentation = TerminalQuickActionPresentation()
        presentation.show(.addCustomButton(phrase()))
        presentation.validate(phraseContext: phrase(connected: false), commandContext: nil)
        #expect(presentation.isPresented)
        #expect(presentation.suspendsTerminalInput)
        presentation.toggleCommands(context: nil, terminal: phrase())
        #expect(!presentation.suspendsTerminalInput)
        for changed in [phrase(host: "other"), phrase(pane: "%2"), phrase(revision: 1)] {
            presentation.show(.addCustomButton(phrase()))
            presentation.validate(phraseContext: changed, commandContext: nil)
            #expect(!presentation.isPresented)
            #expect(!presentation.suspendsTerminalInput)
        }
    }
}
