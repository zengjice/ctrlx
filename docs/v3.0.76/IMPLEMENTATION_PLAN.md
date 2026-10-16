# Workspace recovery implementation

Source baseline: `53bb8f2` (3.0.75). Scope: [workspace recovery design](../workspace-recovery-design.md).
Status: delivered for review on 2026-10-16. After software acceptance, the user
chose “先交付审查”, explicitly deferring physical display removal and real OS
reboot/login acceptance for this delivery. These are unverified follow-ups,
not passing results. See the current closeout in [Stage 4](STAGE4_TODO.md).
This directory tracks implementation; it does not bump the release version.

## Review handoff

The implementation is delivered on `main`, based on `53bb8f2`, including the
accepted P2 reconstruction identity fix. The user authorized committing the
implementation, tests and documentation on 2026-10-16. Locally generated E2E
screenshots remain outside Git. No installed App was replaced and no release
was made.

- Durable snapshots capture tmux topology, directories and private presentation
  every two seconds, writing only changed content. Startup distinguishes a new
  OS boot from a surviving tmux server and an unexpected same-boot server loss.
  Start at `Services/WorkspaceRecovery/WorkspaceRecoveryController.swift`,
  `WorkspaceRecoveryStore.swift` and `WorkspaceTmuxClient.swift` under
  `CtrlxPackage/Sources/CtrlxServerFeature/`.
- Main/detached windows, split/tab selection, Files/Git state and unsent drafts
  recover through persistent object identities. Ordinary terminals return to
  shells; recorded commands, prompts and old approvals are not replayed.
  `Coordinators/AppCoordinator+WorkspaceRecovery.swift` wires these components.
- Codex/Claude resume exact conversation IDs and configuration roots. Durable
  launch records prevent duplicate recovery; unsupported/missing history has
  explicit Resume/Use Shell actions. General settings offers full recovery,
  layout/terminals only, or Off, independently of launch-at-login.
- Mac Viewer and iOS retain private presentation and reconnect using pairing,
  Host and persistent pane identity. Stream/input/editor/CLI continuations reject
  targets replaced during recovery. Shared models live in
  `CtrlxNetworking/Models/WorkspaceIdentity.swift`; iOS entry points include
  `CtrlxFeature/Models/IOSWorkspaceRecovery.swift` and the Files workspace store.

Validation is recorded per source scope in Stages 1–4. Final focused evidence
includes 38 mode/controller/Agent tests, 60 linked-window UI steps, 80 recovery-mode
UI steps, 33 CLI/editor UI steps and the prior 97-step native-Agent recovery run.
Mac and iOS builds passed. At the review handoff, 109 production files matched
the final signed-App source audit. The subsequent P2 fix changes tmux reconstruction;
its 60 focused tests (including nine identity interleavings), Mac build and strict
signature verification passed. See Stage 1 for that scope. Four-Agent startup
API response p95 was 29.95 ms and maximum 793.29 ms; these are transport-inclusive
MainActor observations, not frame-timing guarantees. No unfiltered full-suite or
Apple Intelligence evaluation pass is claimed.

## Stages

1. Durable snapshot, storage and tmux reconstruction: persistent object identities,
   boot/server distinction, exact pane layout, atomic saves with one backup,
   partial failure and idempotent recovery. [Stage 1](STAGE1_TODO.md).
2. App lifecycle and presentation: capture every observed session, main/detached
   windows, Files/Git, selection, splits and unsent drafts; restore on startup,
   flush before shutdown, preserve unavailable items and respect explicit deletion.
   [Stage 2 progress and evidence](STAGE2_TODO.md).
3. Native Agent resume and settings: optional plugin capability for Codex/Claude,
   exact conversation/configuration identity, three restore modes, per-item retry;
   no prompt/command replay or implicit enabling of disabled plugins.
   [Stage 3 progress and evidence](STAGE3_TODO.md).
4. Host/Viewer identity mapping and acceptance: Mac/iOS reconnect to rebuilt
   objects, backward-compatible wire behavior, isolated tmux and signed-app
   acceptance, then a separately authorized real system reboot test.
   [Stage 4 progress and evidence](STAGE4_TODO.md).

## Completion gates

All acceptance items in the design remain required unless explicitly deferred there.
The two hardware gates are now explicitly deferred by the user's review-first
decision above; they remain follow-ups before claiming full hardware acceptance.
Browser memory, simulator/debugger runtime and historical terminal output are excluded
by that design; core recovery must not be reduced to folder defaults or shell-only recovery.
Tests must cover successful recovery, preserved live processes, interrupted recovery,
missing directories/history, identity reuse, invalid snapshots and multiple sessions
in the same directory. A simulated tmux restart is not a real OS reboot result.

The user subsequently authorized the commit after the review fix. Installation
into the user's running App, release and reboot still require separate authorization.
Record actual evidence and remaining work here.
