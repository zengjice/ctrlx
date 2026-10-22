# Stage 2 — lifecycle and presentation

- [x] App-owned two-second capture loop, write only on content changes.
- [x] Startup gate before folder templates/shared layout seeding.
- [x] Durable recovery attempt before creating any tmux objects.
- [x] Connect main/detached window geometry, ownership, selection and split models.
- [x] Restore Files identity, directory navigation and preview offsets without
  routing an unavailable source through another pane.
- [x] Persist local CtrlX prompt-editor drafts as text, independently of old
  temp files/requests; restore a pane-bound edit/copy entry without submission.
- [x] Save explicit pane/session/window closure and flush before shutdown.
- [x] Preserve unobserved objects and edits to successfully restored workbenches
  during partial retry; retain missing files instead of removing their tabs.
- [x] Add startup recovery mode settings and a non-modal retry/results view.
- [x] Add per-Agent Resume / Use Shell actions and a dead-pane recovery view.
- [x] Retain complete session/window/pane positions when original directories are
  missing, using stopped placeholders and individual or workspace-wide retry.
- [x] Review original-position presentation for remaining tmux structure failures,
  including creation errors and conflicting existing objects.
- [x] Restore Git Changes/History/Stashes previews and unsent commit text. Persist
  Stash object IDs rather than reusable ordinals, keep unavailable selections for
  explicit retry, and retain the saved directory during startup preloading.
- [x] Verify basic App startup/shutdown sequencing for local terminal workspaces
  in an isolated signed Mac app.
- [x] Extend signed-App acceptance to restored terminal buffers, content-click Fit,
  visible output and pane-targeted paste/Return in main and detached windows.
- [x] Verify restored Files, Git and prompt-draft UI; native Agent composition
  remains in Stage 3.
- [x] Exercise off-screen and oversized saved frames against the current AppKit screen.
- [x] Measure capture/write cost against disabled recovery under the same workload.
- [ ] Exercise actual display removal — deferred by the user's 2026-10-16
  review-first decision; not represented as passing.

Evidence (2026-10-15, base `53bb8f2`):

- `.build-local/workspace-recovery-integration-tests.log`: 63 tests in 7 suites
  passed, including compilation of the App composition/MainView bridge.
- `.build-local/workspace-recovery-stage2-drafts-tests.log`: filtered package run
  passed 75 + 6 + 1 + 1 tests across its products. It includes unavailable Files
  source recovery, draft routing through persistent pane identity, no editor
  request recreation, and live prompt capture without its temporary file path.
- Brand/technical boundary scripts and `git diff --check` passed during integration.

Checkpoint workload measurement (2026-10-16):

- The new `Workspace Recovery Performance` scenario uses the signed Debug App,
  12 sessions / 48 windows / 96 idle `cat` panes and an open main window. It uses
  no Relay/pairing or global mouse/keyboard input. The existing MainActor HTTP
  endpoint measures loopback responsiveness; it is not a render-frame timer.
- Attempt 1 exposed a real bulk-identity command-limit failure, now fixed with
  bounded assignment batches (Stage 1). Attempt 2 successfully captured all
  96 panes but failed the measurement script's `/tmp` versus `/private/tmp`
  process lookup; canonical path matching fixes that fixture. These attempts
  remain failed evidence, with normal App exits independently verified.
- CPU counters are converted using the host's Mach timebase, not assumed to
  already be nanoseconds. A 0.2-second calibration agreed with `getrusage` within
  0.001 milliseconds (`cpu-time-calibration.json` under the diagnostics folder).
- Attempt 3 passed all 18 steps in 72 seconds. In the enabled 10-second idle
  sample the 40,703-byte journal retained generation and mtime, with zero process
  disk-write bytes; App CPU used 0.436 seconds. Disabled idle used 0.346 seconds.
  During eight seconds of changes, 207 resizes became five checkpoints and the
  final layout appeared after 1.466 seconds. MainActor loopback p95 was 8.97 ms
  at enabled idle and 69.52 ms during changes; App CPU during changes was 86% of
  one core. This prompted the disabled-resizing comparison below.
  Raw reports are in `.build-local/diagnostics/workspace-recovery-performance/attempt-3/`.
  All 160 Swift hashes stayed unchanged; only the measurement script was extended
  after this run. Both App processes exited normally in 0.181/0.176 seconds.
