# Stage 4 — remote identity and full acceptance

- [x] Publish optional Host state-root, tmux-incarnation and persistent
  session/window/pane identities with ordinary pane metadata. Forward them
  through per-pair snapshots; preserve older peer decoding.
- [x] Resolve references only within the same pairing and Host state root.
  Recycled runtime IDs, names and directories are not identity evidence.
- [x] Reset shared-layout revision comparison across known Host incarnations;
  retain the last known scope through disconnects and partial discovery.
- [x] Preserve Agent state when a live pane moves between windows/sessions;
  clear it when the actual pane or tmux incarnation changes.
- [x] Capture an input queue's original identity and check it again on drain.
  Gate the optional input identity by an advertised capability. A capable Host
  without complete identity metadata is unavailable, not a legacy fallback.
- [x] Check keys, raw input, paste and interrupt in the same tmux command queue
  as the mutation; also guard the final Questions opener. Raw input keeps the
  existing control connection and consumes both conditional-command responses.
- [x] Persist Mac Viewer ownership, private layouts/selections, Files previews
  and unsent editor drafts; remap fresh routes from stable references.
- [x] Persist iOS navigation/selection, private Files state and unsent drafts;
  preserve offline records and reject replacement Host/name/number collisions.
- [x] Audit restored stream, Files, editor/form and non-input command
  endpoints for generation changes. Input protection alone does not complete
  remote restoration or authorize replay of old request continuations.
- [x] Signed Mac App software acceptance: process discovery + journal + native
  resume, detached/main geometry, incomplete recovery, restore modes and measured
  responsiveness. Physical display removal remains the separate Stage 2 gate.
- [x] iOS affected-platform build and runtime acceptance after private recovery
  integration; a macOS package run does not execute conditional UIKit code.
- [ ] Separately authorized real OS reboot/login acceptance — deferred by the
  user's 2026-10-16 “先交付审查” decision; not represented as passing.

CLI/LayoutDriver continuation follow-up (2026-10-16):

- An isolated real-tmux red test reproduced both environment writes and typed
  commands reaching a replacement server after layout creation. Both cases
  returned success before the fix (four issues in
  `.build-local/workspace-layout-continuation-before-tests.log`).
- Layout application captures its initial session/window/pane identities and
  retains them through options, metadata, splits, commands, waits, hooks and
  final focus. Bootstrap discovery uses the actual created pane and honors
  nonzero tmux indexes. Cancellation and changed-target failures propagate.
- Ordinary CLI input, metadata, selection, creation replies, splitting and
  environment batches now keep their resolved identities. Explicit missing
  pane IDs do not redirect to the active pane. UI-only state reconciles current
  metadata instead of replacing it with an older result after an actor hop.
- **32 tests in 3 suites passed** in
  `.build-local/workspace-cli-layout-tests.log`. This includes both original
  reproductions, normal multi-window/split layout at base indexes 7/4, repeated
  warm application, hook interruption and exact CLI target resolution. The
  earlier 29-test run also passed.
- Seven focused Swift files add no formatting diagnostics; brand/technical
  boundary checks and `git diff --check` pass. The Mac Debug build and strict,
  deep signature check passed, including the final formatting-only rebuild.
  iOS sources are unchanged and its accepted build/runtime evidence is retained.
- Signed-App attempt 1 completed ordinary API calls but its replacement test
  could change identity before the layout captured its target. The fixture now
  waits for the post-capture description write. Attempt 2 passed **17/17 steps**
  and **25 API calls**: ordinary creation/metadata/split/input/layout, a rejected
  delayed layout write, fresh input afterward and preservation of the original
  PID. The selected split terminal screenshot was visually inspected. All 189
  Swift/Python hashes stayed unchanged. Both test processes were removed by
  launchd within 0.146 seconds of quit, before the runner's stale five-second
  fallback warning; retained logs do not provide exit status. Evidence:
  `.build-local/diagnostics/workspace-cli-app-acceptance/attempt-2/` (the failed
  synchronization attempt is retained in attempt-1).

Editor lifetime final follow-up (2026-10-16):

- Prompt requests retain their pane identity through asynchronous file reads,
  publication and submission. A replacement pane retires the request before
  broadcast, preserves unsent text under the original persistent pane UUID and
  removes the obsolete display route. Merely moving a live pane keeps its editor.
  Read failures/invalidated requests now reach the CLI as errors.
- **115 tests in 4 suites passed** in
  `.build-local/workspace-editor-lifetime-tests.log`; after closing the brief
  stale-route display interval, **14 tests in 2 suites passed** in
  `.build-local/workspace-editor-final-tests.log`. Coverage includes suspended
  reads, shutdown, same-number replacement, server changes, live pane moves,
  preserved drafts, unchanged temp files and successful current requests.
- Final Mac build and strict/deep signing passed; six affected Swift files pass
  formatting, and brand/technical boundaries plus `git diff --check` pass.
  iOS source is unaffected. The signed CLI scenario now also exercises the
  native prompt editor and verifies the saved draft and fresh submission.
- Signed-App attempt 3 passed **33/33 steps in 28 seconds**, including the prior
  CLI flow and native editor retirement/fresh submission. The old temporary file
  remained unchanged; the saved journal retains `EDITOR_UNSENT_RETAINED` under
  its original persistent pane UUID; the waiting old CLI received an error and
  the new request successfully wrote `EDITOR_FRESH_SUBMITTED`. Both screenshots
  were visually inspected. All 190 Swift/Python hashes remained unchanged.
  Evidence: `.build-local/diagnostics/workspace-cli-app-acceptance/attempt-3/`.

Implementation closeout (2026-10-16):

- User decision: deliver the implementation and software acceptance for review
  now; defer physical display removal and real OS reboot/login acceptance. The
  pending hardware entries remain unchecked and require a later arrangement.
- Core implementation, identified endpoint fixes and bounded software acceptance
  are ready for review.
  No commit, installed-App replacement or release has been performed.
- Do not expand the audit into additional feature work. Remaining full acceptance
  is bounded to physical display removal and a separately authorized real OS
  reboot. The real OS login launch is part of that hardware gate; settings/service
  combinations have isolated evidence below. Existing evidence above
  remains valid within its stated source and runtime limits; these remaining
  items are not represented as passing.

Linked-window signed-App acceptance (2026-10-16):

- `Workspace Linked Windows` passed **60/60 steps** in
  `.build-local/diagnostics/workspace-linked-app-acceptance/attempt-3/`.
  Two sessions link one physical split window at indexes 0 and 7, and each has
  its own private window. The shared window stays in its original detached
  native window; the main window retains the other session's private selection.
- App restart preserves every pane PID. Simulated boot/tmux reconstruction
  retains both links, the four unique physical panes, persistent identities,
  native scene IDs, ownership and selected tabs. Native accessibility verifies
  both windows' selected tabs and fresh shared-pane output; the rebuilt main
  screenshot was inspected. All 192 Swift/Python source hashes stayed unchanged.
- CtrlX already deduplicated live pane display before this feature (verified
  against HEAD `TmuxService.queryRefreshOutcome`). Native ownership remains
  physical-window scoped. The first two fixture attempts incorrectly expected
  the same pane to have a second session presentation/owner; their failures are
  retained. No product behavior was changed to introduce alias presentations.
- Test App processes and the private tmux socket are gone. The runner reports
  its existing quit fallback warning; this run does not prove graceful exit
  status or a real OS reboot. Other lifecycle evidence remains separately scoped.

Restore modes and native startup responsiveness (2026-10-16):

- **38 tests in 3 suites passed** in
  `.build-local/workspace-recovery-modes-tests.log`. Three restore modes × two
  login-registration states preserve independent settings across reload, select
  the expected reboot policy, and handle a failed login registration without
  changing either setting. LoginItemService is injected; no real login item is
  registered by these tests. Agent policy/controller regressions ran with them.
- `Workspace Recovery Modes` passed **80/80 steps in 81 seconds**, evidence in
  `.build-local/diagnostics/workspace-agent-modes-acceptance/attempt-1/`.
  The actual General-settings picker persists each mode across App restart.
  Layout-only reconstructs four stopped Agent placeholders and shows Resume
  without launching a native Agent. Full recovery resumes both Codex and both
  Claude conversations with exact histories/configuration roots and no new model
  requests. Off leaves the saved journal byte-for-byte intact after a simulated
  boot change and keeps a newly running terminal connected and rendering output.
- Apple M1 Pro, macOS 27.0.1, signed Debug App, Codex 0.162.1 / Claude 2.1.276:
  the private MainActor `session.list` API recorded **80 round trips**, median
  **1.37 ms**, p95 **29.95 ms**, maximum **793.29 ms** while four Agents resumed.
  Pending Agents transitioned 4 → 1 → 0; completion was observed 6.50 seconds
  after starting the observer. No request failed. The maximum is a real transient
  latency, not evidence of smooth frame timing. Timings include Unix-socket
  transport and serialization; background machine load was uncontrolled. The
  fixture rejects a one-second request delay and confirms observation began
  while recovery was pending; it does not certify arbitrary workload scalability.
- Both layout-only and resumed-Agent screenshots were visually inspected.
  All 193 Swift/Python source hashes remained unchanged during this run.
  Production sources are unchanged by these acceptance additions, so the prior
  signed Mac/iOS build evidence remains applicable. No installed App replacement,
  personal login-item change, physical iPhone install or system reboot occurred.

New-session reply adoption (2026-10-16):

- `createSession` now returns its physical server incarnation. Local selection
  retries cannot adopt an identically numbered pane on a replacement server.
  Remote responses carry optional `createdPaneScope`; Mac/iOS wait for matching
  Host/catalog/pane metadata before selecting, and iOS retains the resulting
  session binding for delayed Fit. Legacy Hosts retain their previous behavior.
