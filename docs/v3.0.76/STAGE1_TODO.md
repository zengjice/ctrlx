# Stage 1 — durable workspace and tmux reconstruction

- [x] Add a versioned snapshot with persistent session/window/pane identities.
- [x] Add serial atomic storage, previous complete snapshot and invalid-input protection.
- [x] Capture live tmux metadata without copying command lines, environments or terminal output.
- [x] Add startup policy for reboot, surviving tmux, unexpected tmux exit and disabled mode.
- [x] Wire explicit object closure and shutdown to the App lifecycle (stage 2; signed UI acceptance remains open).
- [x] Reconstruct shells, working directories, window order and nested pane proportions.
- [x] Keep failed/unavailable objects and resume interrupted tmux restoration without duplication.
- [x] Cover model/storage/decision paths and reconstruction on an isolated tmux socket.

Evidence (2026-10-15, worktree based on `53bb8f2`):
`./scripts/unit-tests.sh -- --no-parallel --filter 'WorkspaceRecoveryStoreTests|WorkspaceTmuxRecoveryTests|WorkspaceRecoveryPolicyTests'`
passed 9 tests in 3 suites. The tmux tests use their own `/tmp` socket and `/bin/sh`,
restore two same-directory sessions, sparse window indices and nested panes, compare
persistent identity/geometry/cwd/selection, and verify retries preserve process IDs.
They also cover an unavailable directory and an unrelated same-name session.

The services are now wired to the App in stage 2. No signed UI or real reboot acceptance is
claimed. Later stages and the full completion gates remain open in
[the implementation plan](IMPLEMENTATION_PLAN.md).

Large-workspace identity follow-up (2026-10-16):

- A signed-App performance fixture with 12 sessions, 48 windows and 96 panes
  exposed `tmux command failed: command too long` before the first checkpoint;
  discovery also failed and the sidebar was empty. The inspected screenshot
  and failed run are in `.build-local/diagnostics/workspace-recovery-performance/attempt-1/`.
