---
name: agent-browser
description: Default for CtrlX webpage interaction, localhost UI tests, screenshots and video recording via ctrlx browser. For local Codex/Claude Code; not explicitly requested external browsers or native-app UI.
---

# Default browser entry point

For webpage interaction, localhost UI tests, screenshots and video recording in
a local CtrlX Codex/Claude Code session, use `ctrlx browser` by default, even when the
user does not name this skill. It controls the source Host's Chromium; paired
Mac/iOS Viewers can view those pages.

If `ctrlx` is not on PATH, check the bundled CLI before reporting it unavailable:
run `"/Applications/CtrlX.app/Contents/MacOS/CtrlXCLI" browser --help`, then use
that quoted executable path instead of `ctrlx` in the workflow commands. If the
app is installed elsewhere, use its `Contents/MacOS/CtrlXCLI`. `browser` is a
subcommand, not a separate executable; a missing system `agent-browser` package
does not mean CtrlX Browser is missing. A socket error means check the running
Host/connection, not install another browser tool.

Keep the user's explicit browser choice, including requests to use another
browser's existing tab, login or extension. Native-app UI uses its own tools;
ordinary information lookup can use search, fetch or a dedicated API. Source
edits or analysis of an attached image alone do not require opening a browser.

Before operating a webpage, read [workflow](references/workflow.md) for owned-tab
discovery, commands and interaction limits. The workflow links to detailed
actions and extended page commands when needed.

For video capture, read [recording](references/page-commands.md#recording):
background MP4 supports up to 10 minutes while page interaction continues.

If CtrlX is unavailable or an operation unsupported, report the actual blocker
and ask before switching browser surfaces. Do not borrow another pane's identity
or bypass CtrlX routing with a standalone browser client.

Human resource tabs require explicit authorization to this running Agent. List
tabs/devices before use, target the returned ID, and respect paused/revoked grants.
Authorization is use only: do not close human tabs/devices or reclaim them. See
[workflow](references/workflow.md) for ownership and Return Control rules.
