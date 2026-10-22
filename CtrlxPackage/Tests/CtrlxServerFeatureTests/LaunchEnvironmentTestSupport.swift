#if os(macOS)
    import CtrlxCommon
    import Foundation
    @testable import CtrlxServerFeature

    /// Minimal tmux pane-option transport for shell tests that do not need a
    /// real server. Payloads live in files; the tmux process receives only the
    /// base64 payload through stdin, matching production's argv behavior.
    struct FakeTmuxLaunchEnvironment {
        static let pane = "fixture-pane"

        let root: URL
        let executable: URL
        private let values: URL

        init() throws {
            let files = FileManager.default
            self.root = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("cx-fake-tmux-\(UUID().uuidString.prefix(8))")
            self.executable = root.appendingPathComponent("tmux")
            self.values = root.appendingPathComponent("values")
            try files.createDirectory(at: values, withIntermediateDirectories: true)
            let script = """
            #!/bin/zsh
            if [[ $1 == -S ]]; then shift 2; fi
            pane=""
            for ((i = 1; i <= $#; i++)); do
              if [[ ${argv[i]} == -t ]]; then
                ((i++))
                pane=${argv[i]}
              fi
            done
            path=\(values.path.posixSingleQuoted)/"$pane"
            case $1 in
              show-options)
                if [[ -f "$path" ]]; then
                  /bin/cat "$path"
                fi
                ;;
              set-option)
                if [[ " $* " == *" -pu "* || " $* " == *" -u "* ]]; then
                  /bin/rm -f "$path"
                elif [[ -n "$pane" ]]; then
                  print -rn -- "${@[-1]}" > "$path"
                fi
                ;;
            esac
            """
            try Data(script.utf8).write(to: executable)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        func install(_ launch: SessionLaunchPreparation.AgentLaunch, pane: String = Self.pane) throws {
            guard let payload = launch.payload else { return }
            try Data(payload.utf8).write(to: values.appendingPathComponent(pane))
        }

        func containsPayload(pane: String = Self.pane) -> Bool {
            FileManager.default.fileExists(atPath: values.appendingPathComponent(pane).path)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
#endif