- **50 tests in 6 suites passed** in
  `.build-local/workspace-new-session-reply-tests.log`: actual tmux creation and
  post-creation restart guards, nonzero indexes, local delayed discovery,
  snapshot/reply arrival ordering, replacement Host/server refusal, delayed Fit
  and old-peer decoding. No real OS reboot is represented by this run.
- Both Mac and iOS Debug builds and strict/deep signature checks passed
  (`workspace-new-session-reply-macos-build.log` and
  `workspace-new-session-reply-ios-build.log` under `.build-local/`). Fifteen
  focused Swift files add no formatting diagnostics; brand/technical boundaries
  and `git diff --check` pass. An initial E2E compile used the wrong argument
  label for an existing helper; the corrected runner builds successfully.
- Signed Mac attempt 1 stopped before creation because the sidebar's combined
  AX heading did not expose the old individual button identifier. Its inspected
  screenshot and subsequent native AX dump identify a fixture issue. The scenario
  now uses the existing local Command-N shortcut and the remote button's help.
  Attempt 2 passed **74/74 steps in 50 seconds**: both local and remote sessions
  were selected and displayed distinct output, while the original PID survived.
  Both screenshots were visually inspected. The two Apps exited normally within
  0.104 seconds. Evidence:
  `.build-local/diagnostics/workspace-new-session-app-acceptance/attempt-2/`.
- Native Agent iOS created and selected `session`, displayed its terminal output
  and automatically fitted to **66×51**. The Host companion passed **17/17 steps**
  and preserved the original PID. A clipboard permission prompt was accepted;
  the long picker produced partial AX snapshots, so the observed New Terminal
  button was tapped at its screenshot-confirmed coordinate. This is fresh UI
  creation acceptance; delayed/replacement replies are covered by the tests above.
  The Host exited normally in 0.125 seconds. All 186 Swift/Python hashes stayed
  unchanged through both accepted scenarios. Private tmux/Relay stopped; the
  owned simulator was terminated, closed, verified idle and deleted. Evidence:
  `.build-local/diagnostics/workspace-new-session-ios-acceptance/attempt-1/` and
  `.build-local/diagnostics/workspace-new-session-ios-device/`.
  No unfiltered suite or Apple Intelligence evaluation was run for this follow-up.

Fork follow-up (2026-10-16):

- The red run reproduced reconstructed sources being accepted during initial
  Fork, asynchronous preparation/checkout and cached retries. Transport also
  failed to retain the source binding. After fixing a test-macro inference issue,
  the three-test run failed with 20 issues
  (`.build-local/workspace-fork-identity-before-tests-2.log`).
- AgentForkSource now carries optional workspace identity. Legacy sources still
  decode and initially match, but the Host captures its current identity before
  asynchronous work. Preparation, checkout continuations and cached replies
  retain it. Existing request-ID deduplication and retained-worktree errors remain.
- Mac/iOS Fork configurations capture the original Viewer input state. Replies
  must still belong to the source session before selecting the new pane; iOS
  carries that session binding into its existing delayed Fit gate.
- Actual window creation checks both the parent session and source pane in the
  tmux queue, including shell-preparation suspension. Created-pane naming/input
  retains the physical creation identity established by the preceding follow-up.
- The focused run's 52 other tests passed; its only failure was cleanup of a
  temporary shell history file after the source-identity assertions succeeded.
  That identity-only fixture now uses cat as its new-window default, and its
  rerun passed. Distinct coverage is **53 tests in 8 suites**, including real Git,
  shell configuration and legacy-wire cases. The stopped leftover directory was
  inspected for open files and removed. Logs: `workspace-fork-identity-tests.log`
  and `workspace-fork-identity-final-tests.log` under `.build-local/`.
- Both platform Debug builds and deep/strict signature verification passed.
  Fourteen focused Swift files add no formatting diagnostics. The fixture uses
  disposable native configuration roots and loopback model replies.
- Signed Mac attempt 1 stopped at 65/116 successful steps: its text-based Fork
  click did not submit the visible panel. The inspected screenshot shows the
  enabled action without an error; the fixture now targets agentFork.create.
  The Host was terminated after the driver's five-second quit deadline with the
  modal still open; this is not a normal-exit acceptance. Viewer, private tmux,
  Relay and local model servers stopped. Evidence is retained under
  `.build-local/diagnostics/workspace-fork-app-acceptance/attempt-1/`.
  Production App sources stayed unchanged. Attempt 2 also stopped before
  submission: the independent button identifier was absent from the accessible
  tree, although the screenshot still showed the panel. Its evidence and
  non-normal Host quit are retained in attempt-2. The fixture now constrains
  the button role and label and captures the full panel tree for diagnosis.
  Attempt 3 captured the exact AX tree: the container overrides child
  identifiers, and substring matching also selects a sidebar whose directory
  includes fork. The final fixture uses exact button labels and reads error
  static text from AXValue. No production change was made for these automation
  failures. Native Fork UI acceptance is pending.

- Attempt 4 exposed a production capture failure: a Claude history lookup
  failed during startup and its failure remained cached after the native
  history became available. The unchanged four-Agent readiness assertion timed
  out. Only successful descriptors are now cached; later checkpoints retry
  failed reads. The follow-up passed **45 tests in 3 suites** in
  `.build-local/workspace-native-history-retry-tests.log`. Both attempt-4 Apps
  exited normally (0.128/0.048 seconds by exact-PID launchd audit).

- The rebuilt Mac App and strict signature check passed after the cache fix;
  iOS App code was unchanged from its successful build. A deterministic native
  regression now hides a private Claude history, restarts the Host, observes the
  saved unavailable reason, restores the history and waits for a valid descriptor.
  Attempt 5 stopped at reconnect because this new restart step lacked the
  fixture's persistent-e2e-storage tag. The test now uses isolated persistent
  storage. All three attempt-5 Apps exited normally within 0.236 seconds.

- Attempt 6 retained pairing, but stopped at reconnect because the fresh
  fixture kept the default Auto-connect on launch setting off. The scenario
  now enables that existing setting through its isolated Host UI before the
  intentional restart. This does not change the production default.

- Attempt 7 still timed out at reconnect after the reported checkbox press,
  so that UI acknowledgement is not evidence the setting changed. Attempt 8
  preconfigures the same private preference file as the accepted Viewer recovery
  fixture, asserts it before hiding history, and records the actual preference
  and paired-viewer count at restart. The reconnect diagnosis remains pending.

- Attempt 8 confirmed auto-connect enabled and one persisted Viewer, then
  passed the deterministic hidden/restored-history regression: all four original
  native PIDs survived and no new model prompts were sent. Local stale Fork
  displayed the expected error; a fresh Fork created and selected its new tab.
  The run stopped at 90/131 successful steps because Codex showed its own
  upgrade prompt before displaying history. Both screenshots were inspected.
  The disposable Codex config now disables startup update checks; the installed
  CLI is unchanged. All three Apps exited normally within 0.114 seconds.

- Attempt 9 passed local stale rejection and fresh native Fork (two distinct
  conversation IDs, zero added prompts), plus remote stale rejection. It stopped
  at 116/131 steps when trying to reopen a tab after the replaced remote session
  correctly cleared its old selection. The fixture now explicitly reselects the
  current session and source pane before opening a fresh Fork. The empty-selection
  screenshot was inspected; all three Apps exited normally within 0.105 seconds.

- Signed Mac attempt 10 passed **141/141 steps in 99 seconds**. It covers
  the deterministic missing/reappearing-history regression, local and remote
  stale Fork rejection, fresh creation/selection and restored native history.
  There are three distinct Codex conversation IDs after two Forks; all four
  original native PIDs are unchanged and no extra model prompts were sent.
  Local and remote output plus remote rejection screenshots were inspected.
  All 185 Swift/Python hashes stayed unchanged; all three Apps exited normally
  within 0.142 seconds. Private tmux, Relay and model servers stopped. Evidence:
  `.build-local/diagnostics/workspace-fork-app-acceptance/attempt-10/`.
  Native Agent iOS Fork acceptance is recorded below.

- Native Agent iOS acceptance passed with the same signed iOS build and the
  updated isolated Host. Replacing the source session while its Fork panel was
  open removed that stale presentation and displayed Session Unavailable;
  all three original windows remained. After explicitly selecting the current
  session, a fresh Codex Fork created and selected its new tab, displayed the
  native saved history, and automatically fitted to **66×51**. The retained
  window name was `claude fork` because the source chooser initially selected
  Claude before the test chose Codex; process/history checks verify Codex.
  All four original native PIDs stayed unchanged, exactly one distinct native
  history was added, and no model prompt was sent. The Host companion passed
  **28/28 steps**; both screenshots were visually inspected. This accepts iOS
  presentation invalidation, not an observed inline stale-error message.
  All 185 source hashes stayed unchanged, the Host exited normally in 0.112
  seconds, and the private tmux/Relay/model servers stopped. The owned guest
  was terminated, closed, checked as idle and deleted. Evidence:
  `.build-local/diagnostics/workspace-fork-ios-acceptance/attempt-1/` and
  `.build-local/diagnostics/workspace-fork-ios-device/`.

New-window creation follow-up (2026-10-16):

- The encrypted transport red run reproduced stale CreateTmuxWindow requests
  crossing a Host replacement (two tests, three issues in
  `.build-local/workspace-create-identity-before-tests.log`).
- Mac/iOS terminal buttons and Agent configuration closures capture the original
  session binding. The Host preserves it through directory/plugin/shell
  preparation and guards actual creation. Reply and selection continuations
  reject replaced sessions; iOS also cancels pending selection and automatic Fit.
- Both tmux creation commands now return their own server incarnation and pane
  ID. Subsequent rename/startup operations cannot reuse a new server's matching
  pane number. First-pane lookup no longer assumes zero base indexes.
