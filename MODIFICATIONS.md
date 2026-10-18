# Modifications

- **Distribution**: CtrlX
- **Fork point**: `919c7772928531d4d0bb266bdf275691d361901e`
- **Fork date**: 2026-08-14
- **Maintainer**: ZengJice `<jicezeng@gmail.com>`
- **Upstream**: [gpambrozio/Gallager](https://github.com/gpambrozio/Gallager)
- **License**: GNU AGPL-3.0

## 3.0.82 — Reliable quotas, Codex questions and Mac light themes

- Prevent Codex quota queries from stalling during child-process cleanup. Observe
  exit asynchronously within the existing 20-second deadline; retain the last
  quota and observation time on failure, with an explicit timeout status.
- Isolate Host account queries per plugin so a slow provider cannot stop other
  accounts refreshing. Keep the one-minute query interval, mark overdue sources
  unavailable and discard responses from removed or stopped sources.
- Normalize unwritten terminal cells and resolve Unicode graphemes when reading
  Codex question prompts on Mac and iOS. Preserve actual drafts, cursor guards
  and the terminal buffer; improve recognition diagnostics without logging text.
- Apply the shared Codex light-theme color adaptation to local, remote and
  detached Mac terminals. Repaint existing content when the theme or Agent
  changes, retaining inverse-video contrast and original terminal data.
- Replace a blocking cleanup wait in the tmux Fit test fixture with the existing
  asynchronous process runner, preserving its layout and ownership assertions.
- Release validation: the bounded serial Swift regression passed with 3,570
  tests reported and nine opt-in probes skipped; Apple Intelligence evaluations
  were excluded. All 24 focused tests passed, including repeated quota queries,
  timeout/cancellation, terminal recognition, native Mac color rendering and
  tmux layout preservation. Three fresh theme screenshots were reviewed.
- Both boundary checks, 89 publisher/COS/distributed-installer tests, website
  build and changed-line SwiftFormat checks passed. There are 54 existing format
  findings in the Mac terminal file and one existing personal shell-wrapper
  argument-forwarding failure; the distributed installer passed all 26 tests.
- Signed Mac and iOS device-SDK Release builds passed. Expired local iOS
  provisioning profiles were renewed through Xcode automatic signing. Physical
  iPhone UI interaction and multi-Mac runtime acceptance were not rerun here.
- Distribution: Mac build 15 through COS, with signature, source metadata and
  complete public-download integrity checks before installer promotion.

## 3.0.81 — Dashboard quicklook, quota alerts and iOS terminal input

- Show waiting panes, account quota summaries and Dashboard access in the Mac
  status menu. Share foreground quota monitoring with iOS and notify once when
  verified fresh account data crosses to 10% remaining. Deduplicate shared
  accounts and quota cycles; ignore stale, offline and conflicting observations.
- Preserve iOS notification navigation when switching sessions from Dashboard.
- Improve Codex text and surface contrast on light iOS terminal themes while
  preserving reverse-video colors. Let plain-terminal taps toggle the keyboard
  without changing link, selection or mouse-reporting behavior.
- Pin the published SwiftTerm explicit-color transform revision in both Apple
  dependency locks; terminal data remains unchanged by display adaptation.
- Release validation: the bounded serial Swift regression passed with 3,558
  tests reported and nine opt-in probes skipped; Apple Intelligence evaluations
  were excluded. The first run stalled in an existing process-cleanup wait;
  the identical-scope rerun passed, including that probe. Both boundary checks,
  89 publisher/COS/distributed-installer tests, 22 bundled-skill tests, the
  production-callback notification navigation regression, website build and
  changed-file SwiftFormat passed. One separate personal shell-wrapper test
  failed because the local ctrlx-install function does not forward arguments;
  the distributed installer passed all 26 of its tests.
- Signed Mac and iOS device-SDK Release builds passed. A same-source signed Mac
  Debug build passed all 58 isolated Host/Viewer menu and Dashboard steps;
  fresh screenshots were reviewed. Physical-iPhone UI interaction and real
  system-notification delivery were not exercised by this release validation.
- Distribution: Mac build 14 through COS, with signature, source metadata and
  complete public-download integrity checks before installer promotion.

## 3.0.80 — Multi-host Dashboard and native Agent CLI maintenance

- Add a shared Mac/iOS Dashboard for Agent account quotas, Host CPU/memory/disk
  and collected usage. Deduplicate shared accounts and Host identities, preserve
  source timestamps, distinguish unavailable/stale data and gate older peers.
- Add Mac Agent Setup with bounded startup detection, explicit native Codex and
  Claude Code installation, managed updates and launch repair. Verify official
  signatures before removing quarantine, preserve working/custom commands and
  refresh guarded settings after successful path repair.
- Give iOS its own terminal theme setting, independent of Mac Host appearance,
  and apply the shared palette to active terminals without restarting sessions.
- Update the Mac installer to skip an already verified identical build, support
  explicit force/verbose flags and retain detailed installation logs locally.
- Release validation: the bounded serial Swift regression passed with 3,544
  tests reported and nine opt-in probes skipped; Apple Intelligence evaluations
  were excluded. Both boundary checks, 90 publisher/COS/installer tests, 22
  bundled-skill tests, the website build, signed Mac Release and iOS device-SDK
  Release builds passed. Eight Agent Setup offscreen UI cases passed; the
  same-source signed Mac Debug build passed the 57-step Dashboard Host/Viewer
  scenario with isolated state, tmux sockets and a private Relay. Reviewed the
  fresh Agent Setup and Dashboard screenshots. Live CLI installation/update,
  cross-machine and iPhone UI acceptance were not run. SwiftFormat reports 46
  existing findings in two files, identical to 3.0.79 and outside changed lines.
- Distribution: Mac build 13 through COS, with signature, source metadata and
  complete public-download integrity checks before installer promotion.

## 3.0.79 — Mac themes, browser app handoff and layout diagnostics

- Add Codex Light for Mac local, remote and detached workspaces, with a shared
  terminal/sidebar/tab palette and readable ANSI colors. Agent-emitted RGB
  colors and Agent syntax-theme settings remain independent.
- Allow human-activated application links in the embedded browser to open the
  registered app on the Host Mac. Preserve the original webpage, report launch
  results to Viewers and reject automatic or Agent-originated handoffs.
- Capture private, bounded AppKit toolbar/window-layout exception diagnostics
  before forwarding the exception to AppKit. This collects evidence; it does
  not claim to fix or recover from the original intermittent layout failure.
- Recognize Codex question prompts followed by complete weekly-usage warnings,
  without rearming dismissed questions when only the warning changes.
- Add iOS window/file tab reordering and an optional image confirmation sheet,
  off by default. Preserve selection and upload target identity, save local
  file-tab order and show failed uploads for manual retry.
- Release validation: the bounded serial Swift regression passed with 3,486
  tests reported and nine opt-in probes skipped; Apple Intelligence evaluations
  were excluded. The first run stalled in the existing process-provenance probe;
  the complete identical-scope rerun passed. Both boundary checks, 63 publisher/COS
  tests, 22 bundled-skill tests, the website build, signed Mac Release build and
  arm64 iOS Simulator build passed. Isolated signed-App acceptance passed 21
  external-application checks and both AppKit diagnostic scenarios; native
  activation/URL core tests also passed. SwiftFormat reports findings in four
  files, including the new banner line following existing indentation; a clean
  whole-file formatting pass is not claimed. Theme UI, real third-party app
  handoff and full iOS UI acceptance were not rerun in this release workflow.
- Distribution: Mac build 12 through COS, with signature, source metadata and
  complete public-download integrity checks before installer promotion.

## 3.0.78 — App-wide debug mode and quieter voice input

- Add a device-local Debug Mode setting on Mac and iOS, off by default. Keep
  it in the application's general diagnostics settings rather than the voice
  settings; voice completion feedback is currently its only consumer.
- Successful voice insertion closes its feedback strip without completion or
  correction notices by default. Debug Mode retains those notices and copyable
  transcript-review evidence. Recording previews and permission, recording and
  insertion errors remain visible regardless of the setting.
- Release validation: the bounded serial Swift regression passed with 3,462
  tests reported and nine opt-in probes skipped; Apple Intelligence evaluations
  were excluded. Voice delivery tests cover Debug Mode on and off. Both boundary
  checks, 63 publisher/COS tests, 22 bundled-skill tests, the website build,
  signed Mac Release build and arm64 iOS Simulator build passed. The six changed
  Swift files have no formatting findings on changed lines; one pre-existing
  whole-file SwiftFormat finding remains. Interactive microphone and settings
  UI acceptance were not rerun in this release workflow.
- Distribution: Mac build 11 through COS, with signature, source metadata and
  complete public-download integrity checks before installer promotion.

## 3.0.77 — Compact permission-mode icons

- Show permission modes as compact icons on Mac and iOS for both Codex and
  Claude Code, including session lists, terminal status bars and session details.
  Keep mode-specific colors and the red bypass warning; retain mode names in
  accessibility labels and Mac hover help.
- Release validation: the bounded serial Swift regression passed with 3,462
  tests reported and nine opt-in probes skipped; Apple Intelligence evaluations
  were excluded. Permission-mode presentation tests, both boundary checks, 63
  publisher/COS tests, 22 bundled-skill tests, the website build, signed Mac
  Release build and arm64 iOS Simulator build passed. The changed Swift file
  passes SwiftFormat. Full UI and screen-reader acceptance were not rerun in
  this release workflow.
- Distribution: Mac build 10 through COS, with signature, source metadata and
  complete public-download integrity checks before installer promotion.

## 3.0.76 — Workspace recovery, browser extensions and faster local files

- Restore saved tmux topology, directories, main/detached window layouts,
  Files/Git selections and unsent drafts. Optionally resume verified Codex and
  Claude conversations; offer layout-only and disabled recovery modes. Preserve
  private Mac Viewer/iOS presentation across Host reconstruction, and reject
  delayed input or commands aimed at replaced terminals. Real OS reboot/login
  and physical display-removal acceptance remain explicitly deferred.
- Manage Host browser extensions from Mac and iOS: preview permissions, import
  ZIP/verified CRX3 packages, install from the Chrome Web Store, update, enable,
  disable and remove extensions. Use native extension-compatible windows and
  separately granted Viewer control. Compatibility remains extension-specific;
  native messaging and cross-machine acceptance are not established.
- Keep Codex question checks stable through terminal redraws, scope session
  worktree details to terminal tabs, route notifications to the owning window,
  and forward Command-C to Codex selections.
- Improve voice capture, correction cancellation and transcript fidelity. Load
  browser guidance at Agent session start and prioritize the Agent iOS skill
  when operating owned simulators. Bundle Codex plugin 1.1.11 and Claude Code
  plugin 1.3.12.
- Speed up local file previews and directory paging while preserving remote
  file behavior.
- Release validation: the bounded serial Swift regression passed with 3,462
  tests reported and nine opt-in probes skipped; Apple Intelligence evaluations
  were excluded. Update shell-integration test fixtures for the guarded tmux
  creation identity and input command format. Both boundary checks, 63
  publisher/COS tests, 22 bundled-skill tests, the website build, signed Mac
  Release build and arm64 iOS Simulator build passed. All 33 bundled plugin
  source files match the source checkout. Existing isolated browser-extension
  and workspace-recovery acceptance is recorded in their implementation docs;
  this release workflow did not repeat those UI runs or hardware acceptance.
  SwiftFormat still reports findings in 35 of the 258 Swift files changed since
  3.0.75, including 23 changed-line findings; the updated fixture lines pass
  scoped lint. No full formatting pass is claimed.
- Distribution: Mac build 9 through COS, with signature, source metadata and
  complete public-download integrity checks before installer promotion.

## 3.0.75 — Click-to-fit Mac terminals and reliable file-link guidance

- After resizing a Mac terminal viewport, an ordinary content click fits its
  owned tmux window once. Record the viewport baseline only after each target
  succeeds, so failed and unattempted split targets remain retryable. Preserve
  selection, links, application mouse reporting, voice holds and IME input;
  cancel delayed clicks when input, focus or presentation changes.
- Supply the shared file-link output guidance through Codex and Claude Code
  SessionStart hooks, including resume, clear, compact and fork. Keep lifecycle
  forwarding unchanged and omit unavailable or malformed guidance silently.
  Bundle Codex plugin 1.1.9 and Claude Code plugin 1.3.10.
- Document the proposed workspace recovery behavior after a computer reboot.
  This is a design record; reboot recovery is not implemented by this release.
- Release validation: the bounded serial Swift regression passed with 3,176
  tests reported and five opt-in probes skipped; Apple Intelligence evaluations
  were excluded. Both boundary checks, 63 publisher/COS tests, 21 bundled-skill
  and hook tests, the website build, signed Mac Release build and arm64 iOS
  Simulator build passed. The Mac bundle's plugin versions, hooks and file-link
  guidance match the source. Native terminal-click and Fit completion regressions
  are included in the Swift suite. SwiftFormat has no findings on changed lines
  across 11 Swift files; existing whole-file findings remain. Full detached-window
  E2E, paired-device and real-agent file-reference
  adherence acceptance were not run in this release workflow.
- Distribution: Mac build 8 through COS, with signature, source metadata and
  complete public-download integrity checks before installer promotion.

## 3.0.74 — Mac workbench gestures and compact worktree status

- Show compact pending, merged and unavailable worktree status controls in Mac
  and iOS session lists. Compare each repository against its unique local main
  or master branch; ambiguous bases remain unavailable. Preserve older Viewer
  compatibility and make the automatic-order reset button easier to use.
- Switch Mac workbench tabs with horizontal two-finger trackpad swipes, using
  the split where the gesture began. Switch once per completed gesture while
  preserving vertical scrolling, modified scrolling and tab-strip scrolling.
- Restore native double-click behavior in empty titlebar areas for main and
  detached workbenches, respecting macOS window-action preferences.
- Reject drops from a different Host or session with an inline explanation,
  consuming the drop so it cannot accidentally tear the tab into a new window.
- Release validation: the bounded serial Swift regression passed with 3,168
  tests reported and five opt-in probes skipped; Apple Intelligence evaluations
  were excluded. All 19 changed Swift files pass SwiftFormat. Both boundary
  checks, 63 publisher/COS tests, the website build, signed Mac Release and arm64
  iOS Simulator builds, and native worktree-status, tab-drop and titlebar UI
  fixtures passed. Native swipe-routing regressions are included in the Swift
  suite. Physical trackpad and paired-device acceptance were not run in this
  release workflow.
- Distribution: Mac build 7 through COS, with signature, source metadata and
  complete public-download integrity checks before installer promotion.

## 3.0.73 — Shared pane tabs, worktree status and clearer voice correction

- Reuse Host-owned Files tabs across clients while preserving private navigation,
  selection and layouts, including iOS workspace restoration. Keep human and
  Agent browser defaults separate; Agent `open` reuses its pane's primary page,
  preserves identical-URL page state, and supports explicit extras with `--new`.
- Show worktree commits pending merge into local `main` in Mac and iOS sidebars,
  with a complete repository worktree list and explicit unavailable states.
  Host-scoped, additive snapshots preserve compatibility with older peers.
- Add Mac terminal-link shortcuts: Command-click opens on the source Host and
  Option-click opens in this Mac's default browser without changing preferences.
  Show the shortcuts in the destination picker.
- Explain voice-correction readiness in settings and show when inserted text
  remains an uncorrected transcription, preserving focus and one-shot delivery.
- Bundle updated browser guidance: Codex plugin 1.1.8 and Claude Code plugin 1.3.9.
- Release validation: the bounded serial Swift regression passed with 3,151
  tests reported and five opt-in probes skipped; Apple Intelligence evaluations
  were excluded. Both boundary checks, 63 publisher/COS tests, the website build,
  signed Mac Release and arm64 iOS Simulator builds, native worktree/voice UI tests
  and browser CLI/ownership tests passed. Both browser engines passed pane-default
  acceptance in a private, signed App with fixture owners and mock Keychain,
  including normal Host exit.
  SwiftFormat has no findings on changed lines across 65 Swift files; existing
  whole-file findings remain. Real-agent, paired-device and microphone/correction
  quality acceptance were not run in this release workflow.
- Distribution: Mac build 6 through COS, with signature, source metadata and
  complete public-download integrity checks before installer promotion.

## 3.0.72 — Mixed-language voice correction and consistent input controls

- Merge `macinput`: improve Chinese/English speech correction with common Git
  vocabulary while preserving ordinary Chinese, explicit branch names, negations
  and existing draft text. Keep complete utterances and response reserves within
  legacy correction budgets; add mixed-language and intent-preservation fixtures.
- Align built-in iOS first-row input buttons to a shared 44-point width at the
  default text size, scaling with Dynamic Type. Recording and loading states keep
  that width; custom buttons remain content-sized.
- Release validation: the bounded serial Swift regression passed with 3,113
  tests reported and five opt-in probes skipped; Apple Intelligence evaluations
  were excluded. Both boundary checks, 63 publisher/COS tests, website build,
  signed Mac Release build and arm64 iOS Simulator build passed. All 13 changed
  Swift files pass SwiftFormat. UIKit-only layout tests, real speech-recognition
  and correction-quality benchmarks, and physical iPhone acceptance were not run.
- Distribution: Mac build 5 through COS, with signature, source metadata and
  complete public-download integrity checks before installer promotion.

## 3.0.71 — Reopen the keyboard when tapping an iOS draft

- Merge `ux`: in iOS Bottom Bar mode, tapping existing draft text opens the
  keyboard while preserving cursor navigation or native TUI clicking. Repeated
  taps keep it open, and tapping again after hiding it resumes editing.
- Recognize bounded multiline drafts without treating terminal output or
  unrelated TUI menus as input. Preserve empty-prompt keyboard toggling,
  selection gestures and composition guards.
- Release validation: the bounded serial Swift regression passed with 3,108
  tests reported and five opt-in probes skipped; Apple Intelligence evaluations
  were excluded. Both boundary checks, 63 publisher/COS tests, website build,
  Mac Debug build and arm64 iOS Simulator build passed. SwiftFormat has no
  findings on changed lines; existing findings outside those ranges remain.
  UIKit-only interaction tests and physical iPhone gesture acceptance were not
  run in this Mac release workflow.
- Distribution: Mac build 4 through COS, with signature, source metadata and
  complete public-download integrity checks before installer promotion.

## 3.0.70 — Hold-to-talk input and session order controls

- Merge `ux`: add Restore Automatic Order beside the new-session button in
  Mac Local and remote Host headers, matching iOS. Keep the context-menu action
  and disable restoration when the section has no saved manual order.
- Support hold to talk on Mac Local and Viewer terminals: hold the microphone
  or a recognized blank prompt cell for 350 ms, then release to insert the final
  text without Return. Preserve short clicks and selection drags; cancel a
  pending recording when released during permission preparation. Align the
  wider microphone with the other 32-point quick-action buttons.
- Move iOS image input into the bottom Attachments menu. In Bottom Bar mode,
  tapping a known empty live prompt toggles the keyboard without sending input;
  preserve draft cursor placement, IME composition and selection gestures.
- Keep distributed build numbers increasing across marketing versions; this
  release uses build 3. Document the iOS synchronization requirement.
- Release validation: the bounded serial Swift regression passed with 3,107
  tests reported and five opt-in probes skipped; Apple Intelligence evaluations
  were excluded. Both boundary checks, 63 publisher/COS tests, website build,
  Mac Debug build, arm64 iOS Simulator build and the isolated native voice-input
  interaction test passed. SwiftFormat has no findings on changed lines;
  whole-file findings outside the changed ranges remain.
- Distribution: Mac package through COS, with signature, source metadata and
  complete public-download integrity checks before installer promotion. Real
  microphone/permission and iPhone gesture acceptance remain separate from
  these automated checks; this release does not install iOS.

## 3.0.69 — Inline voice previews and unified Mac shortcuts

- Merge `macinput`: share context snapshots and one-shot voice delivery across
  Mac and iOS. Show a compact inline preview without resizing the terminal or
  opening a popover; insert the final text once, without Return. Cancel stale
  recordings on input edits, IME composition, target changes or scoped Escape.
  Keep correction fallback and stage diagnostics explicit.
- Unify extended Mac shortcuts under Command-Option. Navigate all tab types in
  the focused split and switch sidebar sessions with the arrow keys; remove
  redundant terminal-only navigation bindings.
- Track Codex question identity through Host and Viewer updates, preserving
  notifications that arrive during a stale pane refresh. Add refusal diagnostics
  and preserve Codex plugin reinstall diagnostics.
- Merge `feature-bug`: simulator Viewers annotate the frame already displayed,
  freezing its image and recipient without waiting for another screenshot.
  Resume preview polling after cancellation or capture failure.
- Release validation: the bounded serial Swift regression passed with 3,098
  tests reported and five opt-in probes skipped; Apple Intelligence evaluations
  were excluded. Both boundary checks, 63 publisher/COS tests, website build,
  Mac Debug build, arm64 iOS Simulator build and the isolated native voice-preview
  interaction test passed. All 37 Swift files in the voice-input merge pass
  SwiftFormat.
- Distribution: Mac package through COS, with signature, source metadata and
  complete public-download integrity checks before installer promotion. Real
  microphone/permission, recognition-quality and paired-device simulator
  annotation acceptance remain separate; this release does not install iOS.

## 3.0.68 — Reliable question expansion and consistent session activity

- Acknowledge guarded Codex question expansion before deduplicating it. Failed
  attempts can retry on later terminal events; successful attempts stay closed
  after Escape. Preserve Host input ordering, report refusal reasons, and gate
  remote acknowledgement support on the Host capability.
- Merge `ux`: use the same representative agent state across clients and order
  idle sessions by their latest task activity. Share Host activity timestamps
  with Viewers without treating session viewing as new task activity.
- Preserve pending automatic terminal Fit across reconnects and request one Fit
  when the owning window or iOS app returns to the foreground. Check live tmux
  dimensions before skipping an unchanged size, and preserve detached ownership.
- Release validation: the bounded serial Swift regression passed with 3,091
  tests reported and five opt-in probes skipped; Apple Intelligence evaluations
  were excluded. Both boundary checks, 63 publisher/COS tests, the website build,
  Mac Debug build and arm64 iOS Simulator build passed. SwiftFormat has no
  findings on changed lines; existing whole-file findings remain.
- Distribution: Mac package through COS, with signature, source metadata and
  complete public-download integrity checks before installer promotion. iOS
  changes require a separate build/install; device UI acceptance remains pending.

## 3.0.67 — Compact iOS session order controls

- Merge `ux`: move Restore Automatic Order beside the new-session button in
  each iOS Host header. Remove the separate ordering row and strategy text,
  keep both controls at 44-point hit targets, and preserve the reset button's
  accessibility label and disabled state when no manual order is saved.
- Release validation: the bounded serial Swift regression passed with 3,069
  tests reported and five opt-in probes skipped. Apple Intelligence evaluations
  were excluded because the model is unavailable on this Mac. Both boundary
  checks, 63 publisher/COS tests, the website build, Mac Debug build and arm64
  iOS Simulator build passed. SwiftFormat passes for the changed range;
  existing findings elsewhere in the file remain.
- Distribution: publish the Mac package through COS with signature, source
  metadata and complete public-download integrity checks, then install the
  matching iOS release on the paired iPhone. On-device layout and accessibility
  acceptance remain separate from build, signing and installation checks.

## 3.0.66 — Mac workspace shortcuts and iOS terminal interactions

- Add common Mac shortcuts for new sessions and terminals, session search,
  focused-side tab navigation and closing, voice input, and terminal font size.
  Keep new-terminal working directories tied to the focused Files/Git context,
  including right-side Files and layouts with moved or detached terminals.
- Merge `ux`: prioritize active iOS sessions in automatic sorting, expose the
  automatic-order reset, and paste clipboard images through the existing
  terminal attachment preview and confirmation flow.
- Merge `feature-bug`: use a consistent iOS terminal link destination sheet
  for Host/device browsing and copying, preserving input suspension until
  dismissal and preventing duplicate presentation.
- Shortcut validation before merge: Mac Debug build, focused Swift tests and
  four isolated Mac E2E scenarios (251 steps) passed. Live remote shortcuts
  and microphone capture remain unverified. After merge, 38 focused tests,
  both boundary checks, 63 publisher/COS tests and the website build passed.
- The bounded serial Swift regression passed with 3,069 tests reported and
  five opt-in probes skipped. Apple Intelligence evaluations were excluded
  because the model is unavailable on this Mac. The merged Mac Debug and arm64
  iOS Simulator builds passed.
- iOS image-paste, link-sheet and keyboard behavior still need physical-device
  UI acceptance; build and installation checks do not establish that coverage.
- Distribution: Mac package through COS; signature, source metadata and public
  download integrity must pass before installer promotion. Install the same
  release on the paired iPhone after Mac publication succeeds.

## 3.0.65 — Simulator screenshot annotations

- Merge `feature-bug` and add in-place screenshot annotation to Mac Host,
  Mac Viewer and iOS Viewer simulator tabs. Capture a bounded, fresh preview,
  mark it with rectangles, arrows or freehand drawing, and add it to the
  selected Agent's input without submitting the prompt.
- Preserve simulator control ownership and native rendering during annotation.
  Suppress input only in the editing Host view, pause only the editing Viewer's
  preview polling, and reject stale captures after source changes or cancellation.
  Reuse image delivery and iOS terminal handoff without duplicating attachments.
- Release validation: the bounded serial Swift regression passed with 3,059
  tests reported and five opt-in probes skipped. Apple Intelligence evaluations
  were excluded because the model is unavailable on this Mac. Both boundary
  checks, 63 publisher/COS tests, website build, Mac Debug build and arm64 iOS
  Simulator build passed. The conflict-resolution file passes SwiftFormat;
  imported files retain existing whole-file formatting findings.
- Native focus/input and capture/routing regressions use isolated test windows
  and injected simulator I/O. Real Host / paired Mac Viewer / iPhone annotation
  and delivery acceptance remains pending; SDK compilation does not establish it.
- Distribution: Mac package through COS, with signature, source metadata and
  public-download integrity verified before installer promotion. iOS changes
  require a separate iOS build/install.

## 3.0.64 — Session directory creation and Codex question notifications

- Add New Folder to the Mac local and remote New Session directory browsers.
  Create inside the selected Host directory, preserve capability checks for
  older Hosts, and enter the new folder without starting a session.
- Rename the agent-history list to Recent Directories on Mac and iOS, explain
  that selecting a directory starts a new session, and show its last-used time.
  Align the existing session-picker UI tests with the updated labels.
- Notify when Codex asks synchronous or asynchronous questions, independently
  of terminal focus. Deduplicate tool calls per session, include a bounded
  preview and preserve agent state and existing structured response forms.
  The shared iOS source also enables foreground question alerts; it requires
  a separate iOS build/install.
- Release validation: the bounded serial Swift regression passed with 3,049
  tests reported and five opt-in probes skipped. Apple Intelligence evaluations
  were excluded because the model is unavailable on this Mac. Both boundary
  checks, 63 publisher/COS tests and the website build passed.
- Validation during merge: 62 focused Swift tests, Mac Debug and arm64 iOS
  Simulator builds, and the isolated Mac Empty State New Session scenario
  passed. Mac directory-search UI acceptance failed while the injected query
  remained in Chinese IME composition; that scenario is not counted as passing.
  Imported Swift sources retain existing formatting findings and the formatter's
  MainView `redundantSelf` parser failure; the five adjusted E2E files pass lint.
- Distribution: Mac package through COS, with source metadata, signature and
  public-download integrity verified by the publisher before installer promotion.

## 3.0.63 — Detached workspaces, voice input and direct COS distribution

- Merge the `ux` and `macinput` work into the Mac release. Detach terminal tabs
  into native windows and combine compatible tabs into independent workspaces,
  preserving terminal ownership, pane input routing and file/browser selection.
- Fit terminals once when entering their tabs or returning from Files/browser
  content, including detached workspaces. Keep passive resizing and snapshot
  updates from repeatedly changing tmux dimensions.
- Add contextual Mac voice input with the shared iOS recognition/correction core,
  bounded context, explicit cancellation and insertion without sending. Improve
  agent command drafts, plugin reinstallation and paused video annotations.
- Include the previously merged narrow status-bar layout fixes, session ordering,
  browser reconnection and Host simulator reuse/read-only Viewer previews.
- Publish packages and the installer directly from the Mac to COS. Verify the
  complete public package before updating the installer under a publication lock;
  retain immutable packages, installer backups and guarded rollback.
- Validation: the bounded serial Swift regression passed with 3,040 tests
  reported and five opt-in probes skipped; Apple Intelligence evaluations were
  excluded because the model is unavailable on this Mac. Both boundary checks,
  196 repository script tests, 63 publisher/COS tests, the website build and the
  Mac Debug build passed. The isolated local detached-window scenario passed
  all 33 steps after fixing its missing window-opening setup. Remote Viewer UI
  acceptance stopped during two-instance pairing setup and remains unverified.
  Broad SwiftFormat lint still reports existing style findings in the merged
  branches; the conflict-resolution and integration files pass their focused
  check (excluding the formatter's `redundantSelf` parser failure).
  The iOS arm64 Simulator build also passed. Final Release packaging and public
  download integrity are verified by the Mac publisher before installer promotion.
- Distribution: Mac package only. Shared iOS changes require a separate iOS
  release/install; this publication does not deploy Relay or replace the running
  local app.

## 3.0.62 — Visible session status in the Mac menu bar

- Keep local and remote session status icons visible in the menu bar dropdown
  on macOS 27, including the accent-colored needs-attention indicator. Explicitly
  preserve icon-and-title labels instead of accepting the system's hidden-image
  default.
- iOS source adds a show/hide control for the saved voice correction API key.
  Keep the key in Keychain, retain unsaved edits, and hide it when switching
  providers, leaving settings, or backgrounding the app.
- Validation: the bounded serial Swift regression passed with 2,862 tests
  reported and four opt-in probes skipped; Apple Intelligence evaluations were
  excluded because the model is unavailable on this Mac. Both boundary checks,
  195 script tests, 30 publisher tests and the website build passed. The menu
  fix passed 35 focused session-state tests, native menu image-visibility checks
  and a Mac Release build during feature acceptance. The iOS settings change
  passed three Simulator tests during feature acceptance and a fresh iOS
  Simulator build for this release.
- Distribution: Mac package only through the existing private channel. The
  iOS settings change requires a separate iOS build/install.

## 3.0.61 — Worktree sessions, file annotations and agent iOS tools

- Add a new-branch worktree option to Start in Directory, with branch name,
  destination and source HEAD preview. Reuse Fork's validation and explicit
  confirmation for uncommitted changes. Keep subdirectory selection and start
  the selected agent in the new worktree; gate remote use by Host capability.
- Annotate supported file previews in place and attach the result to the
  corresponding agent input. Capture the visible preview, including the paused
  video frame, and preserve the annotation during terminal handoff. Accept
  trailing slashes in explicit repository directory links.
- Add local, Codex-owned iOS Simulator tabs and the `ctrlx ios` CLI / agent-ios
  skill: native display, input and accessibility, app and device lifecycle,
  environment settings, optional service profiles, recording and basic pinch.
  Keep device ownership and human takeover explicit. Physical iPhones and remote
  simulator control are not supported; Xcode and an installed runtime are needed.
- Extend worktree-local cleanup to explicitly completed build artifacts and
  document task-based browser tab reuse.
- Validation: the bounded serial Swift regression passed with 2,862 tests
  reported and four opt-in probes skipped; Apple Intelligence evaluations were
  excluded because the model is unavailable on this Mac. Fixed missing simulator
  dependency injection in settings tests; initial Sidecar and video-capture
  failures passed focused and full reruns. Both boundary checks, 195 script tests,
  30 publisher tests, website build, Mac Release build and iOS Simulator compile
  passed. The new worktree form also passed isolated UI interaction checks.
- Distribution: Mac package only through the existing private channel. The
  simulator's existing local acceptance evidence is retained; cross-Mac and
  multi-Xcode compatibility remain unverified. No Relay deployment, local Mac
  replacement or iPhone installation is included.

## 3.0.61 (macinput build) — Detached Mac windows, contextual voice and preview annotations

- Drag Mac terminal Window tabs out of their tab strip into independent native
  windows, including within the same screen. Keep one terminal presentation per
  client, reuse the main window's Fit control and route Files, Fork and links to
  the captured source pane. Closing a detached window returns its presentation
  without terminating the tmux Window.
- Add Mac voice input using the same contextual recognition and correction core
  as iOS. Bound context and correction work, preserve the captured input target,
  and insert without sending. Clicking the microphone again stops and inserts;
  cancelling the preview discards the recording explicitly.
- Keep parameter-requiring Codex and Claude Code `/goal` shortcuts in the input
  field for completion instead of sending Enter. Check installed Agent-side
  CtrlX plugin versions on Mac startup and provide per-configuration reinstall
  controls with a reminder to restart Agent sessions.
- Annotate supported file previews in place and attach the captured image to
  the source Agent, including image, PDF, Office and paused video previews.
  Reject unavailable or protected captures instead of attaching a blank image.
  Accept a trailing slash in explicit repository directory references.
- Add bounded download-cache maintenance on startup and foreground activation,
  protecting active previews and transfers. Enforce size and free-space limits;
  stream video without keeping an application-owned full-file download.
- Include Codex-owned local iOS Simulator tabs and the `ctrlx ios` CLI/skill,
  with input, observation, bounded recording, pinch and explicit storage actions.
  Simulator display and input retain their documented Xcode/runtime limits;
  this is not physical-iPhone or remote-Viewer simulator control. Bundle Codex
  plugin 1.1.6 and Claude Code plugin 1.3.7.
- Distribution: Mac package only, Apple Development signed and not notarized.
  No Relay deployment or local Mac/iPhone installation. iOS UI changes require
  a separate install; deferred device, multi-display and cross-Mac acceptance
  remain listed in the product TODO and simulator design.

## 3.0.60 — Explicit repository links and pane-bound Host browsers

- Reuse each terminal Window's linked Files tab instead of opening another tab
  for each clicked file. Replace automatic path detection with explicit
  `<repo:relative/path>` references, resolved against the current agent worktree
  and checked on the Host. Ordinary paths, file URLs and slash commands no longer
  become Files links; repository references avoid disclosing absolute paths.
- Move Open Browser to Window actions. In-app web links open/reuse the source
  pane's Chromium page on the Host, including from Viewers; the system-browser
  choice still opens on the operating device. Preserve existing local WebKit
  tabs and keep human pages separate from agent-owned pages.
- Normalize equivalent browser URLs, reject embedded credentials explicitly,
  respect Viewer control leases and preserve intervening Git/Files selections
  when an asynchronous browser open completes.
- Guide agent webpage interaction through the shared CtrlX browser skill by
  default while honoring explicit external-browser choices. Do not silently
  switch tools on failure. Add native Claude Code caller discovery alongside
  Codex, preserving process-instance ownership and nested-agent isolation.
  Bundle Codex plugin 1.1.4 and Claude Code plugin 1.3.5.
- Validation: bounded Swift regression (2,688 tests reported, two opt-in probes
  skipped; Apple Intelligence evaluation suite excluded), 189 script tests,
  30 publisher tests, browser CLI checks, both boundary checks, website build,
  and signed iOS device-target build passed. No device UI acceptance in this run.
- Distribution: Mac package only, using cloud-side full HTTPS artifact checking
  plus a bounded client download probe. No Relay deployment or local Mac/iPhone
  installation. Updated iOS behavior requires a separate install; automatic
  skill selection and the new cross-device UI flows still need live acceptance.

## 3.0.59 — Worktree-local build, install and cleanup workflows

- Add a unified local Mac/iOS installer that builds, signs, installs and launches
  through the existing platform scripts. App-only builds avoid unnecessary
  DMG/IPA creation; standalone packaging still produces distributable artifacts.
- Validate reusable signed Apps against their recorded build identity. Stage
  package replacements transactionally and retain local Mac rollback backups.
- Serialize managed builds, tests, installations and cleanup within each
  worktree. Lock installation destinations across worktrees without sweeping
  another worktree's caches or touching simulator state.
- Keep incremental caches by default. Prune completed verification copies and
  install backups with explicit completion records; preserve unmarked or failed
  runs. Optional space-saving cleanup runs only after successful workflows.
- Preserve zero-argument packaging on macOS's system Bash when entering the
  worktree lock, alongside app-only and space-saving options.
- Validation: 189 script tests, 9 worktree regressions, 19 publisher tests,
  brand/technical boundaries and the website build passed. Re-ran 2,705 Swift
  tests using existing products for unchanged Swift sources, excluding the
  unavailable Apple Intelligence evaluation suite. The first Xcode build-settings
  check timed out; the complete script suite passed on rerun.
- Distribution: Mac package only. No Relay deployment, iPhone installation or
  replacement of the local running Mac app; application behavior is unchanged.

## 3.0.58 — Wrapped file links and browser annotation handoff

- Recognize enclosed, word-wrapped filename tails when they cannot fit in the
  preceding row's remaining cells, including Chinese video paths that leave
  six columns unused. Both rows target the complete file; truncated paths,
  independent paths and web URLs retain their existing safeguards.
- Bundle the new `file-links` Skill for Claude Code (plugin 1.3.3) and Codex
  (plugin 1.1.2): short Markdown labels with complete absolute Host targets,
  without manual wrapping or truncation. Keep visible-text compatibility because
  agent terminal renderers do not guarantee explicit file hyperlink metadata.
  Update the installed agent plugin and begin a new session to discover the Skill.
- Keep browser annotations visible while the iOS destination terminal prepares,
  then reveal the ready terminal without a second subscription. Cancellation,
  disconnects and navigation failures preserve the acknowledged attachment;
  retrying Open Agent does not submit the same screenshot again.
- Refresh architecture and contributor documentation for development by
  different AI agents. Distinguish current contracts from historical plans.
- Distribution: Mac package only. No Relay deployment, iPhone installation or
  replacement of the local running Mac app. The iOS handoff requires a separate
  iPhone build/install and physical-device acceptance.

## 3.0.57 — Reliable terminal file links and iOS window swipes

- Separate Chinese prose punctuation from terminal file paths and reject
  ambiguous slash commands, ordinary slash-separated words and visibly
  truncated paths. Do not expose hard-wrapped file URI fragments as independent
  links; join enclosed continuations before checking split ellipses. Explicit
  file hyperlink targets remain authoritative, including shortened labels.
- All three clients share the recognition code and still validate files only
  on activation against the source Host. Update each viewing client to receive
  these recognition fixes; no wire protocol or Relay update is needed.
- iOS swipes now move left to the next Window and right to the previous Window,
  without wrapping at either end. Native gesture handling preserves terminal
  input and scrolling; physical-device swipe acceptance has passed.
- Validation: 82 focused file-link, viewport, URL and Files-workspace tests
  passed, including the reported 21-column hard-wrap case. The release regression
  passed 2,690 serial Swift tests, excluding two unavailable Apple Intelligence
  evaluations. Brand/technical boundaries, 131 script tests, 19 publisher tests
  and the website build passed. Updated recognition still needs physical-device
  acceptance after installation.
- Distribution: Mac package release plus a separately signed local iPhone
  installation. No Relay deployment or local Mac App replacement.

## 3.0.56 — Linked files and interactive browser workflows

- Open underlined terminal file paths directly in the source session's Files
  tabs on Mac Host, Mac Viewer and iOS. Reuse existing directory tabs, resolve
  relative paths on the Host, and preserve web-link precedence, wrapped/CJK
  text and decoded filenames. File checks happen on activation, not hover.
- Add folder creation and file uploads to Files on all clients. Upload from
  coordinated file snapshots, show progress/cancellation, verify bounded chunks
  and publish atomically without overwriting existing files. Remote uploads
  require updated Host and Viewer capabilities; the Relay remains unchanged.
- Improve Viewer browser clarity with display-size/scale-aware, bounded JPEGs
  while retaining Host geometry, remote-click accuracy and legacy peer support.
  Full adaptive quality requires updated Host and Viewer builds.
- Annotate browser screenshots in place and attach them to the corresponding
  Agent input without auto-submission. Resume the latest remote frame after
  annotation ends; preserve recipient identity and control-lease checks.
- Recognize additional textual/symbolic Shift+Left Codex question footers and
  recover idle Codex Fork identity from the active process's rollout files.
- iOS source also adds next-Window right swipes and clarifies custom-button
  auto-send versus insert-only behavior. Those changes need a separate iOS
  installation; physical swipe acceptance is still pending.
- Validation: 2,667 serial Swift tests passed; two unavailable Apple Intelligence
  evaluations were excluded. Brand/technical boundaries, website build, 131
  script tests, 19 publisher tests, 13 installer tests and native browser image
  geometry/budget tests passed. The iOS compile and UIKit test-source typecheck
  passed; these do not replace physical-device gesture acceptance.
- Release scope: Mac package only from this linked worktree. No Relay
  deployment, iOS publication or local App replacement.

## 3.0.55 — Stable Host browser capture and accurate remote clicks

- Capture the existing Host browser surface without CDP clip/scale, avoiding
  transient renderer resizing while Mac/iOS Viewers watch. Resize/compress the
  bounded JPEG on a CEF worker, coalesce same-page capture requests and wait for
  image workers during shutdown. Existing control leases and input remain intact.
- Return CSS dimensions for the complete captured image, including scrollbars,
  using the physical/CSS viewport ratio and pinch scale before downscaling.
  This fixes Viewer click offsets without changing the wire protocol or UI.
- Validation: image bounds/geometry tests, 15 isolated native browser checkpoints,
  18 managed-engine checkpoints, 23 targeted Swift tests and signed native builds
  passed. The screenshot-position regression fails against the previous capture
  runtime and passes with both scrollbars, browser zoom, pinch zoom and Fit.
  Evidence and pending physical-device/WAN acceptance remain in `docs/v3.0.52/`.
  The cached serial release regression passed 2,587 Swift tests; two unavailable
  Apple Intelligence evaluations were excluded. Brand/technical boundaries,
  website build, 131 script tests, 19 publisher tests and 13 installer tests passed.
- Release scope: Mac package only from this linked worktree. Update the Host Mac
  for these fixes; existing Mac/iOS Viewers and the Relay need no update. No Relay
  deployment, iOS publication or local App replacement.

## 3.0.54 — Codex question footer and shell-wrapper compatibility

- Recognize the no-plus `shift← to answer` footer observed in Codex 0.160.0,
  alongside the existing spaced/compact hints and optional elapsed time.
  Mac Host, Mac Viewer and iOS share the same narrow live-screen parser.
- Verify the actual Codex process when tmux reports its telemetry shell wrapper,
  using the existing process scanner with a fresh snapshot. Recheck the live
  composer after inspection; retain draft/cursor/copy-mode guards and Host-wide
  queue-count deduplication. Duplicate counts do not repeat the process scan,
  and no background polling is added.
- Validation: 66 targeted Swift tests passed for footer parsing, native Mac
  snapshots, iOS scheduling, Host guards, process reconciliation and input FIFO.
  The release run exercised 2,587 Swift tests; existing cache-TTL, ephemeral-port
  boundary and tmux refresh timing failures passed isolated reruns. Two unavailable
  Apple Intelligence evaluations were excluded. Brand/technical boundaries,
  website build, 131 script tests, 19 publisher tests and 13 installer tests passed.
  Physical auto-expansion acceptance remains pending an updated installation.
- Release scope: Mac package only from this linked worktree. Update both Host
  and viewing Macs for the new footer; iOS requires a separately updated build.
  No Relay deployment, iOS publication or local App replacement.

## 3.0.53 — Reliable Mac sidebar selection after context menus

- Preserve native sidebar selection for local and remote sessions so cancelling
  a window's Fork submenu does not leave subsequent session clicks unresponsive.
  Scope selection identities to the Host so identical names remain distinct.
- Suppress native selection decoration and retain the existing theme-matched
  highlight controlled by "Highlight selected session in sidebar", default off.
  Keep row buttons, double-click rename, context menus and drag handles unchanged.
- Validation: 61 targeted Swift regressions passed. Isolated production-row UI
  checks passed for light/dark highlight toggles, first-click navigation after
  cancelling a Fork submenu, double-click rename and drag reordering.
  The release regression run and isolated serial Mac rerun passed 2,581 Swift
  tests after a parallel Mac process SIGPIPE; two unavailable Apple Intelligence
  evaluations were excluded. Brand/technical boundaries, website build and
  19 offline publisher tests passed. No iOS source was changed in this release.
- Release scope: Mac package only, published from this linked worktree. No Relay
  deployment, iOS publication or local App replacement.

## 3.0.52 — Viewer browser access and reliable workspace navigation

- Share Host Chromium tabs with Mac and iOS Viewers, including manually opened,
  Agent-owned and popup pages. Keep the Host profile/session, bounded encrypted
  frames and input, explicit control leases and Agent/human handoff. WebKit tabs
  stay local; remote audio, system dialogs and remote DevTools are not included.
  Both Host and Viewer need the updated capability; iOS requires a separate build.
- Discard queued input when browser control is lost, forward Mac hover events,
  and repair split selection after a Host browser tab closes.
- Preserve verified Fork conversation identity while nested Agent helpers run.
- Keep Home browsing responsive without stat-ing mounted child directories, and
  restore dot-prefix and macOS system-hidden filtering before pagination.
- Treat cancelled/obsolete Viewer layout updates as normal window-switch flow,
  while still reporting current disconnects, timeouts and Host rejections.
- Validation: 2,576 Swift tests passed across the full run and serial Mac rerun
  after loaded-run timing failures; two unavailable Apple Intelligence evaluations
  were excluded. Brand/technical boundaries, website build, 131 script tests and
  19 publisher tests passed. Native remote-browser and managed-engine evidence,
  remaining expanded-engine failure, physical Viewer/iPhone UI acceptance and
  throttled WAN measurements are recorded in `docs/v3.0.52/`.
- Release scope: Mac package only, published from this linked worktree. No Relay
  deployment, iOS publication or local App replacement.

## 3.0.51 — Responsive directory browsing and ordered terminal delivery

- Enumerate known directory entries without fetching mounted child metadata,
  preventing an unresponsive Home mount from blocking Start in Directory.
  Preserve hidden-folder filtering, path completion, directory links and bounds.
  Explicitly opening an unresponsive mount still depends on the filesystem.
- Admit terminal output to each Viewer's encrypted FIFO before suspending,
  preserving stream order across overlapping Host fan-out calls. The user
  confirmed the duplicate Shell character was resolved after a local Host update.
- Include the iOS quiet-Shell viewport and final native fit-measurement fixes
  in the corresponding source. These require a separately updated iOS app;
  this Mac publication does not update installed iPhone clients.
- Validation: directory/launch/capability and terminal-stream regressions passed.
  The affected Mac's real Home listing returned 14 folders in 13.5 ms. Mac and
  iOS Release compilation passed; iOS native first-frame/keyboard acceptance
  remains pending because the package scheme lacks an iOS test host.
  The full Swift regression run passed after a serial Mac-suite rerun for a
  process-cache assertion affected by parallel scheduling; two unavailable Apple
  Intelligence evaluations were excluded. Brand/technical boundaries, website
  build, 131 script tests and 19 publisher tests passed.
- Release scope: publish the Mac package on Qcloud from this linked worktree.
  No Relay deployment, iOS publication or local App replacement.

## 3.0.50 — Reliable Mac session reordering and terminal table rendering

- Fix Mac local and remote session drag reordering with a dedicated native drag
  handle and explicit insertion feedback. Save once on release, reject drops
  outside the source group, and preserve selection, rename and context menus.
- Pin the published SwiftTerm correction for partial wide-character overwrites
  and continuation attributes, removing white rectangles in sparse table updates.
  The rendering fix requires an updated display client, including a separate
  iOS build for iPhone users; no Relay deployment is needed.
- Keep the Mac New Session directory form inside its popover with explicit
  padding, sufficient width and vertically expanding explanatory text.
- Validation: 36 session-order regressions and isolated native mouse interaction
  checks passed. SwiftTerm's 619 buffer/rendering tests and the real terminal
  trace replay passed; iPhone runtime acceptance remains separate.
  The release rerun passed 2,529 Swift tests, excluding two existing Apple
  Intelligence evaluations unavailable on this device. Brand/technical boundaries,
  website build, 131 script tests and 19 publisher tests passed.
- Release scope: publish the Mac package on Qcloud from this linked worktree.
  No Relay deployment, iOS publication or local App replacement.

## 3.0.49 — Host-backed Files tabs, media previews and iOS launch controls

- Add independent Host-backed Files tabs on Mac Host, Mac Viewer and iOS,
  opening at the source terminal's directory and restoring per-session layouts.
  Keep directory/search/preview requests bounded and off keyboard delivery.
- Restore local media previews; preview Office documents on all clients, offer
  Download and Open for other remote files, and stream MP4/MOV video with bounded
  range reads, seeking, and scene-safe pause/cancellation.
- Start iOS videos muted with an explicit sound button. Share audio ownership
  across players and protect voice-input cleanup from deactivating video audio.
- Support manual Mac session ordering and iOS session swipe actions. Scope Files
  and Fork entry points to window tabs and move iOS copy into the More menu.
- Fit newly created iOS sessions/windows and Fork windows to the viewport,
  retaining fit intent until state arrives; expose custom Fork names and use
  neutral New Terminal session names.
- Add custom iOS terminal buttons and Host-directory creation, with a full-height
  directory picker. Keep build caches worktree-local and add idle cleanup.
- Validation: 2,518 Swift tests passed on serial rerun; two existing Apple
  Intelligence evaluations were excluded because this device is not eligible.
  Brand/technical boundaries, website build, 131 script tests and 19 publisher
  tests passed. Ten repeated native-playback regressions passed; signed
  development Mac/iOS packages were installed and launched. Actual iPad
  multi-window audio acceptance remains pending.
- Release scope: publish the Mac package on Qcloud from this linked worktree.
  No Relay deployment, iOS publication or further local App replacement.

## 3.0.48 — Editable quick phrases and iOS session controls

- Edit existing quick phrases on Mac and iOS while preserving their stable
  identifiers, ordering, and cross-device synchronization.
- Promote iOS terminal fit to the window toolbar and keep the bottom terminal
  actions focused on frequently used controls.
- Move iOS Close Session to the session-list context menu. Keep Close Window
  in the window menu, and show running-process warnings before closing a session.
- Validation: 2,387 Swift tests passed across the full run and the serial Mac
  rerun; two existing Apple Intelligence evaluations were excluded. Brand and
  technical boundaries, website build, iOS device build and 19 publisher tests passed.
- Release scope: publish the Mac package on Qcloud. The merged iOS changes were
  installed separately on iPhone Air as a local 3.0.47 build. No Relay deployment
  or local Mac replacement is included.

## 3.0.47 — Fork names, terminal quick actions and neutral iOS session names

- Allow custom Codex and Claude Code Fork names on Mac and iOS. Reuse the
  chosen name for the window and, for worktree forks, the branch and directory;
  reject existing names before creating a worktree.
- Move Mac quick-command and quick-phrase buttons to the focused window's
  status bar. Expand both agents' command catalogs and group destructive
  session actions separately without changing pane dispatch guards.
- Show explicit drag destinations when reordering iOS quick phrases, without
  persisting intermediate hover positions.
- Default iOS New Terminal sessions to `session` instead of `claude`, preserving
  saved custom names and existing project/directory naming.
- Release scope: publish the Mac package on Qcloud and build the signed iOS
  device package. No Relay deployment or local Mac replacement is included.

## 3.0.46 — Fork callback isolation and verified session recovery

- Keep Host and shared Mac/iOS Fork callbacks explicitly on MainActor across
  suspended I/O, correcting the Host crash when Fork is requested from iOS.
- Persist native Codex/Claude conversation UUIDs with the pane, stable window
  and kernel process identity. Restore only a matching live process after a
  Host restart; reject reused processes, ambiguous panes and stale records.
  Legacy sessions need one fresh native Agent event to establish the binding.
- Keep identity writes off live status/notification delivery, serialize
  conversation changes, and preserve native IDs during automatic approvals.
  Unavailable Fork actions now expose their specific reason on Mac and iOS.
- Validation: 2,460 Swift tests passed on serial rerun after a parallel-process
  SIGPIPE interruption; two environment-dependent Apple Intelligence evaluations
  were excluded. Mac and unsigned iOS device-target compilation passed.
  Real-device Fork acceptance remains pending installation of the correction.
- This publication packages Mac only. No Relay deployment, iOS package/install
  or local Mac replacement is performed.

## 3.0.45 — Packaging disk checks and worktree-local storage management

- Check available build-volume space before packaging and warn below 20 GiB.
  Add opt-in `--save-space` to local Mac/iOS packaging, removing only the selected
  platform's compiler intermediates and module/SDK caches after success while
  preserving installable apps, packages and downloaded dependencies.
- Keep incremental compilation by default. Remove packaging indexes, duplicate
  dependency copies and verified public-download copies from completed releases;
  retain publication evidence and preserve failed or active publication downloads.
- Add offline regressions for cleanup boundaries, successful/failed packaging,
  argument handling, disk warnings and primary/linked-worktree isolation.
- Include Relay source changes that bound WebSocket memory, close replaced/stale
  connections, add heartbeat/close deadlines and break the pairing/APNs retain cycle.
  These require a separate Relay deployment to take effect in production.
- Release validation: brand/technical boundaries and 143 offline script tests
  passed; 2,351 Swift tests passed. Two existing Apple Intelligence evaluations
  remain unavailable on this Mac (`deviceNotEligible`), so the full-suite result
  is not all green.
- This publication packages Mac only. No Relay deployment, iOS package/install
  or local Mac replacement is performed.

## 3.0.44 — Native conversation forks, terminal updates and internal naming cleanup

- Add native Codex and Claude Code conversation forks on Mac and iOS, using
  the current directory or a new Git worktree. Keep agent configuration scoped
  to the fork invocation, use the intended shell, and verify worktree ignore rules.
- Add Quick Phrase drag reordering on Mac and iOS. Include iOS terminal-fit,
  dollar-key and ordered clipboard-paste improvements from the merged branch.
- Pin the tested SwiftTerm iOS line-layout cache optimization. Package local iOS
  builds as optimized Release by default, retaining local signing overrides and
  a separate Debug artifact for same-source performance comparisons.
- Rename internal CLI, emoji, plugin-contract, path and E2E symbols to Ctrlx.
  Preserve the public ctrlx command, packaged CtrlXCLI binary, saved editor
  preferences, upstream attribution and third-party licenses.
- Support worktree-local packaging and bounded local artifact retention. Remove
  upstream results-repository defaults; make generated proof-video watch commands
  carry the upload repository and release tag, with offline regressions.
- This publication packages Mac only. iOS changes need a separate signed package
  and installation; no Relay deployment or local Mac replacement is performed.

## 3.0.43 — Manual resume identity and Mac command-panel recovery

- Keep the Mac agent-command button openable while pane identity is unavailable.
  Opening an unidentified local panel requests one fresh process snapshot and
  restores its catalog only for the same Host, pane and input revision.
- Suppress ended sessions by their observed old process IDs rather than the
  entire pane, allowing a new agent launched or resumed between scans to be
  recognized. Include agents that replace the pane shell with `exec`.
- Preserve hook authority, failed-probe state, stable panel identity and stale
  send protections. Background reconciliation remains at ten-second intervals;
  unchanged results do not publish observable state or Viewer snapshots.
- Add process-cache ordering, quick-resume, probe-failure and panel-target
  regressions. All 90 focused checks and 2,271 tests in the full run passed;
  two existing Apple Intelligence evaluations remain unavailable on this Mac
  (`deviceNotEligible`), so the full-suite result is not all green.
- This publication packages Mac only and excludes the separate window-Fork
  feature under development. No Relay deployment, iOS reinstall or SwiftTerm
  dependency update is required.

## 3.0.42 — Agent windows, terminal telemetry and Codex question expansion

- Add New Agent window panels on Mac and iOS with one launch card per enabled
  Host agent. Reuse the Host's launch configuration and working directory;
  capability checks preserve compatibility with older Hosts.
- Add Codex telemetry defaults to manual launches in newly created zsh
  terminals, including resume commands. Preserve explicit telemetry settings,
  user shell configuration and argument forwarding; retain Claude telemetry
  environment support. Existing terminals are not retroactively rewritten.
- Automatically expand recognized Codex queued questions on iOS through the
  existing input queue and Host-side guards. Accept legacy and compact shortcuts
  plus optional elapsed-time suffixes on Mac/iOS; timer ticks do not reopen
  dismissed questions or postpone the stable-screen check.
- Preserve draft, IME, selection, scrolling and multi-viewer safeguards. Add
  shared parser, launch, shell integration, scheduler and Host regressions.
  iPhone Air opening and answering passed manual acceptance with the updated Host.
- Update Host Mac and viewing clients for elapsed-footer compatibility. This
  publication packages Mac only; iOS requires its separate signed package/install.
  No Relay deployment or SwiftTerm dependency update is required.
- Release validation: 1,256 tests passed in the full run; all 1,006 Mac tests
  passed on serial rerun after parallel test-process SIGPIPE interruptions.
  Two existing Apple Intelligence evaluations remain unavailable on this Mac
  (`deviceNotEligible`); this is not an all-green full-suite result. Brand and
  technical boundaries, website/iOS builds and 10 publisher regressions passed.

## 3.0.41 — Configurable Mac New Browser and Codex compatibility

- Add Mac Settings → Browser → New Browser → Engine, defaulting to Chromium
  with WebKit as an option. Apply the device-local choice to explicit New
  Browser actions in both local and Viewer workbenches, without converting
  existing tabs or changing terminal-link routing and agent automation.
- Embed human-created Chromium tabs in the existing session/split layout.
  Share CtrlX's dedicated Chromium profile without granting agent control;
  preserve child-tab routing across session renames and workspace cleanup.
  Chromium tabs remain transient; existing WebKit restoration is unchanged.
- Recognize both legacy and compact Codex queued-question shortcut hints,
  retaining live-composer, input-queue and multi-viewer safeguards.
- Keep agent identity when a Host process probe is temporarily unavailable,
  rather than falsely reporting an agent exit. Include the source changes for
  an always-openable iOS command panel with explicit unavailable-state guidance.
- Add preference, routing, lifecycle, ownership and compatibility regressions.
  This publication packages Mac only; iOS needs a separate package/install.
  No Relay deployment or SwiftTerm update is required.

## 3.0.40 — Avoid redundant terminal drawing during fullscreen scrolling

- Commit completed synchronized frames once, avoiding a second delayed redraw
  of the same content. Preserve first-frame/timeout recovery, stable caret,
  ordinary output, and the Mac Retina correction from 3.0.39.
- Reuse Mac CoreGraphics layout for unchanged lines that move during scrolling.
  Bound the cache to visible lines, validate mutations/columns, and rebuild
  row-dependent image placeholders; retain selection and link safeguards.
- Pin the tested SwiftTerm revision and add native-window/cache regressions.
  Isolated Release measurements show reduced drawing work, not guaranteed
  three-device frame rates or elimination of every downward-scroll stall.
- Update each display client for its rendering fix: local/Viewer Mac and iOS.
  This publication packages Mac only; iOS requires a separate package/install.
  No Relay deployment, transport change or Codex setting change is required.

## 3.0.39 — Mac terminal first-frame and Retina correction

- Correct the custom SwiftTerm backing layer's native redraw policy so local
  and Viewer Mac terminals paint their first frame and ordinary output without
  scrolling or waiting for a synchronized-output boundary.
- Keep the backing layer's pixel scale aligned with its window on attachment
  and screen changes; preserve terminal dimensions, selection, cursor and the
  synchronized-presentation/stable-caret improvements.
- Add native-window lifecycle regressions, including SwiftUI hosting and
  Retina scaling, rather than relying only on forced offscreen layer drawing.
- Mac display-client correction only; no Relay deployment or iOS reinstall
  is required for this issue.

## 3.0.38 — Fullscreen terminal interaction and embedded Agent Browser

- Keep Codex's fullscreen transcript and fixed composer. Correct precise
  trackpad/touch distance for its three-row wheel step; preserve Mac native
  momentum and add bounded, interruptible iOS touch momentum. This does not
  claim pixel-smooth scrolling or remove remote network latency.
- Reuse the Host's existing tmux control connection for ordered raw mouse
  input. Never replay ambiguous writes through the process fallback. Preserve
  live subscribers across Host resynchronization and overlapping subscriptions.
- Pin SwiftTerm's synchronized-presentation and stable-caret fixes on both
  Apple platforms. Restore iOS single-tap cursor placement in mouse-reporting
  TUIs while retaining link, selection, IME and inactive-pane protections.
- Include session-routed embedded Chromium tabs for local Codex instances,
  a shared persistent browser profile, the default bounded Vercel engine and
  the retained CtrlX engine. Include scoped page capabilities and native
  DevTools lifecycle fixes; the existing WebKit browser remains available.
- Add regression coverage and document per-client rollout and remaining
  browser/scrolling limits. Update the Host and display clients for the full
  terminal changes; no Relay redeployment or protocol migration is required.
- This Qcloud package uses the existing Apple Development/private-distribution
  path. Developer ID notarization and distribution archives remain gated.

## 3.0.37 — Mac Codex question expansion and post-IME shortcuts

- Restore Shift+arrow terminal shortcuts after committing or clearing IME
  composition by pinning the tested SwiftTerm fix. Preserve candidate selection
  during composition, ordinary navigation, paste and mouse selection.
- Automatically expand Codex's recognized queued-question footer in the focused
  Mac Host or Viewer pane, only at an empty live composer. Reuse Codex's native
  form; never answer questions or send Return automatically.
- Defer while typing, composing, selecting or browsing history. Serialize the
  opener with keyboard input, validate the live screen on the Host and deduplicate
  queue growth across viewers. Unknown layouts remain manual via Shift+Left.
- Add footer, stale-input, multi-viewer, FIFO, post-IME and isolated tmux PTY
  regression coverage. Update both Macs for remote auto-expansion; no Relay
  redeployment is required, and this release adds no iOS auto-opener.

## 3.0.36 — Codex as the default agent

- Prefer Codex in the shared Mac/iOS directory-session form and Mac agent
  settings. Preserve explicit choices and existing project identities; fall
  back to an available Host agent when Codex is absent.
- Default new session requests and the project-start API to Codex. Send the
  CLI's choice explicitly and add `ctrlx start-project --agent` for overrides.
- Preserve Claude attribution when decoding legacy session requests that
  omitted the agent ID. Add default-selection and launch-API regressions.
- No Relay redeployment or SwiftTerm update is required.

## 3.0.35 — Host directory browsing and path completion

- Browse folders when starting a session on Mac (local or Viewer) and iOS,
  starting at the Host's home directory. Navigate into folders, go Home/Up,
  show hidden folders, or type a path to complete its final component.
- Keep browsing separate from launching: only Start in This Directory creates
  the session, using the existing agent launch and telemetry configuration.
- Perform read-only, one-level lookups on the selected Host over the existing
  encrypted command channel. Bound results by count and bytes; debounce input
  and discard late responses when the path or Host changes.
- Preserve manual entry for older Hosts and show missing-path, permission and
  connection errors without changing terminal state. Add filesystem, request
  ownership, Host-isolation and wire-compatibility regression coverage.
- Update both Host and client for directory browsing. No Relay redeployment
  or SwiftTerm change is needed.

## 3.0.34 — Agent sessions in arbitrary Host directories

- Add New Session → Start in Directory on Mac (local and Viewer) and iOS.
  Enter an existing absolute Host path or ~/… and choose an enabled agent;
  a directory no longer needs to appear in the Projects history first.
- Reuse a shared lightweight form and the existing plugin launch contract,
  including Codex's runtime telemetry arguments and plugin environment.
  Do not edit global agent configuration or intercept manually typed commands.
- Resolve and validate directories on the Host before creating tmux state.
  Explicit agent launches fail clearly when the plugin is unavailable or
  Auto-run is disabled, while existing Projects and New Terminal keep their
  optional auto-run and bare-shell behavior.
- Scope remote agent choices to each Host and preserve shell quoting and
  simple command aliases. Add path, launch, Host-isolation and wire-compatibility
  regressions alongside the existing Codex telemetry tests.
- Update both the launching client and the Host for this workflow. The existing
  Relay remains compatible and does not require redeployment.

## 3.0.33 — Expanded agent commands and iOS Shift shortcuts

- Expand the shared Mac/iOS command panels to 24 Codex and 27 Claude Code
  commands, with independent per-agent allowlists and stable display order.
- Check Claude commands against 2.1.276: add effort, diff, review, goal,
  autocompact, output-style, branch, rename and skill/plugin reload entries;
  remove the retired agents manager and omit duplicate or higher-risk actions.
- Keep one-tap submission, the host-side pause before Return, and existing
  draft, permission, connection and focused-pane protections. Bound the Mac
  command grid with scrolling so the expanded catalog remains accessible.
- Pin the published SwiftTerm extension-keyboard update for iOS: Shift arrows,
  Shift-Tab and Shift-Enter send complete chords without sticky Shift state or
  an extra Return. Keep both always-visible shortcut rows unchanged.
- Add command-catalog, submission-guard and Shift transport/accessory tests.
  New commands depend on the Claude/Codex version running on the actual host;
  the existing Relay protocol and phrase synchronization remain unchanged.

## 3.0.32 — Mac modified arrow-key input

- Send Shift+arrow keys through the shared Mac Host/Viewer terminal input path
  instead of letting AppKit consume them as unsupported selection commands.
- Preserve Shift/Alt/Control arrow modifiers in the existing literal keystroke
  transport, including Codex's Shift+Left shortcut for queued questions.
- Preserve ordinary arrows, Option word movement, Command shortcuts, IME
  composition and mouse selection; pin the tested SwiftTerm fork revision.
- Add native keyboard, wire round-trip and isolated real-tmux regressions for
  both control-mode and process-based input, including conflicting root bindings.
- Update the Mac where keyboard input originates. No tmux configuration change,
  Codex update or Relay redeployment is required for this input-path fix.

## 3.0.31 — Device-level quick phrase sync settings

- Unify Mac and iOS phrase synchronization in Settings → Quick Phrase Sync,
  with one local switch per paired device instead of separate Host/Viewer
  controls. Both devices must allow sharing; neither role has priority.
- Group reciprocal pairings by their trusted public key, not their name.
  Preserve consistent legacy choices and ask for confirmation when old
  connection switches disagree, without silently expanding sharing permission.
- Show actual connection and consent status. Preserve offline merges and
  deletion markers, and explain how phrases propagate through trusted devices.
- Include the iOS quick-action glass overlay improvements: keep the terminal
  and keyboard stationary, toggle panels from their toolbar buttons, and
  match the microphone button's appearance to other toolbar controls.
- Add migration, pairing lifecycle, reciprocal permission-combination and
  four-device convergence regressions. Update both clients for the unified
  settings; the existing Qcloud Relay needs no redeployment.

## 3.0.30 — Shared quick actions and phrase synchronization

- Add Mac toolbar panels for agent commands and saved phrases, targeting the
  focused local or remote pane and reusing its ordered keyboard input queue.
- Share the curated command catalog across iOS and Mac. Phrases remain usable
  in ordinary shells and are saved locally before optional synchronization.
- Add per-pair, bilateral opt-in phrase synchronization over the existing E2EE
  connection, with offline merge, stable IDs, permanent deletion markers,
  bounded snapshots and backward-compatible capability negotiation.
- Preserve existing phrases through v1-to-v2 storage migration. Synchronization
  is disabled by default and never submits commands or changes terminal rendering.
- Include the recent iOS quick-phrase, tap-to-record, paired-quote input and
  compact toolbar improvements. Update both clients for phrase synchronization;
  the existing Qcloud Relay remains compatible and is not redeployed.

## 3.0.29 — Mac completion attention

- Acknowledge completed agent tasks from each displayed terminal pane, covering
  local and remote windows on both sides of a split.
- Observe pane state instead of the local pending total, so remote completions
  and same-count state changes no longer leave task markers or Dock badges stale.
- Preserve unread hidden tabs, background completions, blocking approval/question
  forms, and manual state overrides. Reuse existing Host/Viewer state and badge
  synchronization; no Relay or iOS update is required for this Mac fix.
- Add regression coverage for visibility, activation, host-scoped pane identity,
  repeated acknowledgements, and state changes without a pending-count change.

## 3.0.28 — Mac selection during streaming output

- Keep Mac local selections through incoming text, cursor updates and linefeeds,
  independently of mouse-reporting permission. Do not pause or buffer output
  while selecting; application mouse reporting remains available.
- Invalidate buffer-relative selections on buffer replacement and real grid
  changes, not an unchanged AppKit layout pass. Preserve explicit click, text
  input, paste and shortcut cancellation, including CtrlX's direct input routes.
- Add streaming-drag regressions for both pane positions, Shift selection,
  fragmented control sequences and auto-copy in the shared Mac Host/Viewer view.
- This requires the fixed SwiftTerm dependency on the Mac displaying the pane.
  It does not require a Relay deployment or change iOS gesture policy. The
  reported machine-specific new-pane behavior still needs device acceptance.

## 3.0.27 — Mac terminal mouse selection

- Respect Shift-selection and disabled mouse reporting throughout the shared
  Mac Host/Viewer event path, including drags, scrolling and selection auto-copy.
- Preserve mouse modifiers when an application explicitly captures Shift.
- Recognize valid nine-byte SGR mouse reports near the top-left corner so
  press and release events reach the terminal application intact.
- Add regressions for both pane positions, local selection, application mouse
  input, auto-copy, multi-click selection, links, scrolling and short reports.
- Publish a new Mac package. No Relay redeployment is needed; the original
  report of selection failing only in a newly split pane still needs device
  verification and is not claimed as conclusively resolved.

## 3.0.26 — Focused agent skills and image review

- Reduce the two bundled skill entrypoints from 444 to 131 lines, with
  task-specific references for CLI workflows and sidecar contracts.
- Correct CLI targeting/JSON examples and sidecar permission encodings; ignore
  child-agent completion in the starter template. Add isolated protocol,
  resource-sync, and documentation-size regressions.
- Bump the bundled Claude plugin to 1.3.2 and Codex plugin to 1.1.1 so updated
  skills have distinct cache versions.
- Let iOS users open a pending image to review the compressed content, with
  pinch/double-tap zoom and a separate remove action.
- Publish a new Mac package; the existing 3.0.25 Relay remains compatible and
  does not require redeployment. Image review requires a separate iOS build.

## 3.0.25 — Ordered Relay forwarding

- Preserve wire order across text and binary WebSocket frames with one bounded
  inbound FIFO and one async forwarding worker per connection.
- Keep early frames behind pair/entitlement validation. Discard queued frames
  on close, replacement or overflow; recheck source ownership at the send boundary.
- Add lossless-loopback regressions for both directions, immediate upgrade
  traffic, chunked snapshots and the final SwiftTerm composer/status rows.
- Deploy the Relay first and reconnect viewers for a fresh snapshot. Existing
  3.0.24 Mac/iOS clients remain compatible and do not need rebuilding for this fix.

## 3.0.24 — Native terminal viewport synchronization

- Pin the SwiftTerm fork fix that synchronizes the iOS viewport after native
  size/inset changes, including repeated requests for the current bottom row.
- Present an iOS session's initial tail after its native view is attached and
  laid out, without waiting for another terminal output byte.
- Preserve manual history scrolling, selection, and gesture ownership. Add
  regression coverage for initial presentation and native viewport drift.
- Keep the 3.0.23 Host stream fixes unchanged. The iOS viewport correction
  requires an updated iOS build; installing this Mac package alone cannot
  activate it on an iPhone. No Relay deployment is needed for these changes.

## 3.0.23 — Host terminal stream consistency

- Keep snapshot capture and live output on one control connection per tmux
  session, including concurrent connections and pane reopen operations.
- Capture history, visible cells, and cursor in one tmux command transaction;
  drain late responses after timeouts without shifting subsequent requests.
- Add real-tmux regression coverage for duplicate output and inconsistent
  screen/cursor state. Update the Host Mac running the affected sessions;
  updating only a Viewer or Relay does not activate these fixes.

See [terminal rendering investigation](docs/terminal-rendering-investigation.md)
for reproduced causes and verification scope.

## Major changes

- Rebranded the macOS app, iOS app, CLI, Relay, and documentation as CtrlX.
- Isolated Apple bundle identifiers, App Group, Keychain, local state, sockets,
  environment variables, tmux metadata, update infrastructure, and telemetry
  from Gallager.
- Added explicit build-to-source metadata and Relay source-disclosure endpoints.
- Retained the pre-existing customized terminal, tmux, remote-control, Relay,
  notification, and performance work in the complete Git history.

Detailed implementation and acceptance status live in
[`docs/v3.0.0`](docs/v3.0.0/).

This file records distribution-level changes, not every individual commit.
Consult the Git history and release notes for detailed changes.
