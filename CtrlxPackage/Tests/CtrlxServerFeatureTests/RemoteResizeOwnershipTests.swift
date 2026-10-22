#if os(macOS)
    import ConcurrencyExtras
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    @Suite("Remote resize ownership")
    struct RemoteResizeOwnershipTests {
        @Test("Host rejects a resize without an explicit user action")
        func hostRejectsAutomaticViewerResize() async {
            let commandID = UUID()
            let executor = TmuxCommandExecutor(
                tmuxService: TmuxService(
                    tmuxPath: "/nonexistent/tmux",
                    socketPath: "/tmp/ctrlx-unused.sock"
                )
            )
            let command = CommandMessage(
                id: commandID,
                paneId: "%1",
                command: ResizeTmuxPane(width: 80, height: 59).commandType
            )

            let response = await executor.execute(command)

            #expect(response.commandId == commandID)
            #expect(!response.success)
            #expect(response.error == "Terminal resize requires explicit user action")
        }

        @Test("Host executes an explicitly user-initiated resize")
        func hostExecutesManualViewerResize() async {
            let resizeArguments = LockIsolated<[String]?>(nil)

            await withDependencies {
                $0[ProcessRunner.self].run = { @Sendable _, arguments, _, _ in
                    if arguments.contains("display-message") {
                        return ProcessResult(exitCode: 0, stdout: Data("@1\t160x60,0,0,5\n".utf8), stderr: Data())
                    }
                    if arguments.contains("resize-window") {
                        resizeArguments.withValue { $0 = arguments }
                        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                    }
                    if arguments.contains("list-clients") {
                        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                    }
                    if arguments.contains("list-panes") {
                        let separator = String(PaneInfo.fieldSeparator)
                        let paneLine = [
                            "%5", "work", "0", "0", "zsh", "/tmp",
                            "132", "48", "1", "zsh", "layout", "terminal 1",
                            "1", "", "", "", "@1",
                        ].joined(separator: separator)
                        return ProcessResult(
                            exitCode: 0,
                            stdout: Data("\(paneLine)\n".utf8),
                            stderr: Data()
                        )
                    }
                    return ProcessResult(
                        exitCode: 1,
                        stdout: Data(),
                        stderr: Data("unexpected command".utf8)
                    )
                }
            } operation: {
                let executor = TmuxCommandExecutor(
                    tmuxService: TmuxService(tmuxPath: "/usr/bin/tmux")
                )
                let commandID = UUID()
                let response = await executor.execute(CommandMessage(
                    id: commandID,
                    paneId: "@1",
                    command: ResizeTmuxPane(
                        width: 132,
                        height: 48,
                        userInitiated: true
                    ).commandType
                ))

                #expect(response.commandId == commandID)
                #expect(response.success)
                #expect(response.error == nil)
                let arguments = resizeArguments.value
                #expect(arguments != nil)
                #expect(arguments?.contains("@1") == true)
                #expect(arguments?.contains("132") == true)
                #expect(arguments?.contains("48") == true)
                #expect(arguments?.contains("select-layout") == true)
            }
        }

        @Test("Foreground Fit checks live Host dimensions even when the cached grid matches", arguments: [80, 160], [false, true])
        func foregroundFitUsesHostDimensions(hostWidth: Int, local: Bool) async throws {
            let commands = LockIsolated<[[String]]>([])
            try await withDependencies {
                $0[ProcessRunner.self].run = { @Sendable _, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    let output = arguments.contains("display-message")
                        ? "@1\t\(hostWidth)x\(hostWidth == 80 ? 24 : 60),0,0,5\n" : ""
                    return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
                }
            } operation: {
                let target = TerminalTabFit.Target(hostID: local ? nil : "host", sessionName: "dev", windowID: "@1")
                let viewport = ResizeTmuxPane(width: 80, height: 24, userInitiated: true)
                var fit = TerminalTabFit()
                fit.request(target)
                // The last Viewer snapshot matched this viewport, but another
                // client may have resized tmux before the Viewer resumes.
                let pendingRequest = fit.takeRequest(
                    for: target, isAvailable: true, isPresentationReady: true,
                    measuredRequest: viewport
                )
                let request = try #require(pendingRequest)
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                if local {
                    try await tmux.fitWindow("@1", width: request.width, height: request.height)
                } else {
                    let response = await TmuxCommandExecutor(tmuxService: tmux).execute(CommandMessage(
                        paneId: "@1", command: request.commandType
                    ))
                    #expect(response.success)
                }
                #expect(commands.value.first?.contains("display-message") == true)
                if hostWidth == 80 {
                    #expect(commands.value.count == 1)
                } else {
                    let resize = try #require(commands.value.first { $0.contains("resize-window") })
                    #expect(resize.contains("80"))
                    #expect(resize.contains("24"))
                    #expect(resize.contains("select-layout"))
                }
                #expect(fit.takeRequest(
                    for: target, isAvailable: true, isPresentationReady: true,
                    measuredRequest: viewport
                ) == nil)
            }
        }

        @Test(
            "Local and Viewer tmux Fit retain unequal splits, pane IDs, and repeatability",
            arguments: ["horizontal", "vertical", "nested", "reordered"],
            [false, true]
        )
        func realTmuxFit(kind: String, local: Bool) async throws {
            let tmuxPath = try #require(TmuxBinaryLocator.liveValue.find())
            let socket = "/tmp/ctrlx-fit-\(UUID().uuidString.prefix(8)).sock"
            let runner = ProcessRunner.liveValue
            try await withDependencies {
                $0[ProcessRunner.self] = runner
                $0.continuousClock = ContinuousClock()
            } operation: {
                do {
                    let tmux = TmuxService(tmuxPath: tmuxPath, socketPath: socket)
                    let created = try await runner.run(tmuxPath, [
                        "-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", "fit",
                        "-x", "160", "-y", "60", "/bin/cat",
                    ], nil, 5)
                    try #require(created.isSuccess)
                    let vertical = kind == "vertical"
                    let split = try await tmux.runTmuxCommand([
                        "split-window", vertical ? "-v" : "-h", "-t", "fit:0",
                        "-l", vertical ? "15" : "40", "/bin/cat",
                    ])
                    try #require(split.isSuccess)
                    if kind == "nested" {
                        let nested = try await tmux.runTmuxCommand(["split-window", "-v", "-t", "%0", "-l", "15", "/bin/cat"])
                        try #require(nested.isSuccess)
                    } else if kind == "reordered" {
                        let swap = try await tmux.runTmuxCommand(["swap-pane", "-s", "%0", "-t", "%1"])
                        try #require(swap.isSuccess)
                    }
                    let height = vertical ? 16 : 44
                    for (width, rows) in [(80, 40), (64, height), (100, 60), (64, height), (60, height), (64, height), (64, height)] {
                        let before = try await tmux.runTmuxCommand(["display-message", "-p", "-t", "fit:0", "#{window_layout}"])
                        let original = try #require(TmuxLayoutParser.parse(before.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)))
                        if kind == "horizontal", width == 80, case let .horizontal(children, _, _) = original {
                            #expect(original.width == 160)
                            #expect(children.map(\.width) == [119, 40])
                        }
                        let expectedString = try #require(TmuxWindowFitLayout.layoutString(original, width: width, height: rows))
                        let expected = try #require(TmuxLayoutParser.parse(expectedString))
                        if local {
                            try await tmux.fitWindow("fit:0", width: width, height: rows)
                        } else {
                            let response = await TmuxCommandExecutor(tmuxService: tmux).execute(CommandMessage(
                                paneId: "fit:0", command: ResizeTmuxPane(width: width, height: rows, userInitiated: true).commandType
                            ))
                            try #require(response.success, "\(response.error ?? "Fit failed")")
                        }
                        let after = try await tmux.runTmuxCommand(["display-message", "-p", "-t", "fit:0", "#{window_layout}"])
                        let actual = try #require(TmuxLayoutParser.parse(after.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)))
                        #expect(actual == expected)
                        #expect(actual.width == width && actual.height == rows)
                        if kind == "horizontal", width == 80, case let .horizontal(children, _, _) = actual {
                            #expect(children.map(\.width) == [59, 20])
                        }
                        if kind == "horizontal", width == 64, case let .horizontal(children, _, _) = actual {
                            #expect(children.map(\.width) == [47, 16])
                        }
                        if kind == "horizontal", width == 60, case let .horizontal(children, _, _) = actual {
                            #expect(children.map(\.width) == [44, 15])
                        }
                        if vertical, rows == 16, case let .vertical(children, _, _) = actual {
                            #expect(children.map(\.height) == [11, 4])
                        }
                    }
                    let beforeInvalid = try await tmux.runTmuxCommand(["display-message", "-p", "-t", "fit:0", "#{window_layout}"])
                    if local {
                        await #expect(throws: TmuxError.self) {
                            try await tmux.fitWindow("fit:0", width: 3, height: 3)
                        }
                    } else {
                        let failed = await TmuxCommandExecutor(tmuxService: tmux).execute(CommandMessage(
                            paneId: "fit:0", command: ResizeTmuxPane(width: 3, height: 3, userInitiated: true).commandType
                        ))
                        #expect(!failed.success)
                    }
                    let afterInvalid = try await tmux.runTmuxCommand(["display-message", "-p", "-t", "fit:0", "#{window_layout}"])
                    #expect(afterInvalid.stdout == beforeInvalid.stdout)
                } catch {
                    _ = try? await runner.run(tmuxPath, ["-S", socket, "kill-server"], nil, 5)
                    throw error
                }
                let cleanup = try await runner.run(tmuxPath, ["-S", socket, "kill-server"], nil, 5)
                #expect(cleanup.isSuccess)
            }
        }
    }
#endif