- Added real private-tmux preparation/restart interleavings and nonzero-index
  coverage, plus iOS pending-response tests. The first run failed to compile
  because Swift Testing's expression macro captured a mutating call as an
  immutable value; the test now stores each result before asserting it.
- The focused run passed 40 tests in 9 suites. A later inspection also retained
  the session binding after selecting the new iOS tab, until delayed Fit is
  consumed. Its follow-up run passed 26 tests in 3 suites (overlapping the first
  run); the distinct coverage is 53 tests in 10 suites. Logs are
  `.build-local/workspace-create-identity-tests-2.log` and
  `.build-local/workspace-create-fit-tests.log`.
- Mac Debug build and deep/strict signing passed. Mac runtime attempt 1 stopped
  before creation because the New Terminal menu item was not found (60/80 steps
  passed). Its screenshot was inspected; this does not establish a product
  regression. Both isolated Apps exited normally within 0.157 seconds, source
  hashes stayed unchanged and private tmux/Relay stopped. The fixture now uses
  the existing Command-T action to exercise the same creation handler.
- The later code changes are confined to the iOS module and the E2E fixture;
  the signed Mac App remains applicable by source-impact review. The updated
  iOS Simulator build and deep/strict signature check also passed. Fifteen focused
  Swift files add no formatting diagnostics; brand/technical boundaries and
  diff checks passed.
- Signed Mac attempt 2 passed **78/78 steps** in 57 seconds: local and remote
  Command-T create/select usable terminals while preserving the original pane
  PID. Both output screenshots were visually inspected. All 171 Swift source
  hashes remained unchanged. Both Apps exited normally within 0.119 seconds;
  private tmux/Relay stopped and the Relay port was freed. Evidence:
  `.build-local/diagnostics/workspace-creation-app-acceptance/attempt-2/`.
- Native Agent iOS attempt 9 created two terminals through the Tabs sheet. Both
  selected automatically and reached the measured **66x51** viewport. Output
  markers appeared in the correct panes; the second output screenshot was
  inspected. The original pane PID remained **40613**. The 15-step isolated Host
  companion passed; all 171 source hashes stayed unchanged. Evidence:
  `.build-local/diagnostics/plugin-response-agent-ios/attempt-9/`. The owned
  guest was terminated, closed and deleted. The Host exited normally in 0.183
  seconds; private tmux/Relay stopped and the Relay port was freed.
- Fork, queued local CLI/LayoutDriver continuations and new-session reply
  adoption still need their own audit. This validates new-window interactions
  and physical post-creation targeting, not the remaining complete recovery gates.

Reorder/shared-layout follow-up (2026-10-16):

- The encrypted transport regression reproduced stale reorder/shared-layout
  requests reaching a reconstructed Host: the two-test run failed with four issues in
  `.build-local/workspace-layout-identity-before-tests.log`.
- Both requests now carry the session binding. Reorder keeps that identity
  through its window query, swaps and partial-failure rollback. Local and remote
  UI continuations reject replaced session bindings before remapping tab state.
- Shared-layout debounce retains its original session while continuing to resolve
  the final layout after SwiftUI settles. The Host validates actual tmux identity
  and any newer published identity before mutating canonical layout state.
- Added private-tmux interleavings for replacement after listing/after the first
  swap, same-session rollback, and replacement during shared-layout validation.
  Fresh and legacy operations remain covered. The focused run passed **33 tests
  in 5 suites** (`.build-local/workspace-layout-identity-tests.log`). Mac Debug
  build and deep/strict signature verification passed. Eight focused Swift files
  add no formatting diagnostics; brand/technical boundary and diff checks passed.
  iOS Simulator Debug build and deep/strict signature verification also passed;
  no new iOS UI or native iOS runtime check was needed for these Mac actions.
- The signed-App `Workspace Layout Actions` scenario passed **84/84 steps** in
  `.build-local/diagnostics/workspace-layout-actions-app-acceptance/attempt-1/`.
  Local and remote terminal drags changed actual tmux order; local split opening,
  remote collapse and remote split opening converged on both Apps. The terminal
  process PID stayed unchanged. Both directions were visually inspected, and all
  165 Swift source hashes stayed unchanged during the run. Both Apps exited
  normally within 0.112 seconds; private tmux/Relay stopped and the port was freed.
- New window/Agent creation, Fork and queued local CLI/LayoutDriver continuations
  still need their own source-impact audit.

Session metadata follow-up (2026-10-16):

- Description, emoji, color and manual session state now retain the originating
  session identity through Viewer command transport. Mac editors and iOS More
  actions retain their original callbacks when the Host catalog refreshes.
- Host metadata writes guard both the legacy window-option sweep and the final
  session option write against server/session replacement. Persistence errors
  propagate before cached state is updated; transient state overrides also check
  the target identity. Replacing child panes in the same live session is valid.
- `.build-local/workspace-session-metadata-tests.log`: **46 tests in 5 suites
  passed**. Real private tmux tests include replacement during the asynchronous
  window query, fresh/legacy edits, window override cleanup and unchanged process
  IDs after rejection. The encrypted transport red run failed before the fix.
- Mac Debug and iOS Simulator Debug builds succeeded; both App signatures passed
  deep/strict verification. Fourteen focused Swift files have no added formatting
  diagnostics relative to HEAD. Brand/technical boundaries and diff checks passed.
- Mac runtime attempt 1 passed 133 steps before a fixture queried the nonexistent
  `Edit Emoji` menu item. The existing label is `Emoji: 🚀`; only the test was
  corrected. Both isolated Apps exited normally within 0.112 seconds. The failed
  attempt is retained. Corrected attempt 2 passed **159/159 steps**: local and
  remote stale editors reject writes without changing metadata or pane PID;
  fresh description/emoji edits persist and appear in both sidebars. Screenshots
  were visually inspected, all 165 source hashes stayed unchanged during the run,
  and both Apps exited normally within 0.146 seconds. Evidence is under
  `.build-local/diagnostics/workspace-session-metadata-app-acceptance/attempt-2/`.
- Native Agent iOS attempt 8 passed the corresponding More/editor checks:
  replacing the session identity while More is open rejects its later description
  submission; replacing it with the emoji picker open rejects that selection.
  Fresh description and emoji edits persist and appear in the session list, with
  the same physical pane PID. Four screenshots and native action logs are in
  `.build-local/diagnostics/plugin-response-agent-ios/attempt-8/`; the stale
  description and both fresh results were visually inspected. All 165 source
  hashes stayed unchanged. The 15-step isolated Host companion passed.
- The installed CtrlX was initially not running; it was launched normally without
  replacement. Two subsequent guest boot attempts failed the existing memory
  reserve check. Once reported reclaimable memory exceeded the unchanged reserve,
  the third attempt succeeded. These were environment prerequisites, not product
  acceptance failures. The owned test App/guest was terminated, closed and deleted
  after use. The isolated Host exited normally in 0.437 seconds; private tmux and
  Relay stopped and the Relay port was released. The installed user App remains.
- This follow-up does not complete create/shared-layout or queued CLI/LayoutDriver
  identity auditing, or the real OS reboot gate.

Session rename follow-up (2026-10-16):

- An encrypted transport test reproduced an old session editor crossing a Host
  incarnation change. Mac and iOS editors now retain their original callbacks;
  Viewer callbacks capture their catalog binding before scheduling. The command
  wrapper preserves it, and Host `rename-session` checks the actual server and
  session UUID after the asynchronous name lookup, in the mutation's tmux queue.
- Local rename detection now also compares persistent pane identities, preventing
  recycled runtime pane IDs from migrating a replacement's private layout as if
  it were the old session under a new name. Legacy identity-free snapshots retain
  their existing behavior.
- `.build-local/workspace-session-rename-tests.log`: **25 tests in 3 suites passed**.
  Real private tmux checks cover session UUID replacement, restarted servers with
  reused UUIDs, restart after listing names, unchanged name/PID on rejection,
  child replacement within a live session, literal Unicode/quote/semicolon names,
  fresh and legacy renames. The initial transport red run recorded three failed
  assertions in `.build-local/workspace-session-rename-before-tests.log`.
- Mac Debug and generic iOS Simulator Debug builds and strict/deep signatures
  passed. Focused formatting adds no diagnostics versus HEAD; brand/technical
  boundaries and `git diff --check` passed. Signed-App editor acceptance is in
  progress; session metadata, shared layout/create and local CLI/LayoutDriver
  continuations remain under audit.
- Native Agent iOS attempt 6 rejected the retired editor but also rejected a
  newly opened editor. The Host journal already contained the replacement UUID;
  the failed fresh-editor screenshot and explicit `acceptance-status.json` are
  retained in `plugin-response-agent-ios/attempt-6/`. Its manual companion was
  acknowledged only to clean up, not to establish passing editor acceptance.
- A regression reproduced stale publication: ordinary discovery could broadcast
  before its caller/UI observer updated `MirrorWindowManager`, then quiet polls
  never broadcast the corrected identity. `wirePaneRefresh` now updates that
  model synchronously before publishing routes and snapshots. Viewer snapshot
  reads remain read-only; this adds no tmux query. The fixture preserves physical
  identity when simulating a rename and counts subsequent queries relative to
  initial UUID discovery, which legitimately rereads new panes.
- The final focused run passed 31 tests in the other four suites; its only two
  failing assertions were the old fixed query count in the parameterized routing
  test. After correcting that fixture expectation, all 16 simulator-pane tests
  passed, including both rename/publication orderings and identity-only changes
  (`workspace-session-publication-final-tests.log`). The publication red run and
  preceding fixture-identity failure are retained separately.
