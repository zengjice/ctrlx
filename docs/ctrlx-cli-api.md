# CtrlX CLI API

The maintained reference is [the app's bundled CLI API document](../CtrlxPackage/Sources/CtrlxServerFeature/Resources/ctrlx-cli-api.md).

Run `ctrlx --help` for command-line usage.

The PATH wrapper is optional. If `ctrlx` is not found, run
`"/Applications/CtrlX.app/Contents/MacOS/CtrlXCLI" --help` and use that quoted
absolute executable path for the same commands. For a differently located App,
use its `Contents/MacOS/CtrlXCLI`. `browser` and `ios` are subcommands of this
executable, not separate CLI installations.
