# Workspace recovery open validation

Current closeout (2026-10-16): implementation and bounded software acceptance are
delivered for review. The user chose “先交付审查”, deferring physical display
removal and separately authorized OS reboot, including real OS login launch.
These remain unverified follow-ups, not blockers to the requested review handoff.
Restore-mode/login service combinations passed isolated tests. Historical notes below
describe earlier scopes; the latest Stage 4 evidence supersedes their references
to pending CLI/LayoutDriver/editor work.

- The review P2 about reconstruction mutating reused tmux runtime IDs is fixed.
  Server and persistent target identities are checked in the mutation command
  queue; a changed identity stops recovery and preserves its saved source. Nine
  actual private-tmux interleavings and the 60-test recovery follow-up pass. See
  [Stage 1](STAGE1_TODO.md) for evidence; this is not new OS reboot acceptance.

- Recovery modes passed 38 focused tests and 80 signed-App steps. Native startup
  of two Codex and two Claude conversations completed with no new model requests;
  MainActor API p95 was 29.95 ms, maximum 793.29 ms. That transient maximum is
  retained explicitly; this is not frame-timing proof. See Stage 4 for conditions,
  screenshots, exact-history checks and the distinction from OS login/reboot.

- Signed-App linked-window acceptance now passes 60/60 steps: original native
  ownership/selection, live process survival, rebuilt physical window sharing
  and fresh output all verified. The existing UI deduplicates physical panes;
  this does not add a duplicate presentation for each tmux link. See Stage 4.

- CLI/LayoutDriver continuation guards pass 32 tests, including two reproduced
  writes to a replaced tmux server and ordinary nonzero-index layout behavior.
  Editor lifetime fixes pass the 115-test follow-up and 14-test final rerun.
  The signed-App scenario passes 33/33 steps, including normal CLI operations,
  refused stale input/editor submission, correctly retained drafts and successful
  fresh requests. See [Stage 4](STAGE4_TODO.md) for evidence and limits.
- New-session replies now retain the original Host state root/tmux incarnation;
  Mac/iOS selection and delayed Fit require matching live metadata. Fifty tests,
  both platform builds, the 74-step signed Mac scenario and native Agent iOS
  creation/selection/Fit acceptance passed. See [Stage 4](STAGE4_TODO.md).
  Queued local CLI/LayoutDriver actions remain under audit.
- Fork now keeps the captured source through preparation, worktree creation,
  retries, transport and result selection. The 53-test focused run, both builds,
  141-step signed Mac local/remote scenario and native Agent iOS acceptance
  passed. Native runtime exposed a failed history lookup cached indefinitely;
  only successes are now cached, and a later checkpoint retries missing history.
  The 45-test follow-up and deterministic missing/reappearing-history App check
  passed. See [Stage 4](STAGE4_TODO.md) for inspected evidence and cleanup.
  Queued CLI/LayoutDriver actions remain under audit.
- New-window terminal/Agent actions retain session identity through preparation,
  transport, creation and UI selection. Physical post-creation naming/startup
  rejects a replacement tmux server. iOS keeps the binding through delayed Fit.
  Distinct focused coverage is 53 tests in 10 suites; Mac/iOS builds and signing,
  78-step signed Mac local/remote creation and native Agent iOS creation passed.
  Native iOS created two usable, fitted windows with the original process intact.
  See [Stage 4](STAGE4_TODO.md) for failure evidence, source-impact review and
  cleanup. Queued CLI/LayoutDriver actions remain.
- Reorder/shared-layout commands now retain their session identity through
  debounce, transport, tmux swaps and partial-failure rollback. Old operations
  cannot adopt a reconstructed session; a surviving original session still rolls
  back after failure. The focused 33-test run, both platform builds and 84-step
  signed Mac local/remote layout scenario passed. See [Stage 4](STAGE4_TODO.md).
  New-window follow-up is recorded above; Fork and queued continuations remain.