- Updated native Agent iOS acceptance passed in attempt 7: the open retired
  session editor reports the changed identity without changing name/PID, while
  a freshly opened editor changes both actual tmux and the iOS row to
  `FreshSession`, retaining the same process and replacement session UUID.
  Both outcome screenshots were inspected. Native actions, identity/process
  assertions and explicit acceptance status are retained in
  `.build-local/diagnostics/plugin-response-agent-ios/attempt-7/`; all 159
  recorded Swift source hashes remained unchanged. The 15-step manual Host
  companion passed in 381 seconds including observation time. The exact-PID
  launchd record confirms normal Host exit in 0.186 seconds; the driver's later
  force-quit warning refers to an already exited process. The owned guest was
  terminated, closed and deleted after acceptance; fixture processes stopped
  and the local Relay port was released. Mac session-editor acceptance remains
  pending: attempts 1–3 could not open the context menu and are failed evidence,
  not a demonstrated product regression.
- Attempts 4–6 used a System Events foreground trace that reported the installed
  App while the driver targeted the isolated Host. Attempts 5 and 6 stopped at
  that guard before any right-click. Another worktree's Browser Probe was also
  observed in attempt 5. **The foreground interpretation is superseded below:**
  same-named process resolution made that observer unreliable. These failures
  establish neither a product context-menu regression nor the actual recipient
  of the earlier coordinate input. Their raw evidence is retained.
- Only the E2E driver changed after native iOS acceptance. The E2E rebuild,
  formatting comparison for 16 files (no additional diagnostics), brand/technical
  boundaries and `git diff --check` passed. Attempt 5's 159 recorded Swift hashes
  were unchanged. Exact-PID launchd records confirm normal exits for both Mac
  attempts (4: 0.110/0.054 seconds; 5: 0.116/0.101 seconds); fixture processes
  stopped and the local Relay port was released. These are cleanup results,
  not successful Mac editor acceptance.
- A bounded signed-App probe compared the native focused AX application and
  `NSWorkspace` with the System Events query. Both native APIs reported the
  owned test PID `24801`; System Events repeatedly reported installed PID `9798`.
  The same test row advertised `AXShowMenu`, which opened the native menu even
  though its modal callback returned `cannotComplete`. Evidence is under
  `.build-local/diagnostics/workspace-activation-probe/`. All three owned probe
  Apps and private tmux servers stopped; no Relay or iOS guest was used.
- The E2E driver now checks the focused process through system-wide AX instead
  of name-based AppleScript resolution. Context menus prefer `AXShowMenu` and
  observe/select the actual menu item through AX; unsupported controls still
  require verified foreground focus before mouse input. The menu action's
  timeout is not treated as proof of success. No production App code changed.
- With that driver, `Session Rename` passed **115/115 steps in 83 seconds** in
  `.build-local/diagnostics/workspace-session-rename-app-acceptance/attempt-7/`.
  Both Host and Mac Viewer reject an editor opened before its session UUID was
  replaced, preserving the actual tmux name and pane PID. Fresh editors then
  rename the real session and both sidebars while retaining PID `36555`.
  Four outcome screenshots were inspected; all 162 recorded source hashes
  remained unchanged during the run. Four process-scoped menu actions were used
  with no global right-click. Exact launchd audits confirm normal App exits in
  **0.113 / 0.074 seconds**, private tmux shutdown and local Relay release.
- The E2E build, focused formatting comparison, brand/technical boundaries and
  `git diff --check` passed. Existing native iOS acceptance remains applicable;
  neither iOS nor the production Mac App changed for this follow-up. Session
  editor acceptance is complete; metadata/create/shared-layout and queued local
  CLI/LayoutDriver continuations remain in the endpoint audit.

Window rename follow-up (2026-10-16):

- An encrypted transport regression reproduced a stale window rename crossing
  a Host incarnation change. The editor now captures its original action on
  Mac and its window binding on iOS. Viewer sends preserve that binding, and
  the Host's final `rename-window` checks the actual server and window UUID in
  the same tmux queue. UI errors are surfaced; a fresh editor can retry.
- `workspace-window-rename-tests.log`: **16 tests in 3 suites passed**. Real
  private tmux tests cover window UUID replacement, restart with the same UUID,
  unaffected name/process, fresh rename with literal quotes/semicolon/Chinese,
  replacement of a child pane, and legacy calls. The encrypted transport test
  rejects an old binding before sending and carries the fresh binding to Host.
  The preceding red run is in `workspace-window-rename-before-tests.log`.
- Mac Debug, generic iOS Simulator Debug and E2E CLI builds passed; both App
  signatures passed strict/deep verification. Nine affected Swift files add no
  formatting diagnostics against HEAD after formatting the new conditional
  bodies. Brand/technical boundaries and `git diff --check` passed.
- Native CtrlX Agent iOS acceptance passed in the owned iPhone 18 Pro/iOS 27
  guest: replace the window UUID while the rename alert is open, Save reports
  the retired binding, name/PID remain unchanged, and a fresh editor successfully
  renames the window to `FreshName`. The tab list and actual tmux name agree.
  Inspected screenshots, native actions and `rename-checks.json` are in
  `.build-local/diagnostics/plugin-response-agent-ios/attempt-5/`. The reused
  15-step manual Host companion passed in 468 seconds including observation;
  this is editor acceptance, not another pairing or full recovery regression.
  All 154 recorded Swift hashes were unchanged for this run. The Host exited
  normally in 0.919 seconds, verified by the exact-PID launchd record. The owned
  guest was terminated, closed and deleted, and fixture cleanup was verified.
  Two observation-only waits used an outdated role/title and timed out before
  input; fresh observations corrected them. Native paste prompts were approved
  from observed UI, and text was verified before Save.
- The signed Mac **Window Rename** scenario passed all **140 steps in 98 seconds**
  (`workspace-window-rename-app-acceptance/attempt-4/`): Host and Viewer reject
  their open retired editors, preserve name/PID, then fresh editors change the
  actual tmux name and both tab bars. New Terminal still creates `terminal 1`.
  Final screenshots were inspected; all 154 Swift source hashes stayed unchanged.
  The exact-PID launchd records confirm normal exits in 0.133 and 0.246 seconds.
  The driver's later Host force-quit warning is a stale lifecycle observation;
  the recorded process had already exited normally. Private sockets were removed.
- Attempts 1–3 remain failed evidence. Temporary diagnostics showed the fresh
  callback and tmux rename both succeeded, while AppleScript typing left the
  proposed name as uncommitted IME text. Fixture names now use clipboard paste,
  and the scenario checks actual tmux names before UI synchronization. An
  ineffective callback-read experiment and all temporary logging were removed;
  the final production Swift sources match the accepted Agent iOS run exactly.
  Only the Mac E2E fixture differs from that run. Final Mac/E2E rebuilds and
  signature/format/boundary checks passed. This does not complete session rename,
  metadata, create/shared-layout or the remaining queued CLI/LayoutDriver audit.

Attention/Yolo command follow-up (2026-10-16):

- An encrypted transport regression reproduced stale Yolo/MarkHandled requests
  crossing a Host incarnation change. These commands now use pane bindings;
  Mac captures before scheduling, and iOS detail services use their original
  binding. A retired service also leaves the replacement's local attention alone.
- Host state mutations reject a supplied mismatched identity before changing
  Yolo or attention. Existing permission delivery still validates the form and
  final physical tmux pane. Moving the same physical pane is allowed; legacy
  callers retain the optional-identity path.
- `workspace-attention-final-tests.log`: **39 tests in 5 suites passed**,
  including encrypted stale/fresh commands, Host state preservation after pane
  replacement/server restart, valid live pane moves, existing attention rules,
  detail-service and plugin response tests. The first compile needed the new
  test's Foundation import; the earlier transport red run is separately retained
  in `workspace-attention-before-tests.log`.
- Eight focused Swift files add no formatting diagnostics against HEAD
  (`workspace-attention-format-comparison.json`); brand/technical boundaries
  and `git diff --check` passed. Mac and generic iOS Simulator Debug builds
  succeeded (`workspace-attention-macos-build.log`,
  `workspace-attention-ios-build.log`), with strict/deep signature verification.
- Native **CtrlX Agent iOS** acceptance used an owned iPhone 18 Pro/iOS 27 guest,
  the isolated signed Host and a local Relay. Opening the completed task showed
  Idle in Session Info. Enabling Yolo updated the menu and a subsequent test
  permission wrote exactly `1` to its `cat` pane. Disabling left the next form
  open and output unchanged; re-enabling with that form pending produced `11`
  and retracted it. The second test pane stayed empty throughout. Native actions,
  inspected screenshots, captured output and `attention-checks.json` are in
  `.build-local/diagnostics/plugin-response-agent-ios/attempt-4/`.
- The reused 15-step manual Host companion passed in 457 seconds including
  observation time; this run checks attention/Yolo rather than repeating the
  earlier close/form suites. All 152 recorded Swift hashes stayed unchanged.
  The exact-PID launchd record confirms a normal Host exit in 0.179 seconds.
  Host/Relay/private tmux stopped and the owned guest was closed and deleted.
  A cleanup query initially matched its own shell text; the final check filters
  the actual executable as well as fixture arguments. No user App was replaced.
- Queued create/rename/metadata/shared-layout and local CLI/LayoutDriver actions
  remain under audit; this follow-up does not complete the real reboot gate.

Live identity discovery with recovery disabled (2026-10-16):

- Ordinary discovery now assigns missing UUIDs before publishing new panes,
  including linked session identities before physical-pane deduplication. It
  rereads the actual tmux metadata and retains the last valid state on failure.
  Existing complete metadata adds no assignment/reread command. This path works
  independently of journal loading, periodic checkpoints and the recovery mode.
- Both discovery and recovery capture condition their assignment on the original
  tmux server and an empty option. Concurrent observations cannot overwrite one
  another's UUIDs or assign old records to a replacement server. Reconstructed
  objects still receive their saved UUIDs in the same tmux command as creation.
  Local close dialogs require identity metadata; delayed Agent-end cleanup skips
  a target whose original identity was unavailable.
