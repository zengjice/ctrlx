# AppKit Toolbar Layout Crash Investigation

Status: mitigated, pending runtime validation

Scope: macOS `3.0.89`, `3.0.95`, `3.0.100`; `3.0.102` is the first distributed
build with the Settings sidebar mitigation. The locally built `3.0.101` package
predates the mitigation and was not published.

Last updated: 2026-10-25

## Fix applied

The Settings `TabView` now uses `.tabViewStyle(.sidebarAdaptable)`. On macOS 15+
this moves Settings navigation out of the native toolbar and into a sidebar when
the window is wide enough. It removes the 11 text-plus-icon tab items from the
toolbar path implicated by the crash.

An isolated SwiftUI probe reproduced the structural difference:

- the default Settings `TabView` exposed 11 `NSToolbarItemViewer` items;
- the same `TabView` with `.sidebarAdaptable` exposed only the standard
  sidebar-toggle and split-view toolbar items.

Cycling all 11 tabs and alternating the window width between 900 and 1100 pt for
60 seconds did not emit the AppKit 300-iteration warning with either variant in
the isolated probe. That probe therefore confirms the toolbar-shape change but
does not prove the production crash is gone. Runtime acceptance must still cover
the real Settings content and a long-lived window.

The real `SettingsView` was then launched from an isolated, re-signed copy with a
different bundle ID. Its Settings window exposed one native toolbar button
(`Hide Sidebar`) and a split group, rather than 11 toolbar tab items. No AppKit
layout warning appeared during the smoke run. This verifies the production view
uses the sidebar path; the 30-minute acceptance check is still outstanding.

## Handoff summary

CtrlX terminated because AppKit detected a non-converging Auto Layout loop in an
`NSToolbarItemViewer`. AppKit repeatedly marked the same window and toolbar item as
needing layout/constraint updates, exceeded its internal iteration limit, threw
`NSGenericException`, and used `+[NSApplication _crashOnException:]` to terminate
the process.

The crashing window was probably the SwiftUI Settings window. Its runtime frame
exactly matches the saved `com_apple_SwiftUI_Settings_window` frame. The primary
suspect is the Settings `TabView`, whose tab items are hosted inside the native
toolbar and which currently contains 11 text-plus-icon tabs in a window whose
minimum width is 900 pt.

This is not a packaging, Sparkle, memory-corruption, or CEF-runtime crash. Chromium
appears near the bottom of the stack only because CtrlX uses CEF's AppKit message
loop as the main event loop.

## Incident

| Item | Value |
|---|---|
| Crash time | `2026-10-25 20:21:03.841 +0800` |
| App | `CtrlX 3.0.100 (33)` |
| Source tag | `v3.0.100` / `ffc37f32fe2d1b6caac66ac18037a4d14ed71362` |
| Executable | `/Applications/CtrlX.app/Contents/MacOS/CtrlX` |
| Process launched | `2026-10-25 19:56:52.6466 +0800` |
| Process ID | `94971` |
| OS | macOS `27.0.1 (26A434)` |
| Hardware | MacBookPro18,3, Apple Silicon |
| Faulting thread | `CrBrowserMain`, main thread |
| Exception | `EXC_BREAKPOINT`, `SIGTRAP`; AppKit-level `NSGenericException` |
| Crash report | `~/Library/Logs/DiagnosticReports/CtrlX-2026-10-25-202117.ips` |

The user-visible symptom was a sudden application exit after roughly 24 minutes of
uptime. The crash report contains no evidence of a Swift fatal error, memory fault,
or signal originating in application code.

## Evidence

### 1. AppKit explicitly reported non-converging toolbar layout

At `20:21:02.615`, about 1.2 seconds before process termination:

```text
Warning: -layoutSubtreeIfNeeded for <NSToolbarItemViewer: 0x76d234aa00>
has continued for 300 iterations because -updateConstraints and/or -layout
has kept the layout or constraints dirty. This problem should be fixed.
Future iterations will be artificially limited.
```

This is AppKit's own diagnosis that the same toolbar item repeatedly dirtied
layout or constraints during one layout pass.

### 2. The same window repeatedly exceeded DisplayCycle limits

From `20:21:03.591` through `20:21:03.678`, AppKit logged the same window moving
further over its update/ layout limits:

```text
Incrementing window 0x76d56e2a00 update constraints count (was 282) ...
Marking window 0x76d56e2a00 as needing Update Constraints in Window
  (limit: 281, count: 283 ...)
...
Incrementing window 0x76d56e2a00 update constraints count (was 286) ...
Marking window 0x76d56e2a00 as needing Update Constraints in Window
  (limit: 281, count: 287 ...)
```

