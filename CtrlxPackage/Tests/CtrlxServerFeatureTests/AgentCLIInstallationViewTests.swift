#if os(macOS)
    import AppKit
    import CtrlxCommon
    import Dependencies
    import SwiftUI
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Agent setup offscreen UI") @MainActor
    struct AgentCLIInstallationViewTests {
        final private class Measurement {
            var size: CGSize?
        }

        @Test("Setup fits its window with missing agents, managed installs, errors and active logs", arguments: [0, 1, 2, 3], [540, 620])
        func layout(scenario: Int, width: Int) async throws {
            let state = withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[AgentCLIClient.self] = .init(inspect: { agent, _ in
                    if scenario != 0 {
                        return agent == .codex ? .available(path: "/test/codex", version: "codex-cli 0.999.0") : .unavailable("Configured command is missing or not executable: /a/custom/location/with/a/long/path/claude. Check its path in Agents settings.")
                    }
                    return .missing
                }, install: { _, _ in Issue.record("Layout must never install") }, managedInstallation: { agent, _ in
                    guard scenario >= 2 else { return nil }
                    return .init(agent: agent, launcherPath: "/test/\(agent.command)", binaryPath: "/test/version/\(agent.command)", source: .homebrew(prefix: "/test", cask: agent == .codex ? "codex" : "claude-code@latest"))
                }, maintain: { _, _, event in
                    guard scenario == 3 else { Issue.record("Idle layout must never update or repair")
                        return
                    }
                    await event(.phase("Verifying official signatures"))
                    await event(.output("Checking agent signatures…\n"))
                    try await Task.sleep(for: .seconds(60))
                })
            } operation: {
                AgentCLIInstallations(command: { $0.command }, useInstalledCommand: { _, _, _ in Issue.record("Layout must never modify settings") })
            }
            state.start()
            await state.waitForOperation()
            if scenario == 3 {
                state.maintain(.codex, action: .update)
            }
            defer { state.cancel() }
            _ = NSApplication.shared
            let measurement = Measurement()
            let view = NSHostingView(rootView: AgentCLIInstallationContent(installations: state, close: { }, launch: { _ in })
                .background(Color.white)
                .environment(\.colorScheme, .light)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { measurement.size = $0 })
            view.sizingOptions = []
            let height = width == 540 ? 420 : 460
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            view.layoutSubtreeIfNeeded()
            let size = try #require(measurement.size)
            #expect(size.width <= CGFloat(width))
            #expect(size.height <= CGFloat(height))
            if let folder = ProcessInfo.processInfo.environment["CTRLX_CLI_UI_SNAPSHOTS"] {
                let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: image)
                let data = try #require(image.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("cli-setup-\(scenario)-\(width).png"))
            }
            await state.stop()
        }
    }
#endif