- Final attempt 4 passed all **18 steps** on **Apple M1 Pro / macOS 27.0.1**,
  using the signed Debug App. The fixture applies the same eight-second resize
  loop with recovery enabled and disabled; completed request counts vary with
  processing time. Enabled metrics additionally include final-checkpoint settling,
  so their average CPU percentages are not a strict active-load comparison.

  | Measurement | Recovery enabled | Recovery disabled |
  | --- | --- | --- |
  | Idle duration / App CPU | 10.015 s / 0.492 s | 10.009 s / 0.385 s |
  | Idle exited-child CPU | 0.162 s | 0.108 s |
  | Idle checkpoint / process disk writes | 0 / 0 bytes | 0 / 0 bytes |
  | Idle MainActor loopback p95 | 9.39 ms | 8.84 ms |
  | Completed resizes / checkpoints | 190 / 5 | 169 / 0 |
  | Resize-loop App CPU, including settling | 8.002 s | 7.461 s |
  | Resize-loop MainActor loopback p95 / max | 83.31 / 110.59 ms | 90.88 / 135.97 ms |
  | Final layout save delay | 2.100 s | Saving disabled |

  The final ~40 KB checkpoint matched actual pane widths. Both idle runs retained
  journal generation and mtime; the disabled resize run also preserved them.
  Enabled resize writes totaled 409,600 process disk bytes including checkpoint
  backups. High load and elevated latency also occur with recovery disabled;
  these samples do not isolate every rendering/process-discovery cost or prove
  a smooth frame rate. Background machine workload was uncontrolled. Native
  Agent batch startup and physical display removal remain separate gates.
- Final report: `.build-local/diagnostics/workspace-recovery-performance/attempt-4/evidence/performance-report.json`.
  All **161 recorded source hashes** (160 Swift plus the measurement script)
  stayed unchanged. The App and E2E builds, strict/deep signature verification,
  focused formatting and brand/technical boundaries passed. Exact-PID launchd
  records confirm normal exits in 0.423/0.177 seconds; all four attempts' fixture
  processes stopped and the test HTTP port was released. No installed App was
  replaced and no physical reboot was performed.

- `.build-local/workspace-recovery-stage2-closure-tests.log`: passed 79 + 6 + 1 + 1
  tests (87 total) after adding partial-closure topology pruning, late draft
  recovery and preserving unavailable Files tabs. This run includes terminal
  environment and native resume command regressions.

Native Agent launch, reconciliation and manual controls are now connected; see
[Stage 3](STAGE3_TODO.md) for native CLI evidence and pending signed-App acceptance.
Mac Viewer/iOS identity and private-state recovery are also outstanding. This
stage is not an end-to-end recovery acceptance claim.

Git component evidence (same source baseline plus current changes):

- `.build-local/workspace-recovery-git-priority-tests.log`: 86 tests in 11 suites
  passed with `./scripts/unit-tests.sh -- --no-parallel --filter
  'WorkspaceAgentRecoveryTests|WorkspaceGitRecoveryTests|WorkspaceRecovery.*Tests|WorkspaceTmuxRecoveryTests|DetachedTerminalWindowsTests|WorkbenchContentContextTests|WorkbenchTabDropTests'`.
- `WorkspaceGitRecoveryTests` exercises actual disposable repositories: staged
  versus unstaged selection, commit previews older than the first history page,
  Stash ordinal changes/deletion, missing-file retry, unchanged HEAD/index and
  unsent text. It also covers cancelled concurrent view/badge loads, Stash reads
  changing mid-load, session identity remapping and one-time snapshot consumption.
- The same scene snapshot now retains the backing terminal selection while Git
  or another utility tab is visible. This prevents restoring the utility preview
  against an arbitrary first terminal. Git preferences such as diff style remain
  in the existing preference store; no confirmation/action state is replayed.
- The pinned GitWorkbench's commit and Stash selection APIs are already public
  through `public extension`; no dependency or fork change was required.
- Signed-App startup and visual acceptance remain unchecked above.

Signed Mac App recovery follow-up (2026-10-16, base `53bb8f2` plus current changes):

- `Workspace Recovery` is a reproducible, isolated E2E scenario with its own App
  instance, state directory and tmux socket. Its 69 steps passed in 59 seconds
  (`.build-local/diagnostics/workspace-app-acceptance-1/attempt-6/`). It covers
  two same-directory sessions, a nested three-pane tree, a workbench split,
  sparse terminal indices, detaching a tab, App restart with live tmux, and a
  simulated boot change with recycled runtime IDs. Existing process IDs survived
  the App-only restart. Rebuilt terminals returned to their directories as shells
  without replaying the interrupted fixture command. Closing the detached window
  returned its tab, and the next App restart retained that ownership.
