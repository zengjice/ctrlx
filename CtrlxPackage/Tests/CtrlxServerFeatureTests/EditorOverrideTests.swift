import CtrlxCommon
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

struct EditorOverrideProbeParsingTests {
    /// A typical sentinel-survives capture: prompt echo of the command, then the
    /// real output line. The echo starts with the prompt, not the marker.
    @Test("Sentinel intact → .intact")
    func sentinelIntact() {
        let captured = """
        ~ %  printf 'CTRLX_PROBE=%s\\n' "$VISUAL"
        CTRLX_PROBE=__ctrlx_probe__
        ~ %
        """
        #expect(EditorOverride.parseProbeOutput(captured) == .intact)
    }

    @Test("rc override → .conflict with the user's value")
    func overridden() {
        let captured = """
        ➜  ~ printf 'CTRLX_PROBE=%s\\n' "$VISUAL"
        CTRLX_PROBE=vim
        ➜  ~
        """
        #expect(EditorOverride.parseProbeOutput(captured) == .conflict(effectiveValue: "vim"))
    }

    @Test("Value with spaces is preserved")
    func overriddenWithSpaces() {
        let captured = "CTRLX_PROBE=code --wait\n"
        #expect(EditorOverride.parseProbeOutput(captured) == .conflict(effectiveValue: "code --wait"))
    }

    @Test("rc unset → .conflict(nil)")
    func unset() {
        let captured = "$ printf ...\nCTRLX_PROBE=\n$ "
        #expect(EditorOverride.parseProbeOutput(captured) == .conflict(effectiveValue: nil))
    }

    @Test("Marker not present yet → nil (keep polling)")
    func notYetPresent() {
        #expect(EditorOverride.parseProbeOutput("") == nil)
        #expect(EditorOverride.parseProbeOutput("just a prompt\n~ %") == nil)
    }

    /// The typed command echo contains `CTRLX_PROBE=%s`. If a narrow terminal
    /// wrapped it so a continuation row started at column 0 with the marker, the
    /// real output line still comes after it — "last match" wins.
    @Test("Wrapped command echo doesn't mask the real output line")
    func wrappedEchoLastMatchWins() {
        let captured = """
        printf 'CTRLX_PROBE=%s\\n' "$VISUAL"
        CTRLX_PROBE=__ctrlx_probe__
        """
        // The first line begins with `printf` (not the marker) so it's skipped;
        // even constructing the worst case where it begins with the marker, the
        // output line is last.
        #expect(EditorOverride.parseProbeOutput(captured) == .intact)

        let worstCase = """
        CTRLX_PROBE=%s\\n' "$VISUAL"
        CTRLX_PROBE=nvim
        """
        #expect(EditorOverride.parseProbeOutput(worstCase) == .conflict(effectiveValue: "nvim"))
    }

    @Test("Leading whitespace on the output line is tolerated")
    func leadingWhitespace() {
        #expect(EditorOverride.parseProbeOutput("   CTRLX_PROBE=emacs") == .conflict(effectiveValue: "emacs"))
    }
}

struct EditorOverrideInjectionTests {
    @Test("POSIX shells get a leading-space export")
    func posixShells() {
        for shell in ["zsh", "bash", "sh", "dash", "ksh"] {
            let cmd = EditorOverride.injectionCommand(visualValue: "/Apps/G.app/Contents/MacOS/CtrlXCLI edit", shell: shell)
            #expect(cmd == " export VISUAL='/Apps/G.app/Contents/MacOS/CtrlXCLI edit'")
        }
    }

    @Test("fish gets set -gx")
    func fish() {
        let cmd = EditorOverride.injectionCommand(visualValue: "/bin/g edit", shell: "fish")
        #expect(cmd == " set -gx VISUAL '/bin/g edit'")
    }

    @Test("Unknown shells are skipped (nil)")
    func unknownShells() {
        #expect(EditorOverride.injectionCommand(visualValue: "x", shell: "nu") == nil)
        #expect(EditorOverride.injectionCommand(visualValue: "x", shell: "xonsh") == nil)
        #expect(EditorOverride.injectionCommand(visualValue: "x", shell: "elvish") == nil)
    }

    @Test("Leading space keeps the line out of history")
    func leadingSpace() {
        let cmd = EditorOverride.injectionCommand(visualValue: "x", shell: "zsh")
        #expect(cmd?.hasPrefix(" ") == true)
    }

    @Test("Full $SHELL paths and login-shell argv0 resolve to the basename")
    func shellPaths() {
        #expect(EditorOverride.injectionCommand(visualValue: "x", shell: "/opt/homebrew/bin/fish")?.hasPrefix(" set -gx") == true)
        #expect(EditorOverride.injectionCommand(visualValue: "x", shell: "/bin/zsh")?.hasPrefix(" export") == true)
        // Login shells carry a leading '-' in argv[0].
        #expect(EditorOverride.injectionCommand(visualValue: "x", shell: "-zsh")?.hasPrefix(" export") == true)
    }

    @Test("Embedded single quotes in the path are escaped")
    func embeddedQuotes() {
        let cmd = EditorOverride.injectionCommand(visualValue: "/Users/o'brien/g edit", shell: "bash")
        #expect(cmd == " export VISUAL='/Users/o'\\''brien/g edit'")
    }

    @Test("isKnownShell mirrors injectionCommand")
    func knownShell() {
        #expect(EditorOverride.isKnownShell("zsh"))
        #expect(EditorOverride.isKnownShell("fish"))
        #expect(EditorOverride.isKnownShell("/bin/bash"))
        #expect(!EditorOverride.isKnownShell("claude"))
        #expect(!EditorOverride.isKnownShell("nu"))
        #expect(!EditorOverride.isKnownShell("node"))
    }
}