- The new tests first reproduced missing identities with disabled/corrupt
  journals and concurrent UUID overwrite. The final focused invocation passed
  **103 tests in 7 suites** (`workspace-discovery-final-tests.log`), including
  real private-tmux linked sessions, stable repeated refresh, zero journal writes,
  usable Viewer bindings and server restart between capture and assignment.
- Mac Debug and E2E CLI builds passed (`workspace-discovery-macos-build.log`,
  `workspace-discovery-e2e-build.log`); strict/deep App signature verification
  passed. Nine focused Swift files add no formatting diagnostics against HEAD
  (`workspace-discovery-format-comparison.json`). Brand/technical boundaries and
  `git diff --check` passed. Shared/iOS implementation was unchanged in this
  follow-up; no new iOS build or native iOS interaction is claimed here.
- `Workspace Identity With Recovery Off` passed **153 steps in 123 seconds**:
  `.build-local/diagnostics/workspace-discovery-app-acceptance/attempt-1/`.
  It switches General settings to Off, creates four new targets, exercises local
  and remote window/session confirmation replacement, verifies process survival
  and fresh closes, and compares the journal byte for byte. The settings selector
  was checked through AX; its saved screenshot does not show the off-screen row.
  Error screenshots were visually inspected. All 150 recorded Swift source hashes
  stayed unchanged; isolated Apps, tmux servers and Relay stopped after the run.
  Exact-PID launchd records confirm both Apps exited normally in 0.124–0.291 s.
- Remaining endpoint, linked-window presentation, performance and separately
  authorized real OS reboot gates are unchanged. No unfiltered suite was run.

Close confirmation identity follow-up (2026-10-16):

- Mac local, Mac Viewer and iOS capture the original session/window identity
  before querying running processes or showing confirmation. Viewer process
  queries and close commands share the existing optional identity capability;
  session bindings tolerate child-pane/window changes but reject a replacement
  session, Host or tmux incarnation. Legacy peers retain their compatibility path.
- The Host validates the supplied identity and carries the actual target through
  the existing serialized close/journal transaction. The final conditional tmux
  command checks the same physical target. Delayed Agent-end cleanup also passes
  the pane identity observed when the event arrived, when available.
- `.build-local/workspace-close-identity-tests.log`: **32 tests in 5 suites
  passed**, including real private-tmux reconstruction reusing all UUIDs, wrong
  identity within one server, all three close kinds with/without the journal
  handler, valid fresh closes, encrypted stale/fresh process-query and close
  commands, session binding scope and legacy peers.
- Mac and iOS Debug builds succeeded (`workspace-close-macos-build.log` and
  `workspace-close-ios-build.log`), with strict/deep signature verification.
  Focused formatting passed; three larger files have no added rule diagnostics
  against HEAD (`workspace-close-format-comparison.json`). Brand/technical
  boundaries and `git diff --check` passed. No unfiltered suite was run.
- Native **CtrlX Agent iOS** acceptance used an owned iPhone 18 Pro/iOS 27 guest
  and the existing manual Host companion. Both session and window dialogs stayed
  open across persistent-identity replacement: the old confirmation displayed an
  error and left the original `cat` PID alive; a fresh confirmation closed only
  that target. The other window/session remained. Evidence:
  `.build-local/diagnostics/plugin-response-agent-ios/attempt-3/`, including
  `close-checks.json`, native actions, inspected screenshots and source hashes.
  The 15-step Host companion passed in 344 seconds; its name does not imply that
  this run repeated plugin-form checks. Host exit was normal in 0.216 seconds;
  Host/Relay/private tmux stopped and the owned guest was deleted.
- Fixture corrections preserve the failed evidence: Mac alert text is an AX
  value rather than label, and a same-named native window could receive the
  session-row context click. An empty current-session loop format also hid the
  last retained session from the wait condition after the final successful close;
  a real private tmux control client reproduced that fixture error. iOS also
  waited once for the wrong alert title;
  fresh observation verified the actual `Error` alert without replaying input.
- The corrected **145-step Mac Host/Viewer scenario passed in 107.764 seconds**:
  `.build-local/diagnostics/workspace-close-app-acceptance/attempt-4/`.
  All four old confirmations retained their target processes; fresh confirmations
  closed the intended windows/sessions and retained the keeper. Both signed Apps
  exited normally in 0.154–0.246 seconds. Source hashes stayed unchanged; the
  isolated Apps, Relay and tmux servers stopped. The final E2E-only rebuild is
  `.build-local/workspace-close-e2e-acceptance-build.log`; App sources did not
  change during the fixture corrections.
- The discovery follow-up above handles missing identity with recovery disabled.
  The remaining queued CLI/create/metadata/layout endpoints still require the
  broader audit. These checks do not establish a real OS reboot result.

Fit/split/selection identity follow-up (2026-10-16):

- Viewer window actions retain pairing, Host state root, tmux incarnation and
  persistent window identity, independently of the current representative pane.
  Replacing an active pane in the same live window remains valid. Mac and iOS
  capture the original binding before queuing Fit, split and selection work;
  local pane/window actions pass their original identities through to tmux.
- Fit guards both the layout read and the resize/select-layout mutation against
  the physical window. Split and pane/window selection use the same conditional
  tmux queue as their mutations. Automatic Fit waits for usable identity metadata;
  both automatic and manual Mac Fit use the same request builder. Retired results
  cannot mark a replacement window fitted or display its predecessor's error.
- `.build-local/workspace-noninput-final-tests.log`: **29 tests in 7 suites
  passed**, including encrypted old-binding rejection and fresh-command delivery,
  legacy peers, actual private-tmux reconstruction, and a restart between Fit's
  layout read and mutation that reuses the same persistent window UUID. The new
  server remains unchanged. Existing Fit partial-failure retry checks also pass.
- Both platform Debug builds and strict/deep signature checks passed. The final
  Mac build is `.build-local/workspace-noninput-macos-final-build.log`; iOS uses
  `.build-local/workspace-noninput-ios-build.log`. Formatting comparison has no
  added diagnostics; the final MainView change also passes SwiftFormat directly.
  Brand/technical boundaries and `git diff --check` passed. No unfiltered suite
  or real OS reboot was run.
- The final **176-step Mac Viewer recovery scenario passed in 134.616 seconds**,
  including offline restart, Host reconstruction with numeric-ID collisions,
  Files/drafts, detached ownership and terminal input. All six exact-PID App exits
  were normal (0.089–0.209 seconds). Evidence is in
  `.build-local/diagnostics/workspace-viewer-app-acceptance/attempt-11/`.
- Native **CtrlX Agent iOS** acceptance passed on an owned iPhone 18 Pro/iOS 27
  guest paired to an isolated signed Host. Automatic and manual Fit changed the
  intended window from 100x35 to 66x51 while the other stayed 100x35. Horizontal
  and vertical splits produced the expected three-pane layout; tapping each side
  changed the actual Host pane. Switching to OTHER selected its physical window
  and fitted it; returning preserved the original three panes.
- The existing 15-step manual Host companion was reused for this **non-input**
  check (286 seconds including observation waits); it did not repeat form-response
  acceptance. Evidence is in
  `.build-local/diagnostics/plugin-response-agent-ios/attempt-2/`:
  `noninput-checks.json`, native actions, inspected screenshots and source hashes.
  Host exit was normal in 0.159 seconds. Host/Relay/private tmux stopped and the
  owned guest was closed/deleted. No personal App was installed or replaced.
- This accepts these Fit/split/select paths. The broader audit still includes
  destructive/create/metadata/shared-layout operations and queued local CLI/
  LayoutDriver paths. Linked-window/display/performance and actual OS reboot
  acceptance remain open.

Plugin response identity follow-up (2026-10-16):

- Structured Viewer submissions carry the original pane binding through the
  existing workspace-input capability; older Hosts retain the optional-field
  compatibility path. iOS notification actions wait for a usable first snapshot
  after connection instead of submitting before the target can be bound.
- `PluginResponseContext` carries physical pane, plugin, native conversation and
  open request identity through native core calls. The sidecar adapter retains
  it until the ordered RPC response; same-pane concurrent deliveries are rejected.
  Text/key sinks recheck the context and use the actual tmux identity guard at
  mutation. Live pane moves remain valid. A response timeout retires the sidecar
  stream and child; re-enable the plugin to reconnect. Sidecars must emit related
  notifications before acknowledging `deliver_response` (documented contract).
- `.build-local/workspace-plugin-response-final-tests.log` passed the initial
  response/context/wire/service/native-core regressions. After the timeout-child
  cleanup and notification readiness adjustment, the focused final run
  `.build-local/workspace-plugin-response-verified-tests.log` passed **25 tests in
  7 suites**, including ordered sidecar notification scope, original binding over
  encrypted transport, and a suspended native plugin write rejected by real tmux
  after reconstruction while a fresh response succeeds. UIKit notification-action
  execution is not covered by the macOS package tests.
- The additional `.build-local/workspace-plugin-response-timeout-tests.log`
  passed **15 tests in 3 suites** (33.934 seconds), exercising the real 30-second
  sidecar deadline: late input and a subsequent response cannot use the retired
  stream. The native context and private-tmux reconstruction tests also passed.
- Mac and iOS Simulator Debug builds passed. Formatting comparison in
  `.build-local/workspace-plugin-response-format.json` shows no added diagnostics
  over HEAD; the new real-tmux test file is formatted. Brand/technical boundaries
  and `git diff --check` passed. No unfiltered suite was run.
- Native **CtrlX Agent iOS** acceptance passed on an owned iPhone 18 Pro/iOS 27
  guest, with a fresh encrypted pairing to an isolated signed Host/Relay and a
  private `cat` pane. Both built-in Echo and the real Echo sidecar delivered
  deny-with-feedback text and Accept keys. Captured output was exactly
  `NATIVE_RESPONSE_MARKER1SIDECAR_RESPONSE_MARKER1`; saved drafts remained visible.
  The **15-step manual Host companion** passed (406 seconds including setup and
  manual observation waits). This verifies valid form delivery; reconstruction
  rejection is covered separately by the real-tmux/encrypted tests above.
