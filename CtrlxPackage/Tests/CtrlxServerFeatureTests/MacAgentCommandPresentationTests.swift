#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite("Mac command-panel identity refresh")
    struct MacAgentCommandPresentationTests {
        private func terminal(host: String = "local", pane: String = "%5", revision: UInt64 = 0) -> TerminalPhraseContext {
            TerminalPhraseContext(hostID: host, paneID: pane, inputRevision: revision,
                                  isConnected: true, isInputAvailable: true)
        }

        private func command(host: String = "local", pane: String = "%5", revision: UInt64 = 0,
                             plugin: String = "codex", ready: Bool = true) -> AgentCommandContext? {
            var session = AgentSession(paneId: pane)
            session.pluginID = plugin
            return AgentCommandContext(hostID: host, paneID: pane, session: session,
                                       isConnected: true, isInputAvailable: ready,
                                       hasExternalEditor: false, inputRevision: revision)
        }

        @Test("Late identity restores the catalog without replacing the captured panel")
        func lateIdentity() throws {
            let terminal = terminal()
            var captured = TerminalQuickActionButtons.Presentation(token: nil, command: nil,
                                                                   phrase: terminal, label: "This Mac")
            let id = captured.id
            let remainsOpen = captured.updateCommand(nil, terminal: terminal)
            #expect(remainsOpen)
            #expect(captured.command == nil)
            let restored = captured.updateCommand(command(), terminal: terminal)
            #expect(restored)
            #expect(captured.id == id)
            #expect(captured.command?.target.pluginID == "codex")
            let request = try #require(AgentCommandRequest(.model, in: captured.command))
            #expect(request.isValid(in: command()))
        }

        @Test("Refresh never promotes metadata for a different host, pane, or input revision",
              arguments: ["host", "pane", "input"])
        func staleIdentity(change: String) {
            var captured = TerminalQuickActionButtons.Presentation(token: nil, command: nil,
                                                                   phrase: terminal(), label: "This Mac")
            let current = command(host: change == "host" ? "remote" : "local",
                                  pane: change == "pane" ? "%6" : "%5",
                                  revision: change == "input" ? 1 : 0)
            let accepted = captured.updateCommand(current, terminal: terminal())
            #expect(!accepted)
            #expect(captured.command == nil)
        }

        @Test("A known agent change invalidates the panel instead of swapping catalogs")
        func changedAgent() {
            var captured = TerminalQuickActionButtons.Presentation(token: nil, command: command(),
                                                                   phrase: terminal(), label: "This Mac")
            let changed = captured.updateCommand(command(plugin: "claude-code"), terminal: terminal())
            let removed = captured.updateCommand(nil, terminal: terminal())
            #expect(!changed)
            #expect(!removed)
        }

        @Test("Opening or identifying an unavailable terminal grants no send permission")
        func unavailableTerminal() {
            var captured = TerminalQuickActionButtons.Presentation(token: nil, command: nil,
                                                                   phrase: terminal(), label: "This Mac")
            let identified = captured.updateCommand(command(ready: false), terminal: terminal())
            #expect(identified)
            #expect(captured.command?.canSend == false)
            #expect(AgentCommandRequest(.model, in: captured.command) == nil)
        }
    }
#endif