struct EditorOverrideRcLineTests {
    @Test("POSIX shells get the CTRLX_SOCKET-guarded export")
    func posix() {
        let line = EditorOverride.recommendedRcLine(visualValue: "vim", shell: "zsh")
        #expect(line == "[ -n \"$CTRLX_SOCKET\" ] || export VISUAL='vim'")
    }

    @Test("fish gets the set -q guard")
    func fish() {
        let line = EditorOverride.recommendedRcLine(visualValue: "code --wait", shell: "/usr/bin/fish")
        #expect(line == "set -q CTRLX_SOCKET; or set -gx VISUAL 'code --wait'")
    }
}

struct EditorOverrideResultTests {
    @Test("isConflict / conflictingValue")
    func resultAccessors() {
        #expect(VisualProbeResult.intact.isConflict == false)
        #expect(VisualProbeResult.skipped.isConflict == false)
        #expect(VisualProbeResult.conflict(effectiveValue: "vim").isConflict == true)

        #expect(VisualProbeResult.intact.conflictingValue == nil)
        #expect(VisualProbeResult.conflict(effectiveValue: "vim").conflictingValue == "vim")
        #expect(VisualProbeResult.conflict(effectiveValue: nil).conflictingValue == nil)
    }

    @Test("All three override modes are distinct and round-trip through rawValue")
    func modes() {
        #expect(EditorOverrideMode.allCases.count == 3)
        for mode in EditorOverrideMode.allCases {
            #expect(EditorOverrideMode(rawValue: mode.rawValue) == mode)
            #expect(!mode.displayName.isEmpty)
        }
    }
}

@MainActor
struct EditorOverrideSettingsMigrationTests {
    @Test("Legacy editor override is retained and rewritten using the current name")
    func legacyOverride() {
        let preferences = PreferencesService.inMemory()
        preferences.setString("overrideInGallagerSessions", AppSettings.Keys.editorOverrideMode.rawValue)
        withDependencies {
            $0[PreferencesService.self] = preferences
            $0[LoginItemService.self] = .previewValue
        } operation: {
            let settings = AppSettings()
            #expect(settings.editorOverrideMode == .overrideInCtrlxSessions)
            #expect(preferences.string(AppSettings.Keys.editorOverrideMode.rawValue) == "overrideInCtrlxSessions")
            #expect(AppSettings().editorOverrideMode == .overrideInCtrlxSessions)
            settings.editorOverrideMode = .useMyEditor
            #expect(AppSettings().editorOverrideMode == .useMyEditor)
        }
    }

    @Test("Current modes keep their choices through reload", arguments: EditorOverrideMode.allCases)
    func currentMode(_ mode: EditorOverrideMode) {
        let preferences = PreferencesService.inMemory()
        preferences.setString(mode.rawValue, AppSettings.Keys.editorOverrideMode.rawValue)
        withDependencies {
            $0[PreferencesService.self] = preferences
            $0[LoginItemService.self] = .previewValue
        } operation: {
            #expect(AppSettings().editorOverrideMode == mode)
            #expect(preferences.string(AppSettings.Keys.editorOverrideMode.rawValue) == mode.rawValue)
        }
    }

    @Test("Missing and unknown settings retain the Ask default")
    func invalidMode() {
        let preferences = PreferencesService.inMemory()
        withDependencies {
            $0[PreferencesService.self] = preferences
            $0[LoginItemService.self] = .previewValue
        } operation: {
            #expect(AppSettings().editorOverrideMode == .ask)
            #expect(preferences.string(AppSettings.Keys.editorOverrideMode.rawValue) == "ask")
            preferences.setString("unknown", AppSettings.Keys.editorOverrideMode.rawValue)
            #expect(AppSettings().editorOverrideMode == .ask)
            #expect(preferences.string(AppSettings.Keys.editorOverrideMode.rawValue) == "ask")
        }
    }
}

struct EditorOverrideReconcileTests {
    @Test("Override + intact probe → drop the now-redundant override")
    func dropsWhenConflictGone() {
        #expect(EditorOverride.shouldDropRedundantOverride(
            mode: .overrideInCtrlxSessions,
            probe: .intact
        ))
    }

    @Test("Override + still-conflicting probe → keep overriding")
    func keepsWhenStillConflicting() {
        #expect(!EditorOverride.shouldDropRedundantOverride(
            mode: .overrideInCtrlxSessions,
            probe: .conflict(effectiveValue: "vim")
        ))
        #expect(!EditorOverride.shouldDropRedundantOverride(
            mode: .overrideInCtrlxSessions,
            probe: .conflict(effectiveValue: nil)
        ))
    }

    @Test("Override + inconclusive probe (skipped / not-yet-run) → keep overriding")
    func keepsWhenProbeInconclusive() {
        // A skipped probe (no CLI, unknown shell, timeout) or a probe that hasn't
        // finished is not proof the conflict is gone — don't disable the override.
        #expect(!EditorOverride.shouldDropRedundantOverride(
            mode: .overrideInCtrlxSessions,
            probe: .skipped
        ))
        #expect(!EditorOverride.shouldDropRedundantOverride(
            mode: .overrideInCtrlxSessions,
            probe: nil
        ))
    }

    @Test("Non-override modes are never dropped, whatever the probe says")
    func ignoresOtherModes() {
        for mode in [EditorOverrideMode.ask, .useMyEditor] {
            #expect(!EditorOverride.shouldDropRedundantOverride(mode: mode, probe: .intact))
            #expect(!EditorOverride.shouldDropRedundantOverride(mode: mode, probe: .skipped))
            #expect(!EditorOverride.shouldDropRedundantOverride(
                mode: mode,
                probe: .conflict(effectiveValue: "vim")
            ))
        }
    }
}