- Evidence: `.build-local/diagnostics/plugin-response-agent-ios/attempt-1/`
  (`checks.json`, terminal captures, `actions.jsonl`, source checksums and inspected
  screenshots). Agent iOS initially refused memory pressure; startup succeeded
  after builds finished. Terminal AX traversal returned partial trees / timed out,
  so subsequent coordinate input used freshly captured and inspected screenshots.
  No timed-out write was retried. The Host exited normally in **0.243 seconds**;
  Host/Relay/private tmux/sidecar stopped, and the owned guest was closed/deleted.
- This closes the response-delivery follow-up for conforming native/ordered
  sidecar paths, not the broader endpoint audit. Non-input commands and local
  queued actions remain, as do linked-window/display/performance and actual OS
  reboot acceptance. Native HID Return and notification-action execution were
  not retested by this form scenario.

Files source-read follow-up (2026-10-16):

- Source-directory (`list` without a path) and repository-link reads now capture
  the original local/Viewer pane identity. The existing identity capability binds
  those requests; old Hosts retain their compatibility path. Explicit Host paths
  remain usable independently of the terminal.
- Host directory queries check the actual tmux server/pane in the same command
  queue as the read. After filesystem work, another check rejects a restarted
  server even when published metadata is still stale. Repository context checks
  remain in place. Viewers reject retired sources before sending and late replies
  after reconstruction; live pane moves remain valid.
- `.build-local/workspace-files-source-tests.log`: **25 tests in 6 suites passed**,
  including real private-tmux reconstruction during suspended reads, unchanged
  cached identities, fresh sources/live moves, explicit paths, encrypted delayed
  replies for all three source-bound operations, and existing legacy behavior.
  Both Mac/iOS Simulator Debug builds and strict/deep signature checks passed;
  build logs use the same `workspace-files-source-` prefix. Formatting comparison
  (`workspace-files-source-format.json`) has no added diagnostics. Brand/technical
  boundaries and `git diff --check` passed. No unfiltered suite was run.
- Native **CtrlX Agent iOS** reran the isolated iPhone 18 Pro/iOS 27 acceptance
  with these builds. All **32 Host companion steps** and journal/UI checks passed:
  ordinary restart, offline launch, Host reconstruction with numeric collisions,
  Files preview and draft/copy restoration, and another iOS restart. After Host
  reconstruction, **Source Pane Directory** opened the correct rebuilt source;
  returning to its file preview preserved the original private record.
- Evidence, observed AX snapshots, inspected screenshots and source checksums:
  `.build-local/diagnostics/workspace-ios-app-acceptance/agent-ios-2/`.
  The three Host exits were verified against exact-PID launchd records; the
  isolated Host/Relay stopped and the owned simulator was closed/deleted.
  This accepts the Files source-read follow-up. Plugin form delivery, non-input
  commands, linked-window/display/performance and real OS reboot gates remain;
  the earlier optional native HID Return issue was not retested in this run.

Files-open identity follow-up (2026-10-16):

- Local Mac, Mac Viewer and iOS capture the source identity before path resolution
  or queued open work. The existing workspace identity capability now also carries
  `expectedWorkspacePane` for Files opens. The Host validates fresh source metadata
  before lookup/insertion, and rejects a suspended query superseded by published
  routes. Viewers reject old bindings and late replies before adopting a tab,
  including after the catalog refresh await.
- Host Files keep their source incarnation/persistent pane identity independently
  of numeric routing. A live move keeps the Files UUID; a replacement process
  cannot inherit it. Only explicit recovery remapping binds saved Files UUIDs to
  a reconstructed server. Legacy peers retain their existing path.
- `.build-local/workspace-files-identity-tests.log`: **27 tests in 5 suites passed**,
  including real encrypted transport with a held Files-open response, rejection
  before transmission after a delayed file-link lookup, same-server pane reuse,
  server restart, unpublished replacement routes, normal moves, explicit recovery,
  old capabilities and existing iOS recovery models.
- Mac and iOS Simulator Debug builds passed in
  `.build-local/workspace-files-identity-{macos,ios}-build.log`; the Mac App passed
  strict/deep signature verification. These compile checks do not replace the
  Agent iOS runtime evidence below.
- Seven focused files pass SwiftFormat. The three larger UI/coordinator files
  retain exactly their HEAD `wrapAttributes` warnings; comparison is recorded in
  `.build-local/workspace-files-identity-format.json`. Brand/technical boundaries
  and `git diff --check` passed. No unfiltered/Apple Intelligence suite was run.
- This closes the Files **open/catalog** gap, not every Files operation. Still
  audit source-directory/repository reads, plugin form delivery and non-input
  actions through their awaits and final targets. Ordinary absolute-path reads
  should not be coupled to unrelated terminal lifetime changes.

Local content acceptance follow-up (2026-10-16):

- `workspace-content-acceptance/attempt-5` passed initial Files open and ordinary
  restart, then failed step 76 after Host reconstruction: the draft and Files
  records were intact, but the UI selected OTHER while its saved private selection
  named CONTENT. The journal's tmux active window legitimately differed from the
  UI selection (quit immediately after a queued tab switch).
- The fixture now forces that divergence and checks external tmux navigation as
  well. Filtering ordinary pane metadata refreshes alone did **not** resolve it:
  attempt 6 failed the same UI check at step 82 of 143. The 58 focused model tests
  and Mac build passed; they do not establish a fixed runtime result.
- Both failed runs exited normally: attempt 5 has three exact-PID launchd exits
  in 0.114–0.546 seconds; attempt 6 in 0.108–0.485 seconds. Their retained journals,
  screenshots and `quit-audit` records are under
  `.build-local/diagnostics/workspace-content-acceptance/`. The runner's later
  force-kill warning does not explain this selection failure.
- Attempt 8's temporary trace identified the second path: after applying CONTENT,
  SwiftUI List echoed the same sidebar selection into its binding, invoking
  session navigation and selecting tmux-active OTHER. The binding now ignores
  equal selections. Pane refreshes follow only actual active-window changes,
  preserving restored/optimistic selection during unrelated metadata updates.
  Temporary tracing was removed before the final build.
- `.build-local/workspace-recovery-selection-refresh-tests.log`: **59 tests in
  4 suites passed**. The final Mac build and strict/deep signature verification
  passed. The E2E fixture now deterministically keeps the saved UI selection
  different from tmux's active window, changes a background window's title, then
  switches tmux windows externally and verifies both directions.
- **Attempt 9 passed all 149 steps in 116.699 seconds**, including original Files
  open, ordinary App restart, Host reconstruction with numeric collisions, draft
  display/copy, Files selection/expanded folders/preview, Git history/stash/message,
  and missing-file/return behavior. No saved prompt or command was replayed.
  Its five exact-PID launchd exits were normal, in 0.093–0.440 seconds. Evidence,
  screenshots, source hashes and exit audit are retained in
  `.build-local/diagnostics/workspace-content-acceptance/attempt-9/`.
  This accepts the new local content/selection case; it does not close the broader
  endpoint audit, linked-window/missing-display/performance or real OS reboot gates.

Native Agent signed-App composition is now verified by the 97-step scenario in
[Stage 3](STAGE3_TODO.md), including four configuration roots and App exit while
identity reconciliation is pending. This completes that part of the Mac
acceptance gate above; it does not cover Viewer/iOS, physical display removal,
linked-window presentation, performance or a real OS reboot.

Mac Viewer implementation and evidence (2026-10-16, source baseline `53bb8f2`
plus uncommitted changes):

- The App-owned journal now includes Viewer scenes, window geometry, stable
  session/window references, private Files navigation/scroll offsets and editor
  text. A fresh Host catalog remaps runtime routes before restoring ownership;
  the main workbench continues to use the Host's shared terminal placement.
- Offline edits remain capturable through the last verified presentation
  catalog. Closing a detached native window returns its live and not-yet-restored
  tabs to main; late Host Files/windows retain their relative tab positions.
  Explicitly closed restored tabs are not recreated by later state snapshots.
- A failed/missing local tmux does not stop Viewer checkpoints. Those writes
  project only Viewer scenes and remote drafts into the journal and preserve
  the local recovery source, local drafts and recovery intent. An unreadable
  source is still never replaced. Unchanged checkpoints do not write again.
- Remote editor text is keyed by pairing plus live editor UUID; the persisted
  draft has its own ID and stable pane reference, without the old editor request
  or temp path. Same-incarnation reconnect keeps edits. Late submit responses
  cannot clear newer text, and stale editor snapshots cannot recreate a cleared
  draft. Host replacement isolates old text; unpair removes only that Host.
- Sidebar, keyboard and menu-bar session selections deliberately bind to the
  selected live Host. Automatic rename detection now requires matching Host
  scope and persistent identities when present; recycled numeric routes do not
  migrate a private workspace into another session. Legacy rename behavior stays
  covered by the existing tests.
- `.build-local/workspace-viewer-tests.log`: **74 tests passed in 9 suites**,
  including model/store round trips and malformed records, partial discovery,
  offline window close, shared-layout precedence, editor races, independent
  Viewer checkpoints, and existing native-window/remote-browser rename tests.
- `.build-local/workspace-viewer-macos-build.log`: affected Mac workspace Debug
  build succeeded after the final source changes. Native browser and simulator
  preparation ran first. This is compilation, not signed-App recovery runtime
  acceptance or a real reboot.

Mac Viewer delayed selection follow-up (2026-10-16):