- Session metadata mutations now keep the originating session through pending
  editors, iOS More actions and Viewer transport. Actual tmux option reads/writes
  and cached metadata/state updates reject replaced targets. The 46-test focused
  run, Mac/iOS builds and 159-step local/remote Mac UI scenario passed. The first
  Mac attempt failed on a wrong fixture menu label, not a product regression.
  Native Agent iOS metadata interaction also passed after the installed CtrlX
  was started and reclaimable memory recovered above the unchanged boot reserve.
  Stale More/editor actions were rejected; fresh edits persisted with the same
  terminal process. No production focus changes were needed for these tests.
  See [Stage 4](STAGE4_TODO.md) for retained evidence and scope.
- Real OS reboot acceptance requires an authorized test environment; implementation
  and isolated tmux restart tests can proceed without rebooting the user's Mac.
- The signed Mac App now passes the basic 69-step local recovery scenario
  (live-tmux App restart, simulated boot change, nested panes, split/detached
  ownership, shell directories and no interrupted-command replay). A main-window
  frame application race was fixed. Further runs exposed transient empty cwd
  metadata during shell startup; bounded rereads now preserve strict snapshot
  validation, and internal editor probes are excluded from recovery capture.
  The 164-test follow-up passed. Disabling competing system scene restoration
  while CtrlX recovery is enabled closes the remaining frame overwrite; the final
  69-step scenario passed three consecutive runs. This accepts the fixture's local
  lifecycle/geometry/process checks, not every restored UI or remote workflow. See
  [Stage 2 evidence](STAGE2_TODO.md) for reproduction and remaining coverage.
  A later terminal-buffer/input check exposed a separate main-window Fit gate:
  recovered layouts skip folder-template seeding, so they must independently
  qualify for Fit. Local and Viewer readiness now include that restored state.
  The 67-test follow-up and final 174-step signed-App run passed, with visible
  output and pane-targeted input in the main and detached windows. AppKit tests
  cover off-screen/oversized saved frames; physical display removal remains open.
- Missing-directory recovery now retains complete stopped session/window/pane
  positions and supports individual and workspace-wide retry. Fifty focused
  tests and the expanded 316-step signed-App scenario passed, including restart
  while pending and input after recovery. The UI banner overlap and dropped Retry
  clicks during capture were fixed. The runner's exit-status warnings were audited
  against launchd: all seven Apps exited normally within 0.455 seconds, before its
  fallback. See the latest [Stage 2 evidence](STAGE2_TODO.md); other structure
  errors and the remaining composition/runtime acceptance are still open.
- Codex 0.162.1 and Claude Code 2.1.276 passed the isolated native idle/interrupted/
  pending-approval matrix. Other versions remain explicit-only; see
  [Stage 3 evidence](STAGE3_TODO.md).
- Current folder layout storage and Host Files identity are not sufficient for
  reboot recovery. New recovery identity must take precedence without changing
  folder defaults for newly created sessions.

- Native launch/reconciliation now passes a 97-step signed-App scenario with
  four real conversations/configuration roots, split/detached panes and App
  termination while a native resume awaits its real identity event. PID/launch
  records remain stable and reconciliation finishes without repeated resume.
  A discovered Codex correlation-store isolation defect is fixed and covered by
  the 215-test follow-up. See [Stage 3](STAGE3_TODO.md); remote clients, arbitrary
  startup hooks, perceived startup performance and real OS reboot remain separate
  acceptance items.
- Local prompt drafts are now restored as editable/copyable text. Optional Host
  UUID wire mappings and input identity guards pass the focused compatibility,
  private-tmux and encrypted transport tests in [Stage 4](STAGE4_TODO.md).
  Mac Viewer drafts and native-window ownership now have pairing-scoped
  persistence and catalog-based route remapping; see the focused tests and Mac
  build in [Stage 4](STAGE4_TODO.md). Delayed terminal/Files selection and focus
  restoration now distinguish automatic fallback from explicit user navigation;
  model and native click-routing tests cover the interleaving. The final
  **176-step signed-App Viewer scenario passed**, after fixing mixed tab ordering,
  Files publication/ownership races, offline layout pruning and retired Fit
  errors. Stage 4 records real encrypted reconnect, private content, stable
  ownership, correct input after Host reconstruction and normal App exits.
  This completes Viewer presentation acceptance; remaining endpoint audits,
  real OS reboot and endpoint audits are separate gates.