At `20:21:03.715`, AppKit logged `NSGenericException`. The crash report was captured
at `20:21:03.841`.

### 3. The crashing window closely matches the Settings window

The stuck window was reported as:

```text
<SwiftUI.AppKitWindow: 0x76d56e2a00> 0xe136 (57654)
{{322, 282}, {900, 588}}
```

The user defaults contain the following saved frame:

```text
NSWindow Frame com_apple_SwiftUI_Settings_window
= "322 282 900 588 0 0 1920 1050"
```

Position and size are an exact match. This makes the Settings window the primary
investigation target, but it should still be confirmed with live instrumentation.

### 4. The fault stack is inside AppKit/SwiftUI toolbar layout

The `3.0.100` exception backtrace repeatedly enters:

- `-[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]`
- `-[NSToolbarItemViewer constraintsDidChangeInEngine:]`
- `-[NSView updateConstraints]`
- `-[NSView _updateConstraintsForSubtreeIfNeededCollectingViewsWithInvalidBaselines:]`

The `3.0.95` backtrace instead repeatedly enters
`-[NSToolbarItemViewer layout]`. Both are variants of the same non-converging
toolbar-item layout problem.

### 5. The same signature has occurred repeatedly

| App version | Crash time | Crash signature |
|---|---|---|
| `3.0.89 (22)` | `2026-10-21 22:45:04 +0800` | `EXC_BREAKPOINT`; AppKit toolbar layout loop |
| `3.0.95 (28)` | `2026-10-24 15:39:53 +0800` | `EXC_BREAKPOINT`; `NSToolbarItemViewer layout` loop |
| `3.0.100 (33)` | `2026-10-25 20:21:03 +0800` | `EXC_BREAKPOINT`; toolbar constraint-update loop |

`3.0.100 -> 3.0.101` only changes the update UI and does not modify this toolbar
path. Do not assume that building or installing `3.0.101` fixes this crash.

### 6. The existing AppKit diagnostic did not produce a report

The source contains a layout-exception diagnostic in
`CtrlxPackage/Sources/CtrlxServerFeature/Services/AppKitDiagnostics.swift`, but no
corresponding report was written under `~/Library/Logs/CtrlX/AppKit` for this crash.
The exact reason is unknown; the exception path may bypass the current
`NSApplication.reportException:` hook, or reporting may have failed. Any new
investigation must not assume this diagnostic is sufficient.

## Suspected cause and confidence

| Hypothesis | Confidence | Basis |
|---|---|---|
| AppKit toolbar Auto Layout failed to converge | High | Explicit 300-iteration warning and repeated DisplayCycle limit messages |
| The failure is in a SwiftUI-hosted native toolbar item | High | Fault stack and `SwiftUI.AppKitWindow`; repeated `NSToolbarItemViewer` frames |
| The crashing window was Settings | High, not proven | Exact frame match with the saved SwiftUI Settings window |
| Settings tab overflow or width instability at 900 pt is the trigger | Medium | 11 text-plus-icon tabs, 900 pt minimum width, native toolbar tab hosting |
| A main-window custom toolbar item is responsible | Low until Settings is excluded | Dynamic quota/title/trial toolbar content also exists, but the window match favors Settings |

The likely failure sequence is:

1. The Settings window becomes active, is resized, or changes its selected tab.
2. A native toolbar item changes its preferred size/constraints during layout.
3. AppKit tries to satisfy the new constraints while the item again marks itself
   dirty, creating a layout loop.
4. AppKit exhausts its guard threshold and terminates the process rather than
   continuing with an undefined layout state.

The initial user action is unknown. There is no event log in the crash report that
records a tab switch or resize immediately before the warning.

## Relevant source

- `CtrlxPackage/Sources/CtrlxServerFeature/Views/SettingsView.swift:16` defines the
  Settings `TabView`. It currently has 11 tabs and a minimum size of `900 x 500`.
- `CtrlxPackage/Sources/CtrlxServerFeature/Models/Settings.swift:53` lists all
  Settings tabs. `selectedSettingsTab` is transient UI state and is not persisted,
  so the active tab at crash time is unavailable from defaults.
- `CtrlxPackage/Sources/CtrlxServerFeature/Views/MainViewComponents/DashboardQuotaToolbar.swift:22`
  is the main secondary suspect if the Settings-window mapping is disproved. It
  uses a periodic `TimelineView`, `ViewThatFits`, and a dynamically calculated
  toolbar width.
