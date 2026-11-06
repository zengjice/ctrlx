#if os(macOS)
    import CtrlxCommon
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    struct CLIInstallationTests {
        private struct Fixture {
            let root: URL
            let home: URL
            let app: URL
            let files = FileManager.default
            var wrapper: URL {
                home.appendingPathComponent(".local/bin/ctrlx")
            }

            init() throws {
                self.root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-cli-test-\(UUID())")
                self.home = root.appendingPathComponent("user's home")
                self.app = root.appendingPathComponent("CtrlX's $(literal).app")
                try files.createDirectory(at: home, withIntermediateDirectories: true)
                let binary = app.appendingPathComponent("Contents/MacOS/CtrlXCLI")
                try files.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("#!/bin/sh\nprintf '<%s>\\n' \"$@\"\n".utf8).write(to: binary)
                try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            }

            func installer(shell: String = "/bin/zsh", app: URL? = nil, runner: ProcessRunner = .init(run: { _, _, _, _ in throw CancellationError() })) -> UserCLIInstallation {
                withDependencies { $0[ProcessRunner.self] = runner } operation: {
                    UserCLIInstallation(home: home, app: app ?? self.app, shell: shell, zshDirectory: home)
                }
            }

            func write(_ name: String, _ text: String) throws {
                let file = home.appendingPathComponent(name)
                try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file)
            }

            func read(_ name: String) throws -> String {
                try String(contentsOf: home.appendingPathComponent(name), encoding: .utf8)
            }

            func run(_ shell: String, _ arguments: [String]) async throws -> ProcessResult {
                try await withDependencies { $0.continuousClock = ContinuousClock() } operation: {
                    try await ProcessRunner.liveValue.runWithExactEnvironment(shell, arguments, [
                        "HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin", "TERM": "dumb", "SHELL": shell,
                    ], 10, 64 * 1_024, nil)
                }
            }

            func remove() {
                try? files.removeItem(at: root)
            }
        }

        @Test("Installation preserves profiles, adds one managed block, and repairs executable permissions")
        func repeatedInstallation() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.write(".zprofile", "export USER_PROFILE=preserved\n")
            try fixture.write(".zshrc", "export USER_RC=preserved\n")
            let installer = fixture.installer()
            _ = try await installer.install(zshCompletion: false)
            let first = try fixture.read(".zshrc")
            try fixture.files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.wrapper.path)
            _ = try await installer.install(zshCompletion: false)
            #expect(try fixture.read(".zshrc") == first)
            #expect(first.hasPrefix("export USER_RC=preserved\n"))
            #expect(first.components(separatedBy: UserCLIInstallation.beginMarker).count == 2)
            #expect(await installer.isInstalled())
            let result = try await fixture.run("/bin/zsh", ["-ilc", "source \"$ZDOTDIR/.zshrc\"; ctrlx 'hello world' '$(literal)' ''; print -r -- \"$PATH\""])
            #expect(result.exitCode == 0, "\(result.stderrString)")
            #expect(result.stdoutString.hasPrefix("<hello world>\n<$(literal)>\n<>\n"))
            let path = try #require(result.stdoutString.split(separator: "\n").last)
            #expect(path.split(separator: ":").filter { $0 == fixture.wrapper.deletingLastPathComponent().path }.count == 1)
        }

        @Test("App relocation repairs the launcher without duplicating PATH configuration")
        func relocatedApp() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            _ = try await fixture.installer().install(zshCompletion: false)
            let profile = try fixture.read(".zshrc")
            let moved = fixture.root.appendingPathComponent("Moved CtrlX.app")
            try fixture.files.moveItem(at: fixture.app, to: moved)
            _ = try await fixture.installer(app: moved).install(zshCompletion: false)
            #expect(try fixture.read(".zshrc") == profile)
            let result = try await fixture.run("/bin/zsh", ["-ilc", "ctrlx relocated"])
            #expect(result.exitCode == 0)
            #expect(result.stdoutString == "<relocated>\n")
        }

        @Test("Bash uses its existing login profile and interactive rc file")
        func bashProfiles() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.write(".profile", "export BASH_PROFILE_PRESERVED=yes\n")
            _ = try await fixture.installer(shell: "/bin/bash").install(zshCompletion: false)
            #expect(!fixture.files.fileExists(atPath: fixture.home.appendingPathComponent(".bash_profile").path))
            let result = try await fixture.run("/bin/bash", ["--noprofile", "--norc", "-c", ". \"$HOME/.profile\"; . \"$HOME/.bashrc\"; ctrlx \"$BASH_PROFILE_PRESERVED\""])
            #expect(result.exitCode == 0)
            #expect(result.stdoutString == "<yes>\n")
        }

        @Test("Symlinked dotfiles and their permissions survive installation and removal")
        func symlinkedProfiles() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let target = fixture.root.appendingPathComponent("dotfiles-zshrc")
            let original = "export MY_SETTING=retained\n"
            try Data(original.utf8).write(to: target)
            try fixture.files.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
            let link = fixture.home.appendingPathComponent(".zshrc")
            try fixture.files.createSymbolicLink(at: link, withDestinationURL: target)
            let installer = fixture.installer()
            _ = try await installer.install(zshCompletion: false)
            try await installer.uninstall()
            #expect(try fixture.files.destinationOfSymbolicLink(atPath: link.path) == target.path)
            #expect(try String(contentsOf: target, encoding: .utf8) == original)
            #expect(try fixture.files.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int == 0o640)
            #expect(!fixture.files.fileExists(atPath: fixture.wrapper.path))
        }

        @Test("An unrelated ctrlx command or symlink is never replaced", arguments: [false, true])
        func conflictingLauncher(symlink: Bool) async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let original = "#!/bin/sh\necho someone-elses-command\n"
            if symlink {
                let target = fixture.root.appendingPathComponent("foreign")
                try Data(original.utf8).write(to: target)
                try fixture.files.createDirectory(at: fixture.wrapper.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fixture.files.createSymbolicLink(at: fixture.wrapper, withDestinationURL: target)
            } else {
                try fixture.write(".local/bin/ctrlx", original)
            }
            await #expect(throws: (any Error).self) { try await fixture.installer().install(zshCompletion: false) }
            #expect(try fixture.read(".local/bin/ctrlx") == original)
            #expect(!fixture.files.fileExists(atPath: fixture.home.appendingPathComponent(".zshrc").path))
        }

        @Test("Incomplete managed blocks fail without overwriting shell configuration")
        func malformedBlock() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let original = "export KEEP_ME=yes\n" + UserCLIInstallation.beginMarker + "\nunfinished\n"
            try fixture.write(".zshrc", original)
            await #expect(throws: (any Error).self) { try await fixture.installer().install(zshCompletion: false) }
            #expect(try fixture.read(".zshrc") == original)
            #expect(!fixture.files.fileExists(atPath: fixture.wrapper.path))
        }

        @Test("Custom ZDOTDIR is discovered from zsh rather than guessed from the App environment")
        func customZdotdir() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let directory = fixture.root.appendingPathComponent("custom-zsh")
            let runner = ProcessRunner(run: { _, _, _, _ in throw CancellationError() }, runBoundedCancellable: { executable, arguments, _, _, _ in
                #expect(executable == "/bin/zsh")
                #expect(arguments.first == "-c")
                return .init(exitCode: 0, stdout: Data("startup noise\n__CTRLX_ZDOTDIR__\(directory.path)".utf8), stderr: Data())
            })
            let installer = withDependencies { $0[ProcessRunner.self] = runner } operation: {
                UserCLIInstallation(home: fixture.home, app: fixture.app, shell: "/bin/zsh")
            }
            _ = try await installer.install(zshCompletion: false)
            #expect(fixture.files.fileExists(atPath: directory.appendingPathComponent(".zshrc").path))
            #expect(!fixture.files.fileExists(atPath: fixture.home.appendingPathComponent(".zshrc").path))
        }

        @Test("Completion failure leaves a working CLI and reports the partial result")
        func completionFailure() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let installer = fixture.installer(runner: ProcessRunner(run: { _, _, _, _ in throw CancellationError() }, runBoundedCancellable: { _, _, _, _, _ in
                .init(exitCode: 1, stdout: Data(), stderr: Data("failure".utf8))
            }))
            let result = try await installer.install(zshCompletion: true)
            #expect(await installer.isInstalled())
            #expect(result.completionRequested && !result.completionInstalled)
            #expect(result.completionFailureReason != nil)
            #expect(try !(fixture.read(".zshrc")).contains("compinit"))
        }

        @Test("Shell edits saved while completion generation is suspended are retained")
        func profilesSavedDuringCompletion() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.write(".zprofile", "export PROFILE_ORIGINAL=yes\n")
            try fixture.write(".zshrc", "export RC_ORIGINAL=yes\n")
            let started = AsyncStream<Void>.makeStream()
            let completion = AsyncStream<ProcessResult>.makeStream()
            let runner = ProcessRunner(run: { _, _, _, _ in throw CancellationError() }, runBoundedCancellable: { _, _, _, _, _ in
                started.continuation.yield(())
                var iterator = completion.stream.makeAsyncIterator()
                guard let result = await iterator.next() else { throw CancellationError() }
                return result
            })
            let installer = fixture.installer(runner: runner)
            let installation = Task {
                defer { started.continuation.finish() }
                return try await installer.install(zshCompletion: true)
            }
            defer {
                installation.cancel()
                completion.continuation.finish()
            }
            var iterator = started.stream.makeAsyncIterator()
            _ = try #require(await iterator.next())
            let savedProfile = "export PROFILE_ORIGINAL=yes\nexport PROFILE_JUST_SAVED=keep\n"
            let savedRC = "export RC_ORIGINAL=yes\nexport RC_JUST_SAVED=keep\n"
            try fixture.write(".zprofile", savedProfile)
            try fixture.write(".zshrc", savedRC)
            completion.continuation.yield(.init(exitCode: 0, stdout: Data("#compdef ctrlx\n_ctrlx() { :; }\n".utf8), stderr: Data()))
            _ = try await installation.value
            #expect(try fixture.read(".zprofile").hasPrefix(savedProfile))
            #expect(try fixture.read(".zshrc").hasPrefix(savedRC))
        }

        @Test("Files created by another installer during completion generation are preserved", arguments: [false, true])
        func filesCreatedDuringCompletion(launcher: Bool) async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let path = launcher ? ".local/bin/ctrlx" : ".local/share/zsh/site-functions/_ctrlx"
            let destination = fixture.home.appendingPathComponent(path)
            let saved = "# User-owned file created during installation\n"
            let installer = fixture.installer(runner: ProcessRunner(run: { _, _, _, _ in throw CancellationError() }, runBoundedCancellable: { _, _, _, _, _ in
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(saved.utf8).write(to: destination)
                return .init(exitCode: 0, stdout: Data("#compdef ctrlx\n_ctrlx() { :; }\n".utf8), stderr: Data())
            }))
            if launcher {
                await #expect(throws: (any Error).self) { try await installer.install(zshCompletion: true) }
            } else {
                let result = try await installer.install(zshCompletion: true)
                #expect(!result.completionInstalled)
                #expect(result.completionFailureReason != nil)
            }
            #expect(try fixture.read(path) == saved)
        }

        @Test("Completion is loaded only from interactive zsh configuration")
        func completionSuccess() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let installer = fixture.installer(runner: ProcessRunner(run: { _, _, _, _ in throw CancellationError() }, runBoundedCancellable: { _, _, _, _, _ in
                .init(exitCode: 0, stdout: Data("#compdef ctrlx\n_ctrlx() { _message 'test'; }\n".utf8), stderr: Data())
            }))
            let result = try await installer.install(zshCompletion: true)
            #expect(result.completionInstalled)
            #expect(try !(fixture.read(".zprofile")).contains("compinit"))
            #expect(try fixture.read(".zshrc").contains("compdef _ctrlx ctrlx"))
            let process = try await fixture.run("/bin/zsh", ["-ilc", "source \"$ZDOTDIR/.zshrc\"; (( ${+functions[compdef]} )) && [[ ${_comps[ctrlx]} == _ctrlx ]] && ctrlx completion"])
            #expect(process.exitCode == 0, "\(process.stderrString)")
            #expect(process.stdoutString == "<completion>\n")
        }

        @Test("Automatic setup excludes development builds, E2E and uninstalled Apps")
        func automaticScope() {
            let home = URL(fileURLWithPath: "/Users/test")
            for path in ["/Applications/CtrlX.app", "/Users/test/Applications/CtrlX.app"] {
                #expect(CLIInstallationClient.automaticInstallationAllowed(app: URL(fileURLWithPath: path), home: home, bundleID: "com.gravtice.ctrlx.macos", arguments: []))
            }
            for (path, bundle, arguments) in [
                ("/Applications/CtrlX.app", "com.gravtice.ctrlx.macos", ["--e2e-test"]),
                ("/Applications/CtrlX.app", "com.gravtice.ctrlx.fixture", []),
                ("/Volumes/CtrlX/CtrlX.app", "com.gravtice.ctrlx.macos", []),
                ("/tmp/DerivedData/CtrlX.app", "com.gravtice.ctrlx.macos", []),
            ] {
                #expect(!CLIInstallationClient.automaticInstallationAllowed(app: URL(fileURLWithPath: path), home: home, bundleID: bundle, arguments: arguments))
            }
        }

        private actor InstallationState {
            var installed = false
            var installations = 0
            var completionRequests: [Bool] = []
            func install(zshCompletion: Bool = false) -> CLIInstallResult {
                installed = true
                installations += 1
                completionRequests.append(zshCompletion)
                return .init(completionRequested: zshCompletion, completionInstalled: zshCompletion, completionFailureReason: nil)
            }

            func uninstall() {
                installed = false
            }
        }

        @Test("Explicit uninstall persists across launches until the user reinstalls") @MainActor
        func explicitUninstall() async {
            let state = InstallationState()
            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[CLIInstallationClient.self] = .init(
                    canInstallAutomatically: { true }, userShellIsZsh: { false }, isInstalled: { await state.installed },
                    install: { _ in await state.install() }, uninstall: { await state.uninstall() }
                )
            } operation: {
                let first = CLIInstaller()
                await first.setupAutomatically()
                await first.setupAutomatically()
                #expect(await state.installations == 1)
                #expect(await first.uninstall())
                let relaunched = CLIInstaller()
                await relaunched.setupAutomatically()
                #expect(!relaunched.isInstalled)
                #expect(await state.installations == 1)
                #expect(await relaunched.install() != nil)
                #expect(await state.installations == 2)
            }
        }

        @Test("Startup reads existing installation status even when automatic writes are disabled") @MainActor
        func existingInstallationOutsideAutomaticScope() async {
            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[CLIInstallationClient.self] = .init(
                    canInstallAutomatically: { false }, userShellIsZsh: { false }, isInstalled: { true },
                    install: { _ in
                        Issue.record("A custom App location must not trigger automatic installation")
                        throw CancellationError()
                    }, uninstall: { }
                )
            } operation: {
                let installer = CLIInstaller()
                await installer.setupAutomatically()
                #expect(installer.isInstalled)
            }
        }

        @Test("A manually requested reinstall can add completion after automatic installation") @MainActor
        func reinstallAfterAutomaticInstallation() async {
            let state = InstallationState()
            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[CLIInstallationClient.self] = .init(
                    canInstallAutomatically: { true }, userShellIsZsh: { true }, isInstalled: { await state.installed },
                    install: { await state.install(zshCompletion: $0) },
                    uninstall: { Issue.record("Adding completion must not require an uninstall") }
                )
            } operation: {
                let installer = CLIInstaller()
                await installer.setupAutomatically()
                #expect(installer.isInstalled)
                let result = await installer.install(installZshCompletion: true)
                #expect(result?.completionInstalled == true)
                #expect(installer.isInstalled)
                #expect(await state.completionRequests == [false, true])
            }
        }
    }
#endif