- Pending terminal/Files selections now survive automatic fallback selections
  and focus changes during partial discovery. A late selected terminal issues
  one native-window selection update; a late private Files tab restores its
  side and selection. Main-window terminal selection still follows the Host's
  shared layout.
- Per-window and per-session user-selection revisions distinguish explicit
  navigation from automatic repair. Sidebar/menu/keyboard/tab actions and the
  existing content-click observer cancel the corresponding pending selection,
  including a click on the already-selected fallback. Restoring a background
  session does not select it after the user has navigated elsewhere.
- A choice made before the first Host catalog is retained, including its live
  private tab objects. Late tabs still restore ownership and relative order.
  Session rename migrates the interaction revision; a new Host incarnation
  remaps the latest captured choice instead of replaying an older choice.
- `.build-local/workspace-viewer-selection-before.log` reproduces both missing
  late-terminal selection and a late right Files selection displaced by an
  automatic terminal fallback. `.build-local/workspace-viewer-focus-before.log`
  separately reproduces a pending left terminal losing its saved focus side.
- `.build-local/workspace-viewer-selection-regression.log`: **132 tests passed**
  (125 in 12 Mac suites, plus 7 iOS recovery model tests on the package host).
  Includes automatic fallback versus explicit terminal/Files/browser choice,
  early navigation before the first Host catalog, session rename, focus-side
  restoration, native content-click scope and shared Host layout precedence,
  alongside the existing controller/tmux/native-window recovery regressions.
- `.build-local/workspace-viewer-selection-host-restart.log`: the subsequent
  **17-test Viewer suite passed**, adding a known Host-incarnation change after
  an explicit choice. The fresh runtime IDs map to that latest choice while the
  other restored terminal and Files tab retain their ownership.
- `.build-local/workspace-viewer-selection-macos-build.log`: final production
  source passed the Mac workspace Debug build. The last follow-up added only a
  test. Five touched support/test Swift files pass SwiftFormat; the MainView
  comparison retains exactly the five existing `wrapAttributes` diagnostics
  from `HEAD` (`.build-local/workspace-viewer-selection-format.json`). Both
  brand/technical boundary checks and `git diff --check` passed. This follow-up
  did not run iOS UI or SDK builds, install an App or reboot the Mac.

The Mac Viewer signed-App result is recorded below. Delayed Files/form/non-input
commands still need endpoint review; presentation acceptance does not establish
correct behavior of every command endpoint or recovery after a real reboot.

Mac Viewer signed-App follow-up (2026-10-16):

- The restart scenario uses two signed Apps, a private tmux socket and an
  in-process local Relay. Opt-in `persistent-e2e-storage` preserves only the
  disposable installations' pairing keys/preferences under their explicit state
  roots, without UserDefaults or Keychain. The fixture enables auto-connect
  before either App starts; pairing itself goes through the real UI.
- `.build-local/workspace-viewer-fixture-tests.log`: **2 storage tests passed**,
  covering preference/key reconstruction, root isolation, removal, permissions,
  corrupt storage and the default in-memory path.
- The first runtime attempts exposed fixture errors (the local `scenes` field
  instead of `viewerScenes`, a no-op accessibility toggle and the local Files
  tab label on a remote tab). They are not passing recovery runs. Attempt 4
  established real offline/reconnected journals and the recovered-draft UI,
  but its Files click failed; its screenshot and journals also exposed a real
  defect: main Viewer terminal positions were dropped from the private tab order.
- Recovery now retains terminal positions relative to Files while still applying
  the Host's terminal split/selection. Late terminal discovery inserts missing
  tabs at their saved positions in the main window as well as detached windows.
  `.build-local/workspace-viewer-order-before.log` reproduces both complete and
  partial discovery failures. `.build-local/workspace-viewer-order-tests.log`:
  **60 tests passed in 3 suites**, including that regression, Viewer selection,
  layout mapping and detached-window ownership. The runtime scenario now checks
  native window frames and mixed terminal/Files order after every restart.
- Attempt 5 passed ordinary App restart, native frames/order, Files preview and
  draft-copy checks, then caught a second defect during Host reconstruction:
  the connection manager queued the workspace callback in another main-actor
  task after publishing the new Files catalog. A SwiftUI observer could route
  the new source window number through the old detached-window ownership and
  move the Files tab into that window before recovery captured it.
- Session-state callbacks now explicitly run on MainActor and reach the manager
  and Mac/iOS workspace stores synchronously. The focused callback-composition
  regression uses overlapping old/new runtime IDs and the real manager wiring;
  it reproduces wrong ownership in `.build-local/workspace-viewer-publication-before.log`.
  `.build-local/workspace-viewer-publication-tests.log`: **42 tests passed**
  (28 + 12 + 2 across the selected products), covering publication ordering,
  encrypted Files/reconnect behavior, Viewer recovery, iOS recovery models and
  Files stores, editor request guards and presentation wiring.

Mac Viewer offline and retired-Fit follow-up (2026-10-16):

- Attempt 6 retained Files ownership after Host reconstruction, but exposed a
  separate order loss: the tab strip persisted its temporarily empty terminal
  list during disconnect. Remote order, selection repair and right-pane pruning
  now wait for current Host state; offline checkpoints retain the last layout.
  `.build-local/workspace-viewer-offline-order-tests.log`: **48 tests passed in
  3 suites**. The final Mac build included the additional selection/split guards.
- Attempt 7 passed offline checkpoint, App restart and simulated Host rebuild
  journal checks, including window frames, mixed tab order and selection. Its
  subsequent draft UI check exposed an old Fit timeout alert over the restored
  terminal. Fit plans now capture the Host workspace scope; retired plans cannot
  start another resize, record a successful size or surface a stale error.
  Genuine current failures still leave failed/unattempted targets retryable.
- `.build-local/workspace-viewer-retired-fit-tests.log`: **15 tests passed in
  2 suites**, including success/failure after Host retirement and the existing
  local/remote split failure regression. The affected Mac workspace Debug build
  and strict deep signature verification passed.
- Attempt 8 passed recovered draft/Files UI after Host reconstruction, but its
  input fixture wrote the system clipboard while the test App read its isolated
  clipboard. The fixture now writes that instance's clipboard, as the existing
  local recovery scenario does; this was a test error, not automatic draft replay.
- **Attempt 9 passed all 176 steps in 118.367 seconds**. Evidence:
  `.build-local/diagnostics/workspace-viewer-app-acceptance/attempt-9/`.
  Checks cover real encrypted pairing/reconnect, offline launch and periodic
  offline checkpoint, live-process preservation, native window frames and
  ownership, mixed tab order/selection, private Files preview and expansion,
  saved draft UI/copy, Host reconstruction with reused numeric routes, input
  reaching only the rebuilt source pane, then another Viewer restart without
  recreating Host processes. Journals, screenshots and source checksums remain
  with that run. All **6 Apps exited normally**, launchd status `(0, 0, 0)`,
  **0.086–0.172 seconds** after quit; the driver again logged stale exit-status
  fallback warnings, which are disproved by the exact-PID audit.
- `.build-local/workspace-viewer-publication-ios-build.log`: updated iOS App
  Debug Simulator build succeeded, including synchronous state publication and
  the opt-in E2E storage entry point. The XCTest runner build also succeeded.
  Runtime iOS acceptance is still pending. MainView and focused new Swift files
  pass formatting; the two larger E2E support files have exactly the same
  diagnostics as HEAD (`workspace-recovery-e2e-format-comparison.json`).
  Brand/technical boundaries and `git diff --check` passed.

Remote editor endpoint evidence (2026-10-16):

- Submit/cancel carry optional `expectedSessionID`. The Host verifies the active
  editor and performs the file write/cancel without an intervening suspension.
  Both replacement and already-completed requests return failure. Older wire
  messages still decode and retain legacy active-pane targeting.
- The Mac overlay captures its original terminal binding. A changed known
  incarnation rejects delayed commands before transmission; Host-side request
  checks also reject an old request which was already sent. Submission failure
  is shown in the overlay and retains its text.
- File-write failure leaves the request and completion continuation available
  for retry. The continuation is registered before broadcasting editor state,
  so a fast response cannot arrive before its completion callback exists.
- `.build-local/workspace-editor-tests.log`: **18 tests passed** (14 + 2 + 2
  across selected products), covering actual temporary-file writes, replacement
  submit/cancel, failed-write retry, a suspended state broadcast, optional wire
  compatibility, encrypted delayed commands spanning a Host incarnation change,
  and the existing saved-draft race tests.
- `.build-local/workspace-editor-macos-build.log`: affected Mac workspace Debug
  build succeeded. `.build-local/workspace-editor-lint.log` and the baseline
  comparison JSON record formatting verification; no additional diagnostics in
  larger existing files. Brand/technical boundary checks and `git diff --check`
  passed. No signed-App editor recovery runtime or real reboot is claimed here.

Terminal stream subscription evidence (2026-10-16):

- Every returned stream frame can carry the Viewer subscription's optional lease.
  The Host stamps each recipient's frame synchronously before queue admission;
  snapshot metadata and all chunks retain the original lease across suspension.
  Initial/reset content, live bytes, titles, clipboard, notifications and end
  messages therefore cannot be admitted by a replacement subscription. The new
  optional capability makes modern Viewers reject missing leases; old Hosts and
  old payloads retain their compatibility path.
- Start requests capture the original Viewer pane binding. The Host verifies
  the expected server/persistent pane ID in the same ordered control-command
  batch as the snapshot, including resync captures for guarded subscriptions.
  A stale start cannot evict an active stream for a different known identity.
- Bootstrap boundaries/completions check their lease, and subscriber callbacks
  check the exact stream context. A removed subscription cannot feed a newly
  installed context through a recycled runtime pane ID. Discovery also ends
  guarded streams when the persistent identity changes, preserving a live pane
  moved between sessions/windows.
