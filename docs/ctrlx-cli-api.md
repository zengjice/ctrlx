# CtrlX CLI API

The maintained reference is [the app's bundled CLI API document](../CtrlxPackage/Sources/CtrlxServerFeature/Resources/ctrlx-cli-api.md).

Run `ctrlx --help` for command-line usage.

The installed Mac app automatically creates `~/.local/bin/ctrlx` and adds that
directory to the current user's shell startup configuration, without administrator
permission. Open a new terminal after launching the updated app. Zsh uses
`.zprofile` and `.zshrc` under its effective `ZDOTDIR`; bash uses its existing
login profile and `.bashrc`, and sh uses `.profile`. Repeated launches update one
marked block instead of appending duplicates. Existing commands at that location
are preserved when they are not owned by CtrlX.

**CtrlX → Install Command Line Tool…** installs the launcher. Once installed,
**Reinstall Command Line Tool…** remains available to repair it or add zsh
completion without uninstalling first. **Uninstall Command Line Tool…** removes this user's launcher and
marked configuration, and disables automatic installation until a manual reinstall.
Automatic setup requires the standard CtrlX bundle ID installed under
`/Applications` or `~/Applications`, and is disabled during E2E runs. Legacy
`/usr/local/bin/ctrlx` installations are left untouched.
Existing user installations are still shown in the menu when automatic setup is
disabled, including when the App is launched from a custom directory.

If `ctrlx` is not found, run
`"/Applications/CtrlX.app/Contents/MacOS/CtrlXCLI" --help` and use that quoted
absolute executable path for the same commands. For a differently located App,
use its `Contents/MacOS/CtrlXCLI`. `browser` and `ios` are subcommands of this
executable, not separate CLI installations.
