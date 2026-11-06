#if os(macOS)
    import CtrlxCommon
    import Dependencies
    import DependenciesMacros
    import Foundation

    public struct CLIInstallResult: Sendable {
        public let completionRequested: Bool
        public let completionInstalled: Bool
        public let completionFailureReason: String?
    }

    @DependencyClient
    public struct CLIInstallationClient: Sendable {
        public var canInstallAutomatically: @Sendable () -> Bool = { false }
        public var userShellIsZsh: @Sendable () -> Bool = { false }
        public var isInstalled: @Sendable () async -> Bool = { false }
        public var install: @Sendable (_ zshCompletion: Bool) async throws -> CLIInstallResult
        public var uninstall: @Sendable () async throws -> Void
    }

    extension CLIInstallationClient: DependencyKey {
        public static var liveValue: Self {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let app = Bundle.main.bundleURL
            let shell: String
            if let value = ProcessInfo.processInfo.environment["SHELL"], !value.isEmpty {
                shell = value
            } else if let value = getpwuid(geteuid())?.pointee.pw_shell {
                shell = String(cString: value)
            } else {
                shell = "/bin/sh"
            }
            let files = UserCLIInstallation(home: home, app: app, shell: shell)
            let automatic = automaticInstallationAllowed(
                app: app, home: home, bundleID: Bundle.main.bundleIdentifier, arguments: CommandLine.arguments
            )
            return Self(
                canInstallAutomatically: { automatic },
                userShellIsZsh: { (shell as NSString).lastPathComponent == "zsh" },
                isInstalled: { await files.isInstalled() },
                install: { try await files.install(zshCompletion: $0) },
                uninstall: { try await files.uninstall() }
            )
        }

        public static let testValue = Self()

        static func automaticInstallationAllowed(app: URL, home: URL, bundleID: String?, arguments: [String]) -> Bool {
            guard bundleID == "com.gravtice.ctrlx.macos", !arguments.contains("--e2e-test") else { return false }
            return [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")].contains {
                app.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/")
            }
        }
    }

    /// Serializes wrapper and shell-profile updates without blocking the UI actor.
    actor UserCLIInstallation {
        static let beginMarker = "# >>> CtrlX CLI >>>"
        static let endMarker = "# <<< CtrlX CLI <<<"
        static let wrapperMarker = "# CtrlX CLI — installed by CtrlX.app"
        static let completionMarker = "# CtrlX CLI completion — installed by CtrlX.app"
        let home: URL
        let app: URL
        let shell: String
        let zshDirectory: URL?
        private let files = FileManager.default
        private let runner: ProcessRunner

        init(home: URL, app: URL, shell: String, zshDirectory: URL? = nil) {
            self.home = home
            self.app = app
            self.shell = shell
            self.zshDirectory = zshDirectory
            @Dependency(ProcessRunner.self) var runner
            self.runner = runner
        }

        var bin: URL {
            home.appendingPathComponent(".local/bin")
        }

        var wrapper: URL {
            bin.appendingPathComponent("ctrlx")
        }

        var completion: URL {
            home.appendingPathComponent(".local/share/zsh/site-functions/_ctrlx")
        }

        func isInstalled() -> Bool {
            files.isExecutableFile(atPath: wrapper.path) && owns(wrapper, marker: Self.wrapperMarker)
        }

        func install(zshCompletion: Bool) async throws -> CLIInstallResult {
            let cli = app.appendingPathComponent("Contents/MacOS/CtrlXCLI")
            guard files.isExecutableFile(atPath: cli.path) else {
                throw InstallationError("The bundled CtrlXCLI executable is missing. Reinstall CtrlX and try again.")
            }
            try requireOwnedOrMissing(wrapper, marker: Self.wrapperMarker)
            let profiles = try await profileFiles()
            // Validate all existing profiles before creating the launcher.
            for url in profiles {
                let profile = try readProfile(url)
                _ = try Self.updating(profile.text, block: pathBlock())
            }

            var completionError: String?
            if zshCompletion {
                do {
                    guard (shell as NSString).lastPathComponent == "zsh" else {
                        throw InstallationError("Zsh completion requires a zsh login shell.")
                    }
                    try requireOwnedOrMissing(completion, marker: Self.completionMarker)
                    let result = try await runner.runBoundedCancellable(cli.path, ["--generate-completion-script", "zsh"], nil, 10, 256 * 1_024)
                    guard
                        result.exitCode == 0, !result.outputTruncated, !result.stdout.isEmpty,
                        let script = String(data: result.stdout, encoding: .utf8) else {
                        throw InstallationError("CtrlXCLI could not generate zsh completion.")
                    }
                    try requireOwnedOrMissing(completion, marker: Self.completionMarker)
                    try writeIfChanged(script + "\n" + Self.completionMarker + "\n", to: completion, permissions: 0o644)
                } catch is CancellationError { throw CancellationError() }
                catch { completionError = error.localizedDescription }
            }
            let hasCompletion = owns(completion, marker: Self.completionMarker)
            // Completion generation can outlast an editor save or symlink change.
            let current = try profiles.map { try readProfile($0) }
            let updates = try current.map { profile in
                try (profile, Self.updating(profile.text, block: pathBlock(completionEnabled: hasCompletion && profile.isZshRC)))
            }
            try Task.checkCancellation()
            try requireOwnedOrMissing(wrapper, marker: Self.wrapperMarker)
            try writeIfChanged(Self.wrapperScript(app: app), to: wrapper, permissions: 0o755)
            for (profile, text) in updates where profile.text != text {
                try writeIfChanged(text, to: profile.url, permissions: profile.permissions)
            }
            return .init(completionRequested: zshCompletion, completionInstalled: hasCompletion, completionFailureReason: completionError)
        }

        func uninstall() async throws {
            let profiles = try await profileFiles()
            let current = try profiles.map { try readProfile($0) }
            let updates = try current.map { try ($0, Self.updating($0.text, block: nil)) }
            try Task.checkCancellation()
            for (profile, text) in updates where profile.text != text {
                try writeIfChanged(text, to: profile.url, permissions: profile.permissions)
            }
            for (url, marker) in [(wrapper, Self.wrapperMarker), (completion, Self.completionMarker)] where owns(url, marker: marker) {
                try files.removeItem(at: url)
            }
        }

        private func profileFiles() async throws -> [URL] {
            switch (shell as NSString).lastPathComponent {
            case "zsh":
                let directory: URL
                if let zshDirectory {
                    directory = zshDirectory
                } else {
                    let marker = "__CTRLX_ZDOTDIR__"
                    let result = try await runner.runBoundedCancellable(
                        shell, ["-c", "printf '\(marker)%s' \"${ZDOTDIR:-$HOME}\""], nil, 5, 16 * 1_024
                    )
                    guard
                        result.exitCode == 0, !result.outputTruncated,
                        let output = String(data: result.stdout, encoding: .utf8),
                        let range = output.range(of: marker, options: .backwards) else {
                        throw InstallationError("Could not locate your zsh startup files. Retry Install Command Line Tool from the CtrlX menu.")
                    }
                    let path = String(output[range.upperBound...])
                    guard path.hasPrefix("/") else { throw InstallationError("ZDOTDIR must be an absolute directory for automatic CLI setup.") }
                    directory = URL(fileURLWithPath: path, isDirectory: true)
                }
                return [directory.appendingPathComponent(".zprofile"), directory.appendingPathComponent(".zshrc")]
            case "bash":
                let login = [".bash_profile", ".bash_login", ".profile"].map { home.appendingPathComponent($0) }
                    .first { files.fileExists(atPath: $0.path) } ?? home.appendingPathComponent(".bash_profile")
                return [login, home.appendingPathComponent(".bashrc")]
            case "sh": return [home.appendingPathComponent(".profile")]
            default: throw InstallationError("Automatic CLI PATH setup supports zsh, bash and sh. Use the bundled CtrlXCLI executable with your shell.")
            }
        }

        private struct Profile {
            let url: URL
            let text: String
            let permissions: Int
            let isZshRC: Bool
        }

        private func readProfile(_ url: URL) throws -> Profile {
            let target = url.resolvingSymlinksInPath()
            guard files.fileExists(atPath: target.path) else {
                if (try? files.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                    throw InstallationError("\(url.path) is a broken symbolic link. Repair it before installing the CLI.")
                }
                return .init(url: target, text: "", permissions: 0o600, isZshRC: url.lastPathComponent == ".zshrc")
            }
            let text = try String(contentsOf: target, encoding: .utf8)
            let permissions = try (files.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
            return .init(url: target, text: text, permissions: permissions, isZshRC: url.lastPathComponent == ".zshrc")
        }

        private func pathBlock(completionEnabled: Bool = false) -> String {
            var block = """
            \(Self.beginMarker)
            case ":$PATH:" in
                *:\(bin.path.posixSingleQuoted):*) ;;
                *) export PATH=\(bin.path.posixSingleQuoted):"$PATH" ;;
            esac
            """
            if completionEnabled, (shell as NSString).lastPathComponent == "zsh" {
                let directory = completion.deletingLastPathComponent().path.posixSingleQuoted
                block += """

                if [[ -o interactive ]]; then
                    fpath=(\(directory) "${fpath[@]}")
                    fpath=("${(@u)fpath}")
                    if (( ! ${+functions[compdef]} )); then
                        autoload -Uz compinit
                        compinit
                    fi
                    autoload -Uz _ctrlx
                    compdef _ctrlx ctrlx
                fi
                """
            }
            return block + "\n" + Self.endMarker
        }

        static func updating(_ text: String, block: String?) throws -> String {
            var lines = text.components(separatedBy: "\n")
            if let start = lines.firstIndex(of: beginMarker) {
                guard
                    let end = lines[start...].firstIndex(of: endMarker),
                    !lines[..<start].contains(endMarker),
                    !lines[(start + 1)..<end].contains(beginMarker),
                    !lines[(end + 1)...].contains(beginMarker),
                    !lines[(end + 1)...].contains(endMarker) else {
                    throw InstallationError("The CtrlX CLI block in your shell configuration is incomplete. Repair that block before retrying.")
                }
                lines.replaceSubrange(start...end, with: block?.components(separatedBy: "\n") ?? [])
                return lines.joined(separator: "\n")
            }
            guard !lines.contains(endMarker) else { throw InstallationError("The CtrlX CLI block in your shell configuration is incomplete.") }
            guard let block else { return text }
            return text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + block + "\n"
        }

        static func wrapperScript(app: URL) -> String {
            """
            #!/bin/bash
            \(wrapperMarker)
            CLI=\(app.appendingPathComponent("Contents/MacOS/CtrlXCLI").path.posixSingleQuoted)
            if [ ! -x "$CLI" ]; then
                echo "CtrlXCLI is missing. Open CtrlX to repair the command-line tool." >&2
                exit 1
            fi
            exec "$CLI" "$@"

            """
        }

        private func owns(_ url: URL, marker: String) -> Bool {
            guard
                let attributes = try? files.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeRegular,
                let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.components(separatedBy: "\n").contains(marker)
        }

        private func requireOwnedOrMissing(_ url: URL, marker: String) throws {
            do { _ = try files.attributesOfItem(atPath: url.path) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return }
            if !owns(url, marker: marker) {
                throw InstallationError("\(url.path) already belongs to another installation. CtrlX did not replace it.")
            }
        }

        private func writeIfChanged(_ text: String, to url: URL, permissions: Int) throws {
            if files.fileExists(atPath: url.path), try String(contentsOf: url, encoding: .utf8) == text {
                let current = try (files.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
                if current != permissions {
                    try files.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
                }
                return
            }
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            try files.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }

        private struct InstallationError: LocalizedError {
            let message: String
            init(_ message: String) {
                self.message = message
            }

            var errorDescription: String? {
                message
            }
        }
    }
#endif