- `.build-local/workspace-stream-tests.log`: **48 tests passed** (44 + 3 + 1).
  Includes real private-tmux restart with reused pane IDs, guarded captures and
  a following control response, a stale start against a healthy real stream,
  suspended snapshot/bootstrap replacement, legacy wire compatibility, encrypted
  two-Viewer fan-out with distinct leases and ordered bytes, and queued start
  commands spanning a simulated Host restart.
- `.build-local/workspace-stream-macos-build.log` and
  `.build-local/workspace-stream-ios-build.log`: affected Mac and generic iOS
  Simulator Debug builds succeeded (iOS arm64 and x86_64). The subsequent Mac
  source edit only formatted the new lease guard; behavior was unchanged.
- `.build-local/workspace-stream-format-comparison.json`: 17 changed Swift files
  have no additional formatting diagnostics relative to HEAD. Brand/technical
  boundaries and `git diff --check` passed. Existing unrelated warnings remain.

Reader and control-connection follow-up (2026-10-16):

- Each new control connection captures its actual tmux server identity. Retired
  connections cannot publish output/dimension callbacks; a pane reader accepts
  only output from its own server. A same-server connection replacement triggers
  an ordered resync snapshot before output resumes.
- Fresh subscriptions query the pane's current session and server. Replacement
  no longer depends on capturing through an old session name. Reader lifecycle
  operations are serialized per pane; capture, output toggles and teardown stay
  pinned to the original server. Old snapshots cannot overwrite replacement
  reader dimensions/titles. `PaneInfo` preserves the server identity even before
  recovery UUIDs have been assigned.
- Each OSC reader owns a unique FIFO. Delayed stop cannot delete the replacement
  FIFO or detach its tmux pipe; queued callbacks identify the exact reader.
  Ordinary pane moves and session renames retain the existing physical identity.
- Local native terminal lifetime includes server/persistent pane identity, rather
  than only the runtime number. Teardown cancels bootstrap, rejects late UI
  callbacks and unsubscribes a result which finishes after cancellation.
- `.build-local/workspace-stream-lifetime-tests.log`: **103 tests passed in
  20 suites**. Real private-tmux cases include reused runtime IDs with/without
  recovery UUID guards, new session names before discovery, old snapshots, stale
  OSC callbacks/cleanup and FIFO ownership, native-view destruction before
  bootstrap, and same-server reconnect with rendered content compared to tmux.
  Existing control parsing, stream consistency, batching and identity tests ran
  in the same invocation.
- `.build-local/workspace-stream-lifetime-format-comparison.json`: 12 changed
  Swift files have no additional formatting diagnostics against HEAD. Brand and
  technical boundaries plus `git diff --check` passed.
- `.build-local/workspace-stream-lifetime-macos-build.log`: affected Mac workspace
  Debug build succeeded after the final source changes. This follow-up changes
  only Mac implementation/tests; the previous iOS build evidence remains
  applicable to the unchanged shared/iOS stream code.

The stream changes have focused runtime evidence in isolated tmux and native
view fixtures. They do not establish full signed-App recovery or a real OS
reboot. Files/form/non-input endpoints, local delayed commands and the final
composition/UI acceptance remain in scope.

iOS implementation and evidence (2026-10-16, same source baseline plus
uncommitted changes):

- The iOS scene loads a private atomic journal before connecting. Stable pairing,
  Host, session, window and pane identities restore navigation and selection;
  a new tmux incarnation recreates view/input lifetimes. Offline/partial catalogs
  preserve records, and explicit unpairing removes only that pairing's records.
- Files retain private paths, expansion and selected previews. Host-owned tabs
  wait for live Host descriptors; private tabs wait for their original source
  pane. Same-name session replacement and reused runtime pane numbers cannot
  inherit the old presentation. Closing a private tab removes its saved state.
- Reply, prompt, permission-feedback and Questions free text is saved separately
  from live forms. Recovered text has edit/copy/discard actions, without Send or
  old request IDs/approval choices. Reply submission on capable Hosts waits for
  the tmux result; rejection and later edits retain the draft. The existing
  plugin response channel confirms transport only, so its text is conservatively
  retained even after a submission attempt until the user discards it.
- `.build-local/workspace-recovery-ios-tests.log`: **50 tests passed**
  (4 + 1 + 39 + 6 across selected package products). Includes cold reconstruction,
  renamed sessions/new routes, delayed Host descriptors, partial pane discovery,
  identity collisions, offline/unpair behavior, draft submission races, failed
  writes/retry, corrupt/unknown journals, encrypted Host success/rejection and
  capability checks, plus existing Files/service/input regressions.
- `.build-local/workspace-recovery-ios-build.log`: final generic iOS Simulator
  Debug build succeeded for the affected UIKit/SwiftUI code. This is compilation,
  not runtime or real-reboot acceptance. Standard `--e2e-test` uses in-memory
  recovery unless an explicit `--ctrlx-state-root` supplies an isolated journal.
- `.build-local/workspace-recovery-ios-lint.log`: all 18 focused files passed
  SwiftFormat. Larger touched UI files and the existing transport test were
  compared against HEAD rather than reformatting pre-existing diagnostics.
  Brand/technical boundary checks and `git diff --check` passed.

Evidence (2026-10-15, source baseline `53bb8f2` plus uncommitted changes):

- `.build-local/workspace-recovery-input-tests.log`: **133 tests passed**
  (95 + 1 + 13 + 24 across the selected package products). Covers real private
  tmux restart with reused runtime/persistent IDs; rejected keys, raw bytes,
  paste and interrupt; control-mode rejection followed by a correctly associated
  response; encrypted queued input spanning a simulated Host incarnation change;
  old Host capabilities; pane metadata, catalog and layout revision behavior;
  existing paste, Questions, raw input and control-client regressions.
- The first real control-mode test caught that `if-shell -F` acknowledges itself
  before its one-command branch. The input path now waits for both responses,
  preventing false success and response misassociation. The rerun above passed.
- Brand/technical boundary checks and `git diff --check` passed. The eight new
  model/guard/test files passed SwiftFormat lint. Unrelated formatting in older
  terminal files was kept at its baseline. A later comparison of all 68 modified
  or new Swift files found no additional diagnostics relative to `HEAD`;
  `.build-local/workspace-recovery-format-comparison.json` records that result.

The input-path run alone does not establish client-private restoration or full
signed-App recovery. Later implementation evidence is recorded above. Release,
installation and a real reboot are not established by these runs; all remaining
acceptance gates stay in scope.


Native Agent iOS recovery acceptance (2026-10-16):

- The installed CtrlX Agent iOS controlled an owned, disposable iPhone 18 Pro
  guest on iOS 27. Simulator.app is absent on this machine. Device creation,
  installation, AX observation, taps, paste, screenshots and termination used
  the native `ctrlx ios` interface. `simctl` supplied the test-only launch
  arguments (unsupported by Agent iOS launch) and read the fixture clipboard.
  The generic XCTest headless-driver changes were removed; no alternate GUI
  automation stack was added.
- `Workspace Agent iOS Host` coordinates the isolated signed Host/local Relay
  with explicit checkpoint files; it is a manual scenario, excluded from the
  default unattended suite. The Host companion passed **32/32 steps**. Native
  observations/actions, journal assertions and inspected screenshots are in
  `.build-local/diagnostics/workspace-ios-app-acceptance/agent-ios-1/`.
- Real UI acceptance exposed an identity conversion defect: iOS selection uses
  `session:index`, while the recovery catalog routes by `@window`. The recording
  API now takes the actual `TmuxWindow` and resolves its stable ID; restoration
  maps the fresh route back to the UI window ID. The earlier fixture journal
  demonstrates the missing selection. The seven focused recovery tests now use
  actual grouped window models and verify restored UI IDs after rename/rebuild.
  `.build-local/workspace-ios-window-selection-tests.log`: **7 tests passed**.
  `.build-local/workspace-ios-window-selection-build.log`: updated generic iOS
  Simulator build succeeded; strict/deep signature verification passed.
- The final runtime checks pass encrypted pairing, cold iOS launch while Host
  offline, reconnect, unchanged live Host shell PIDs after an ordinary App
  restart, restored session/window/pane selection, private Files path and preview,
  recovered draft editing surface/copy, and no automatic draft replay. Simulated
  boot/tmux reconstruction reuses old runtime IDs for an unrelated session;
  that session inherits no Files or terminal selection. A subsequent iOS restart
  retains the rebuilt Host processes and restores the same presentation.
- Reinstalling the test build rotates its simulator data-container UUID. The
  runner updated the explicit test-root argument to the retained container;
  this was fixture setup, not lost production pairing data. Other fixture
  corrections wait for tmux reconstruction and permit the intentionally created
  collision session while comparing all original private records exactly.
- An additional explicit paste reached only rebuilt SOURCE, never OTHER or the
  reused-number collision. Native HID Return did not execute that pasted command,
  even after a content tap; this is recorded as **unresolved**, not a passing
  keyboard assertion. Isolate native HID versus ordinary UIKit input before
  claiming that optional hardware-key path. The navigation/Files/draft checks
  above and their journal assertions passed independently.
- Exact-PID launchd audit verifies all **3 Host Apps exited normally** within
  **0.078–0.112 seconds**; the driver's stale exit-status warnings were not actual
  forced terminations. The isolated Host/Relay stopped, and the disposable native
  guest was closed and deleted after verification. The earlier disposable standard
  Simulator was also removed. No physical iPhone install or OS reboot
  is established by this run.

- Final `CtrlxE2E` build passed after the manual-scenario selection and fixture
  corrections. Focused SwiftFormat checks passed; the four larger touched files
  match HEAD's formatting diagnostics exactly
  (`workspace-agent-ios-format-comparison.json`). Brand/technical boundaries,
  Python syntax and `git diff --check` passed. No unfiltered suite or Apple
  Intelligence evaluation was run for this follow-up.