- Both discovery and recovery capture combined every missing-identity assignment
  into one command message. They now share batches of at most 16 assignments,
  retaining each assignment's server and empty-option guard. This avoids the
  [tmux client message limit](https://github.com/tmux/tmux/blob/3.5a/client.c)
  without changing existing identities or publishing an invented snapshot.
- A real private-tmux regression with 40 sessions plus a linked session failed
  on both capture and discovery before the fix (`workspace-identity-batch-before-tests-2.log`).
  The first test compile used the wrong error-property name and is retained
  separately. The expanded regression also interrupts a later batch, verifies
  that retry preserves the identities already assigned, and checks stable
  process IDs and shared-window identity. The post-fix run passed **62 tests in
  4 suites** (`workspace-identity-batch-tests.log`), including storage, controller
  and simulator-pane publication regressions. Five focused Swift files add no
  formatting diagnostics; brand/technical boundaries and `git diff --check`
  passed. The Mac Debug build and strict/deep signature verification passed.
  Updated signed-App performance attempts 3 and 4 both captured the original
  96-pane workload and passed all 18 scenario steps. See Stage 2 for measurements
  and scope; the final source hashes and fixture cleanup were verified.

Linked-window and explicit-closure follow-up (2026-10-16):

- One physical tmux window shared by several sessions is recreated once and
  linked at each session's original index. Session selection/move commands name
  the session as well as the window, so restoring one link cannot select or move
  another session's link. A surviving complete window is linked without changing
  its processes, dimensions or layout.
- Shared snapshot records must agree on physical window/pane contents; only the
  per-session window index can differ. Partial checkpoints propagate completed
  live content to all links and retain one unresolved source for incomplete
  windows. Agent descriptors are captured once per pane and resume targets are
  deduplicated after applying visible-pane priority.
- Explicit closure now distinguishes session, window and pane. Removing one
  session preserves panes and pending Agent records still shared by another.
  Closing an incomplete session/window discards its uncreated children and old
  failure records too; those children cannot reappear after an App restart.
  Recovery completion also checks session/window membership, not only pane UUIDs.
- `.build-local/workspace-linked-window-tests.log`: **78 tests passed** (71 in
  10 Mac suites plus 7 iOS recovery model tests running in the package suite).
  Real private-tmux tests cover three shared-session links, sparse indices,
  independent selections, changed surviving geometry, repeated recovery with
  unchanged process IDs, and a missing directory which later becomes available.
  Store/controller/Agent tests cover conflicting identities, partial checkpoints,
  one resume target, shared-session closure, uncreated-child deletion and closure
  callbacks after successful versus failed tmux mutations.
- `.build-local/workspace-linked-window-lint.log`: nine changed recovery Swift
  files pass lint. The `workspace-linked-window-format/comparison.json` artifact
  records no additional diagnostics for `TmuxService.swift` relative to HEAD;
  existing formatting diagnostics are retained. Brand/technical boundary checks
  and `git diff --check` passed.
- `.build-local/workspace-linked-window-macos-build.log`: the Mac workspace
  Debug build succeeded after the final closure/controller changes. No shared
  wire or iOS implementation changed in this follow-up; no new iOS SDK build
  or iOS runtime acceptance is claimed.

This evidence does not cover signed-App presentation of linked windows or a
real OS reboot. Close/checkpoint interleaving is covered by the follow-up below.

Close transaction follow-up (2026-10-16):

- The initial suspended-capture reproduction failed twice: both the checkpoint
  and later shutdown retained the explicitly closed pane. Evidence is in
  `.build-local/workspace-closure-race-before.log`.
- The actual tmux close now participates in the recovery controller's serial
  transaction. It waits for capture, presentation, journal writes and Agent
  progress to finish before mutating; cancelled queued closes do not run later.
  Shutdown waits for an accepted close and rejects subsequent mutations.
- Closures use persistent session/window/pane UUIDs. A successful close is
  applied to the known snapshot before the next tmux read, so a read failure or
  shutdown cannot put that slot back. Unknown identities do not erase another
  saved object, and a failed mutation leaves the snapshot intact.
- The close request resolves its physical tmux target before entering the
  transaction queue. An `if-shell` guard checks the original server and known
  UUID in the same command queue as `kill-*`. It follows an original window
  whose index changed, rejects a replacement incarnation/identity, and obtains
  a newly assigned recovery UUID before closing a previously unmanaged object.
- `.build-local/workspace-closure-regression-tests.log`: **93 tests passed**
  (86 in 11 Mac suites plus 7 iOS recovery model tests in the package suite).
  Includes suspended capture/extras/write/restore/presentation/Agent callbacks,
  cancellation, shutdown, failed post-close reads, existing recovery regressions,
  actual private-tmux identity guards and one combined real `TmuxService` close
  + suspended controller capture + journal test. These are isolated fixtures,
  not signed-App UI or real reboot acceptance.
- `.build-local/workspace-closure-race-lint.log`: six changed Swift files pass
  lint; `workspace-closure-race-format/comparison.json` records no new
  `TmuxService.swift` diagnostics against HEAD. Brand/technical boundaries and
  `git diff --check` pass.
- `.build-local/workspace-closure-race-macos-build.log`: affected Mac workspace
  Debug build succeeded after the final source changes. No iOS/shared wire
  implementation changed in this follow-up; no new iOS SDK/runtime acceptance
  is claimed.

Requests queued earlier in a UI/remote-command handler, before entering the
close API, remain part of the broader endpoint audit in Stage 4. This follow-up
does not establish all local/remote command lifetime guarantees.

Restore target lifetime review fix (2026-10-16):

- Accepted the P2 finding that a server restart between capture and reconstruction
  could reuse runtime IDs and resize/split an unrelated window before verification.
  Reconstruction now checks the captured server identity and persistent target UUIDs
  inside the same synchronous tmux command queue as each mutation. Pane operations
  also check the owning window UUID; session-index operations check that window's
  identity. An identity change stops the entire restore pass.
- The restore pass retains its server identity across refreshes. The first session
  creation returns the actual server identity in its own command; later capture
  rejects a replacement server before assigning missing UUIDs.
- The initial six real private-tmux interleavings all failed before the fix
  (`.build-local/workspace-restore-identity-before-tests-2.log`). The final run
  passed **60 tests in 4 suites**, including nine interleavings covering snapshot,
  resize, split, layout and post-layout refresh, plus independent server/session/
  window/pane identity changes (`.build-local/workspace-restore-identity-tests-2.log`).
  Rejection preserves target dimensions, pane count, processes and UUIDs. Existing
  restoration, linked-window, partial retry, controller, Agent and store tests pass.
  The first post-fix run exposed only an auto-renamed shell in the same-name conflict
  fixture; assigning an explicit fixture window name removes that timing dependence.
- The affected Mac workspace Debug build passed
  (`.build-local/workspace-restore-identity-macos-build.log`). Both changed Swift
  files pass SwiftFormat; brand/technical boundaries and `git diff --check` pass.
  No new signed-App UI, iOS runtime or real OS reboot acceptance is claimed.