- `CtrlxPackage/Sources/CtrlxServerFeature/Views/MainViewComponents/WorkbenchWindowTitle.swift:8`
  applies OS-version-specific toolbar behavior and should also be checked if the
  crash is reproduced outside Settings.
- `CtrlxPackage/Sources/CtrlxServerFeature/Services/AppKitDiagnostics.swift:121`
  is the current exception-capture implementation that did not write a report.

## Recommended investigation

### 1. Confirm the window and reproduce

Use a signed development build and keep the installed production app untouched.

Stream AppKit and exception logs while exercising Settings:

```bash
/usr/bin/log stream --style compact --level debug \
  --predicate 'process == "CtrlX" AND (subsystem == "com.apple.AppKit" OR subsystem == "com.apple.hiservices")'
```

Repeat these actions while watching for `has continued for 300 iterations`:

- open Settings and keep the window at approximately `900 x 588`;
- switch through every Settings tab repeatedly;
- resize the window to its minimum width and back;
- move focus between Settings and the main window;
- leave Settings visible for at least 30 minutes.

If the warning appears, record the window frame, window identifier, active tab,
and whether the toolbar has overflowed into a menu.

### 2. Capture the unredacted exception with LLDB

The unified log hides the exception reason as `<private>`. An LLDB breakpoint can
inspect it before AppKit terminates the process:

```text
(lldb) breakpoint set -n objc_exception_throw
(lldb) run
(lldb) po $arg1
(lldb) po [(NSException *)$arg1 reason]
(lldb) bt
```

Record the exception reason, the window address, and the `NSToolbarItemViewer`
address. Match the viewer against the live window's toolbar items if possible.

### 3. Change one variable at a time

Start with the highest-value experiments:

1. Temporarily reduce the Settings tabs from 11 to a small set and repeat the test.
2. Temporarily increase the Settings minimum width enough to eliminate toolbar
   overflow, then repeat the test.
3. Replace the Settings `TabView` with sidebar/list navigation and verify whether
   the native toolbar-item path disappears.
4. If Settings cannot reproduce the warning, test the main-window toolbar with
   quotas, trial badge, connection status, and title temporarily removed one at a
   time.

Do not treat `try`/`catch` around AppKit layout as a fix. An AppKit layout
convergence failure indicates an invalid view-constraint cycle; continuing after
catching it would leave the window in an undefined layout state.

### 4. Improve evidence capture

Before or alongside the code fix:

- determine why `AppKitDiagnostics` did not receive this exception;
- capture the exception name and reason before any call that can re-enter layout;
- record the window frame, toolbar item identifiers, and active Settings tab;
- ensure diagnostic writing is synchronous and bounded, as required by the current
  implementation comments.

The existing implementation intentionally avoids reading window titles, labels, and
content. Preserve that privacy boundary unless the user explicitly authorizes more
detail.

## Acceptance criteria

- Repeated Settings tab switching and resizing around `900 x 588` does not produce
  `layoutSubtreeIfNeeded ... 300 iterations` in AppKit logs.
- The Settings window can remain open for at least 30 minutes under normal activity
  without a layout-loop warning or process termination.
- If a main-window toolbar interaction is the real trigger, the same test passes
  with Settings closed and the relevant toolbar controls exercised.
- The fix is verified on macOS 27.0.1 with a signed development build and does not
  replace the user's installed app without explicit authorization.

The structural mitigation is implemented. The acceptance checks above remain
pending runtime verification with the real Settings window; do not mark this
investigation closed until that evidence exists.

## Open questions

- Was the Settings window visible when the user observed the crash?
- Which Settings tab was selected at the time?
- Is the failure reproducible only at the 900 pt minimum width, or also at larger
  widths?
- Does the warning occur with the native Settings toolbar hidden or replaced?
- Why did the current AppKit diagnostic not persist a report?
- Is the trigger a SwiftUI/macOS 27 regression, or a layout pattern in CtrlX that
  also reproduces on earlier macOS versions?

## Non-causes and background

- **Mac packaging:** the crashing process was the installed `3.0.100` app. The
  `3.0.101` DMG was generated after the crash, and packaging does not launch or
  replace `/Applications/CtrlX.app`.
- **Sparkle:** it is absent from the running app.
- **CEF:** CEF only pumps the main event loop in this stack. The fault is thrown by
  AppKit's toolbar layout machinery.
- **Test PTY/tmux leakage:** the environment had test process leakage during an
  earlier phase and it was cleaned up, but no PTY operation appears in the fault
  stack. It is not the primary hypothesis.
