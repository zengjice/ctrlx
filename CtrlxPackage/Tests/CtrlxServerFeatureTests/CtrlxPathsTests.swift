#if os(macOS)
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("CtrlxPaths")
    struct CtrlxPathsTests {
        @Test("default layout derives from ~/.ctrlx")
        func defaultLayout() {
            let paths = CtrlxPaths()
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

            // Compare `.path` so a directory URL's trailing-slash representation
            // doesn't matter — only the layout does.
            #expect(paths.ctrlxRoot.path == "\(home)/.ctrlx")
            #expect(paths.stateRoot.path == "\(home)/.ctrlx/state")
            #expect(paths.registryPath.path == "\(home)/.ctrlx/registry.json")
            #expect(paths.ingressSocketPath.path == "\(home)/.ctrlx/state/ingress.sock")
            #expect(paths.pluginStateDir("claude-code").path == "\(home)/.ctrlx/state/plugins/claude-code")
            #expect(
                paths.pluginSettingsPath("claude-code").path
                    == "\(home)/.ctrlx/state/plugins/claude-code/settings.json"
            )
            #expect(
                paths.pluginLogPath("claude-code").path
                    == "\(home)/.ctrlx/state/plugins/claude-code/logs/sidecar.log"
            )
        }

        @Test("override root redirects the whole tree and keeps registry adjacent")
        func overrideLayout() {
            let override = URL(fileURLWithPath: "/tmp/ctrlx-test-xyz/state")
            let paths = CtrlxPaths(stateRootOverride: override)

            #expect(paths.stateRoot.path == "/tmp/ctrlx-test-xyz/state")
            // registry.json stays adjacent to the redirected state/ directory.
            #expect(paths.ctrlxRoot.path == "/tmp/ctrlx-test-xyz")
            #expect(paths.registryPath.path == "/tmp/ctrlx-test-xyz/registry.json")
            #expect(paths.ingressSocketPath.path == "/tmp/ctrlx-test-xyz/state/ingress.sock")
            #expect(paths.pluginLogPath("codex").path == "/tmp/ctrlx-test-xyz/state/plugins/codex/logs/sidecar.log")
        }

        @Test("ensurePluginStateDir materializes the directory tree")
        func ensurePluginStateDirCreatesDirs() {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ctrlx-paths-\(UUID().uuidString)/state")
            defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

            let paths = CtrlxPaths(stateRootOverride: tmp)
            let dir = paths.ensurePluginStateDir("echo")

            #expect(FileManager.default.fileExists(atPath: dir.path))
            #expect(FileManager.default.fileExists(atPath: paths.pluginLogDir("echo").path))
        }
    }
#endif