- iOS private recovery now passes native Agent iOS runtime acceptance for
  navigation, Files preview, saved drafts, offline relaunch and Host reconstruction
  with reused numeric IDs. The run found and fixed a UI/catalog window-ID mismatch;
  seven focused tests and the updated iOS build passed. See [Stage 4](STAGE4_TODO.md).
  An optional native HID Return check remains unresolved: paste reached only the
  correct rebuilt pane, but Return did not execute it, including after a content
  tap. Isolate native automation versus ordinary UIKit keyboard input separately.
  Plugin form delivery has no native success acknowledgement; preserve submitted
  free text as a saved draft rather than deleting it on a successful socket write.
- Private view recreation and input binding guards are not sufficient proof for
  delayed Files/form/non-input requests. Audit their Host-side targets as part of
  the remaining remote restoration work before claiming full recovery safety.
  Remote editor submit/cancel now carry the expected live request UUID and reject
  replaced/ended requests on the Host. The original Viewer terminal binding is
  also checked before sending. File writes acknowledge only success; failed writes
  preserve the live request. This closes the editor-specific gap, not the remaining
  Files, form and non-input endpoint audit. Stream requests/frames now have
  guarded captures and per-lease delivery, with real tmux and encrypted transport
  regressions in Stage 4. Reader/control-client server isolation, fresh session
  routing, OSC ownership and local bootstrap cancellation now pass the 103-test
  follow-up there. Remaining command/form/Files endpoint guards and signed-App
  composition still need acceptance; this includes queued local actions.
- Files opens now retain their original source identity on local Mac, Mac Viewer
  and iOS. Host catalog reuse, suspended source queries and delayed Viewer replies
  reject replaced panes; explicit recovery remapping preserves valid saved UUIDs.
  The 27-test follow-up and both platform builds passed (Stage 4). Source-directory
  and repository reads subsequently gained guarded tmux reads and Viewer binding
  checks: 25 focused tests, both builds and the repeated Agent iOS recovery scenario
  passed, including Source Pane Directory after reconstruction (Stage 4).
  Form responses now retain physical pane/plugin/conversation/request identity
  through native core and ordered sidecar delivery to the final guarded tmux
  writes. Focused regressions reject a suspended response after reconstruction;
  native Agent iOS confirmed valid text/key replies through both Echo paths.
  Stage 4 records builds, terminal output and cleanup evidence. Fit/split/select
  now retain original window/pane identity through queued UI work and guarded
  tmux mutations. The 29-test follow-up, both builds, final 176-step Mac Viewer
  recovery and native Agent iOS Fit/split/select checks passed. Close confirmation
  follow-up is recorded below. The broader non-input audit still includes
  create/metadata/shared-layout and queued local CLI/LayoutDriver operations.
- The local content selection mismatch found in attempts 5–8 is fixed: equal
  sidebar selection echoes no longer trigger session navigation, and unrelated
  metadata updates no longer override a restored tab. The final 149-step signed
  App scenario passes a deterministic UI/tmux selection divergence, metadata
  refresh and actual external tmux navigation, plus Files/Git/draft restoration.
  All five App exits were normal. See Stage 4; the broader remaining gates above
  are unchanged.
- Git selection APIs, including commit/Stash selection, are public in the pinned
  GitWorkbench's `public extension`. The earlier internal-access diagnosis was
  incorrect. Git preview/draft components pass disposable repository tests, and
  the isolated signed-App content scenario now verifies Files, Git History/Stash
  previews and prompt drafts through App restart and simulated tmux reconstruction.
  Missing-file recovery also retains its selection and succeeds after the file is
  returned. See Stage 2 for the 131-step result and Stage 3 for native Agent
  acceptance; Viewer/iOS and real reboot composition remain open.
