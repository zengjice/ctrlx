#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import Foundation
    import CtrlxPluginProtocol
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite("Live plugin process snapshots")
    struct LivePluginHostTests {
        @Test("Live host preserves unavailable, confirmed empty, and live snapshots",
              arguments: ["tmux-failure", "ps-failure", "cancelled", "empty", "live"])
        func snapshotAvailability(scenario: String) async {
            await withDependencies {
                $0[ProcessRunner.self].run = { @Sendable executable, arguments, _, _ in
                    if scenario == "cancelled" { throw CancellationError() }
                    if arguments.contains("list-panes") {
                        let separator = String(PaneInfo.fieldSeparator)
                        return ProcessResult(
                            exitCode: scenario == "tmux-failure" ? 1 : 0,
                            stdout: Data("%1\(separator)100\(separator)/tmp/project\n".utf8),
                            stderr: Data()
                        )
                    }
                    if executable == "/bin/ps" {
                        let rows = scenario == "live" ? "100 1 zsh\n101 100 codex\n" : "100 1 zsh\n"
                        return ProcessResult(exitCode: scenario == "ps-failure" ? 1 : 0,
                                             stdout: Data(rows.utf8), stderr: Data())
                    }
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                let host: any PluginHost = LivePluginHost(
                    pluginID: "codex",
                    dispatcher: PluginEventDispatcher(),
                    logSink: PluginLogSink(logFileURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("ctrlx-host-test-\(UUID().uuidString).log")),
                    onAgentPanes: { pluginID in
                        #expect(pluginID == "codex")
                        let detected = await tmux.detectAgentPanesIfAvailable(
                            processNamesByPlugin: [pluginID: ["codex"]]
                        )
                        return detected.map { Array($0.keys) }
                    }
                )
                let snapshot = await host.agentPanesIfAvailable()
                switch scenario {
                case "live": #expect(snapshot == ["%1"])
                case "empty": #expect(snapshot == [])
                default: #expect(snapshot == nil)
                }
                // Existing sidecar listing keeps its array-shaped contract.
                #expect(await host.agentPanes() == (snapshot ?? []))
            }
        }

        @Test("An unwired live host cannot provide lifecycle evidence")
        func unwiredHost() async {
            let host: any PluginHost = LivePluginHost(
                pluginID: "codex", dispatcher: PluginEventDispatcher(),
                logSink: PluginLogSink(logFileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ctrlx-host-test-\(UUID().uuidString).log"))
            )
            #expect(await host.agentPanesIfAvailable() == nil)
            #expect(await host.agentPanes() == [])
        }
    }
#endif