- The run exposed and fixed a main-window geometry race: setting the frame before
  SwiftUI first displays the window can be overwritten by its initial sizing.
  The saved frame now remains pending until the visible window updates; capture
  preserves that pending frame. Native AppKit regressions cover both local and
  Viewer restoration and verify that later user geometry changes are retained.
  The main scene also disables system scene restoration while CtrlX recovery is
  enabled; disabling CtrlX recovery retains the system behavior. This prevents
  two restoration sources from applying different geometry. See the Apple
  [scene restoration contract](https://developer.apple.com/documentation/swiftui/scene/restorationbehavior%28_%3A%29).
  The focused presentation/Viewer/detachment run passed 52 tests in 3 suites
  (`frame-fix-tests.log` in the same diagnostics directory).
- Main and detached frames survived reconstruction (1000×600 and 850×560).
  The fixture's unchanged 6006-byte journal retained both its contents and mtime
  for five seconds. This checks redundant writes, not a general performance
  benchmark. Logged App terminations completed without the runner's force-kill
  fallback.
- Repeated runs exposed intermittent partial recovery, including one failure
  before detached windows were presented (`attempt-5/`, `attempt-8/`,
  `attempt-10/`, `attempt-11/`). The last trace captured a new shell returning an
  empty `pane_current_path`; all identities and layout dimensions were valid.
  Capture now rereads empty directory metadata up to five times, with four
  25 ms waits. Persistently unavailable metadata still fails without replacing
  the previous checkpoint or inventing a directory. CtrlX editor-probe sessions
  are excluded before identity assignment, matching the existing sidebar filter.
  Deterministic regressions reproduced both transient-cwd failure and probe
  disappearance before this fix (`capture-before-tests.log`: two tests, five
  issues). The focused post-fix run passed 157 tests in 23 suites plus
  7 iOS model tests (`capture-fix-tests.log`). Broader acceptance remains open for
  Agent/Files/Git/draft composition, display removal and real OS reboot.
  The boot-change fixture edits only its private journal after terminating its
  App; it does not reboot the Mac or establish OS-reboot acceptance.
- The same 69-step scenario passed again in `attempt-7/`. During diagnosis,
  a separate real-tmux probe showed that `-f ignore-size` before `attach` was
  interpreted as the global configuration-file option, leaving the control
  client without the intended flag. The option now belongs to `attach`. The
  native connection/reconnection regression reads tmux's actual `client_flags`;
  the expanded 120-test, 19-suite run passed (`control-flags-tests.log`), including
  tmux reconstruction, control protocol and stream consistency. This parameter
  defect has not been established as the cause of the intermittent recovery error.

Final local-terminal acceptance for this follow-up:

- `scene-restoration-build.log`: Mac workspace Debug build passed; strict deep
  code-signature verification passed. No installed App was replaced.
- `attempt-16/`, `attempt-17/`, `attempt-18/`: the final signed App and fixture
  each passed all 69 steps, three consecutive runs of 58 seconds. Every run
  retained the 1000×600 main frame and 850×560 detached frame across reconstruction,
  preserved live process IDs on App-only restart, and passed the shell/no-replay
  and returned-tab checks. No forced App termination was logged.
- The quiet-period assertion now lets one-time startup Fit finish before requiring
  five continuous seconds with unchanged journal contents and mtime. An earlier
  failure at this assertion was a real terminal-grid update (130×38 → 110×29),
  not a redundant write. The final runs observed stable 6017-byte journals for
  5.10–5.11 seconds, after 0.00–0.41 seconds of settling. An endlessly rewritten
  journal still fails the bounded 20-second check.
- Brand/technical boundary checks and `git diff --check` passed. Recovery files
  and new tests passed SwiftFormat. The touched legacy App entry point and
  control client retain the same 58 and 20 pre-existing formatter diagnostics as
  HEAD; no whole-file reformat was performed.
- This establishes the fixture's local lifecycle/geometry/process assertions.
  It does not assert terminal paint in every tile, Agent resume through the signed
  App, Files/Git/draft UI, remote Viewer composition, iOS runtime, missing-display
  behavior, broad capture performance, or a real OS reboot.


Terminal display/input follow-up (2026-10-16):

- The isolated scenario now checks each of the five displayed terminal buffers
  before and after an App-only restart. After tmux reconstruction it pastes a
  distinct command into each terminal through the App's private clipboard,
  presses Return, checks the actual tmux output and SwiftTerm AX contents, and
  rejects that result in the other four displayed panes. Main and detached
  screenshots supplement the buffer assertions.
- Fixture corrections are retained in `attempt-19/` through `attempt-24/` under
  `.build-local/diagnostics/workspace-app-acceptance-1/`: the right split overrides
  a single terminal's AX identifier; AppleScript typing is affected by the active
  IME; overlapping native windows need an explicit title-bar focus click. The
  final fixture changes neither the system input source nor its clipboard.
- Buffer-only success exposed a real recovery regression: main-window Fit still
  required folder-template seeding, which recovered workbenches deliberately
  skip. Local and Viewer recovery markers now also satisfy that readiness gate.
  The actual pre-fix checkpoint in `attempt-24/evidence/returned.json` retained
  80×31 on the left and 120×40 on the equally sized right side; the screenshot
  shows the right-side output clipped above the viewport. `recovered-fit-before.json`
  records this failed dimension comparison. Existing sizing and click-cancellation
  policies remain; the fixture allows the double-click interval before pasting.
- `recovered-fit-macos-build.log`: affected Mac workspace Debug build and strict
  deep signature verification passed. `recovered-fit-tests.log`: **67 tests
  passed** (54 + 13 across five suites), including off-screen/oversized AppKit
  frames, Local/Viewer presentation, and failed/unattempted manual Fit retries.
- `attempt-25/`: the signed App passed all **174 steps in 82 seconds** after the
  production fix. `evidence/input.json` records 80×31 for both workbench sides.
  Both output screenshots were inspected, including visible right-side output;
  main, nested and detached input routing passed. The same run also retains the
  previous geometry, live-process, shell/no-replay, stable-write and returned-tab
  assertions. No forced App termination was logged.
- The three changed Swift files passed SwiftFormat; Python syntax, brand and
  technical boundary checks and `git diff --check` passed. This follow-up does
  not establish physical display hot-plug, Files/Git/draft UI, signed-App Agent
  resume, remote Viewer composition, iOS runtime or real OS-reboot acceptance.

Missing-directory recovery follow-up (2026-10-16):

- Missing directories now produce owned, stopped tmux placeholders instead of
  dropping the session or split. Only an inert bootstrap uses `/`; no interactive
  shell or Agent is launched there. The original directory remains separate from
  actual live cwd, including an interrupted recovery before its first checkpoint.
  Once available, the existing journaled, identity-guarded launch path starts a
  shell in place. Existing live processes are retained and require an explicit
  choice before resolving their pending recovery entry.
- Each ordinary placeholder offers Retry for that pane. The main recovery bar
  retries all remaining targets. Directory errors retain their path during
  periodic reconciliation. Recovery banners now occupy normal layout space above
  the native split view; using a top safe-area inset let them overlap the sidebar
  and terminal tab strip in signed-App screenshots.
- `.build-local/workspace-missing-directory-tests.log`: **50 tests in 3 suites
  passed**. This covers real private tmux reconstruction, sparse windows, missing
  first directories, durable restart/retry, original-directory preservation,
  uncertain launch reconciliation, explicitly kept processes and unaffected PIDs.
  Shared-window interruption coverage now injects an actual split failure rather
  than relying on a missing directory to prevent structure creation.
- A repeated App run exposed dropped Retry clicks during periodic capture. The
  deterministic pre-fix regression in `workspace-retry-busy-before-tests.log`
  failed with two assertions. Explicit retries now wait for the current operation;
  shutdown or cancellation ends the wait. The 50-test run includes the fixed case.
- Signed-App attempts 26–30 under
  `.build-local/diagnostics/workspace-app-acceptance-1/` retain diagnostic evidence:
  the fixture needed an AX value query for static text, a differently named second
  bootstrap session, and bounded observation of normal login-shell initialization
  before asserting shell readiness. Starting that second server without the
  runner's isolated configuration inherited the machine's one-based pane indices;
  input was visible, but the fixture's zero-based capture target did not exist.
  The final bootstrap again uses the runner's private configuration. These
  runs also exposed the banner overlap and dropped-click defects above. They are
  not passing full acceptance runs. The same-name conflict was correctly retained;
  it was not bypassed to complete recovery.
- `missing-directory-macos-build.log`: Mac Debug workspace build and strict deep
  signature verification passed. The final `attempt-31/` passed all **316 steps
  in 163 seconds**. It retains the earlier live-tmux/boot-change/geometry/input
  assertions and adds six missing-directory placeholders, App restart while
  pending, one-pane Retry without launching the other five, workspace-wide Retry,
  preserved runtime pane IDs, unchanged live PIDs on a subsequent App restart,
  and a second round of pane-targeted input in all five displayed terminals.
  Main/detached screenshots were inspected; the recovery bar no longer overlaps
  navigation, and both workbench sides finish at 80×31.
- The runner emitted seven force-kill warnings in this final run, but its cached
  `NSRunningApplication.isTerminated` status did not reflect actual process exit.
  `attempt-31/quit-audit.log` and `quit-audit.json` independently match all seven
  requested quits to launchd status `(0, 0, 0)`, **0.102–0.455 seconds** after the
  request and before the runner's five-second fallback. AppKit logs also show
  cleanup's `replyToApplicationShouldTerminate:YES` before exit. No fixture App
  remains. Future lifecycle diagnostics should check actual process exit rather
  than treating that runner warning alone as evidence of a hung App.
- SwiftFormat (11 touched files), Python syntax, brand/technical boundaries and
  `git diff --check` passed. Files/Git/draft composition, signed-App native Agent
  resume, remote/iOS runtime, other structure failures, physical display removal,
  capture performance and an authorized real OS reboot remain separate work.

Signed-App Files/Git/draft acceptance (2026-10-16, base `53bb8f2` plus changes):

- `Workspace Content Recovery` uses a disposable actual Git repository, Host
  Files and an isolated `editor.open` socket request. The opt-in
  `live-workspace-content` E2E tag keeps the production Files/Git providers;
  existing mock-based scenarios retain their providers. Native text-field input
  uses Accessibility so the fixture does not depend on the user's input method
  or overwrite the system clipboard.
- `.build-local/diagnostics/workspace-content-acceptance/attempt-4/`: **131/131
  steps passed in 90 seconds**. App restart and a simulated boot/tmux replacement
  retained Files navigation, expanded folders, selected file and visible preview;
  the source session/panes acquired new runtime IDs while their persistent IDs
  and shared Files UUID remained stable. Git History and Stash selections restored
  exact object/file identities. The unsent commit text remained in the journal.
- The actual prompt editor's edited text survived as a pane-bound recovered draft,
  whose Copy action produced the exact original text. The old editor overlay did
  not reopen, and another terminal did not display this draft. The original editor
  file, Git HEAD, index, worktree status and Stash object stayed unchanged.
- A final restart with the selected file moved out of the repository preserved
  its Files tab and selection, showed the missing-file error, and did not select
  a sibling. Returning the file and clicking Refresh restored the preview.
  The final fixture verified the repository's original state again. Post-restart
  Files, History, Stash, draft and missing-file screenshots were inspected.
- The first two attempts corrected fixture behavior: an ambiguous `docs` lookup
  selected the expansion button, the blocking editor request needed a background
  tmux job, and selecting Git after deliberately switching to another terminal's
  cwd correctly retargeted Git. Recovery is now checked before that explicit
  retargeting. No production recovery behavior needed changing for these cases.
- `.build-local/workspace-content-macos-build.log`: affected Mac Debug build
  succeeded and strict deep signature verification passed. The E2E runner build,
  Python syntax, brand/technical boundaries and `git diff --check` passed.
  `.build-local/workspace-content-format-comparison.json` shows no additional
  diagnostics versus `HEAD` in the three existing harness files; the other four
  touched Swift files pass SwiftFormat. No unit suite was rerun for this harness
  follow-up; the earlier component/regression results above remain the unit evidence.
- The runner again warned from a stale `NSRunningApplication.isTerminated` value.
  The separate `quit-audit.log` / `quit-audit.json` use launchd's exact-PID exit
  records to establish normal exits before its five-second timeout; this is not
  evidence of an App shutdown failure. All private test App processes ended.
- Remaining structure-failure presentation was reviewed against design section
  5.3: creation errors and name conflicts belong in the central recovery result,
  while missing directories/Agent failures retain actual pane placeholders.
  `WorkspaceTmuxRecoveryTests.partialLinkedWindow` and `nameConflict` in the
  earlier 50-test run cover retry without replacing existing processes and
  refusing a conflicting session. This audit does not add synthetic runtime IDs
  or claim signed-App linked-window composition, which remains tracked separately.

This closes the local Files/Git/draft UI gate. Performance/display-removal checks,
native Agent composition, remote/iOS runtime and an authorized real reboot remain.