- Linked tmux windows now restore as one physical window with per-session links;
  capture, partial snapshots and Agent targets retain that shared identity. The
  78-test follow-up in [Stage 1](STAGE1_TODO.md) covers real tmux links, partial
  retries and explicit closure semantics. The subsequent 93-test follow-up fixes
  and verifies close/checkpoint/restore/shutdown interleaving, with persistent
  identity guards and an actual service/controller/private-tmux composition test.
  Signed-App linked-window ownership/presentation still needs acceptance.
  Close dialogs now capture their original identities before process queries;
  the 32-test follow-up, both builds and native Agent iOS session/window checks
  pass (Stage 4). The corrected 145-step signed Mac Host/Viewer close scenario
  also passes, with verified process preservation, fresh closes and normal exits.
  Initial identity readiness is covered below; the broader endpoint audit remains.

- Identity readiness now belongs to ordinary tmux discovery as well as recovery
  capture. Disabled recovery and corrupt journals no longer strand new terminals
  without UUIDs; concurrent assignment only fills empty options on the observed
  server. Local close requires the discovered identity. The 103-test follow-up
  covers both failures, linked sessions, repeated discovery and a restarted server
  between capture and assignment. The signed Mac Host/Viewer **153-step** scenario
  passed with recovery off: old confirmations preserved the original processes,
  fresh closes succeeded, and the saved journal stayed byte-for-byte unchanged.
  See [Stage 4](STAGE4_TODO.md). This does not complete the remaining create,
  metadata/shared-layout and queued local CLI/LayoutDriver endpoint audit.

- Resume batches now prioritize saved visible windows and selected panes. Verify
  perceived startup order and responsiveness in signed-App acceptance.

- Delayed Yolo/MarkHandled requests now retain their original pane binding and
  the Host checks it before changing state. The 39-test follow-up, both platform
  builds and native Agent iOS attention/Yolo acceptance passed (Stage 4). Stale
  transport and Host mutation rejection are covered by regressions; native
  acceptance verifies the fresh UI path and targeted approval output. Create,
  rename, session metadata/shared-layout and queued local CLI/LayoutDriver work
  remain in the broader endpoint audit.

- Window-name editors now retain the original window binding across discovery
  updates and queued sends; final tmux writes reject replaced windows or servers.
  The 16-test follow-up, both builds, 140-step signed Mac Host/Viewer scenario
  and native Agent iOS stale/fresh editor checks passed (Stage 4). Failed Mac
  attempts exposed uncommitted IME text in the fixture; paste input and direct
  tmux-name assertions resolved the test failure without an extra UI workaround.
  Session rename, metadata/create/shared-layout and queued CLI/LayoutDriver
  actions remain under audit.

- Session-name editors now retain their original binding, and final tmux rename
  checks the server/session identity after its asynchronous name lookup. Rename
  detection also rejects recycled runtime IDs with changed persistent identity.
  Native iOS acceptance exposed a publication race: discovery could broadcast
  the old MirrorWindowManager identity before the UI observer updated it. Host
  discovery now updates that model before publishing the snapshot. Focused
  regressions, both platform builds and native iOS stale/fresh session-editor
  acceptance passed (Stage 4). Mac session-editor acceptance subsequently passed
  **115 steps** for local Host and remote Viewer, preserving real tmux processes
  on both rejected and successful renames. Earlier focus traces were misleading:
  System Events resolved the foreground reference to another same-named CtrlX.
  The test driver now verifies the native focused AX process and prefers native
  context-menu actions. This follow-up changed test tooling, not product code;
  the failed attempts remain evidence of the old fixture problem. Session
  metadata/create/shared-layout and queued CLI/LayoutDriver work remain open.

- The 96-pane checkpoint measurement exposed a bulk identity-assignment failure:
  a single tmux command exceeded its message limit, stranding both ordinary
  discovery and recovery capture. Both now use batches of 16 guarded assignments.
  Real-tmux regressions cover large discovery/capture, an interrupted later batch,
  retry without overwriting assigned UUIDs, shared windows and unchanged process
  IDs. The 62-test focused run and signed Mac build passed; the 96-pane App now
  captures its workspace. Stage 2 records bounded checkpoint measurements and
  their limits; Agent-startup responsiveness and physical display removal remain
  separate acceptance items.
