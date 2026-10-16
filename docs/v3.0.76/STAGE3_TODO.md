# Stage 3 — native Agent recovery

- [x] Capture PID/start-instance proof, executable, configuration root and
  plugin-owned safe startup options; never persist raw argv/prompts or the environment.
- [x] Build exact-ID Codex/Claude resume commands independently of new-session Auto-run.
- [x] Write each launch intent before starting a process, then confirm the native
  conversation identity; a lost acknowledgement never directly resends resume.
- [x] Start only in an owned dead tmux placeholder. The tmux command queue checks
  server/pane identity, and `respawn-pane` without `-k` refuses a live process.
- [x] Provide per-Agent Resume / Use Shell and Keep terminal for existing processes.
  A pending dead pane has a recovery view instead of an input endpoint.
- [x] Gate automatic recovery on a verified CLI version and check that version
  again at launch. Unsupported options/configuration and other versions retain
  explicit recovery or a clear unavailable result.
- [x] Verify actual native idle, interrupted and pending-approval resume behavior
  using disposable roots, private tmux sockets and a local synthetic model endpoint.
- [x] Resume visible main/detached terminal windows before hidden tabs, ordering
  the focused side and selected pane first; ignore remote scene identities when
  scheduling local Agent processes.
- [x] Exercise process discovery, saved descriptors, native launch and subsequent
  identity reconciliation together in an isolated signed CtrlX App.
- [x] Verify multiple native conversations/configuration roots and multiple Agent
  panes in the signed-App recovery scenario, including App exit mid-recovery.

Evidence (2026-10-15, source baseline `53bb8f2` plus current uncommitted changes):

- `.build-local/workspace-recovery-stage3-tests.log`: 87 + 6 + 3 + 3 tests passed
  across the selected package products (99 total). Includes journal failures,
  uncertain launches, dead retries, disabled plugins, version changes, real tmux
  placeholder launch/quoting, shell fallback and the existing recovery regressions.
- `python3 scripts/verify-workspace-agent-resume.py --output .build-local/diagnostics/workspace-native-acceptance-1`
  completed successfully. All six combinations passed for **Codex 0.162.1** and
  **Claude Code 2.1.276**. Each exact-ID resume kept the original history, remained
  alive, made zero new POST requests to the synthetic provider during the eight
  second observation, and did not execute the old approval command. Reports and
  before/after terminal text are under that output directory. Each report names
  its disposable native history/configuration root under `/tmp`.
- Codex resumes use `--no-daemon` on the verified version so the restored TUI owns
  its process lifetime. Other versions are explicit-only until revalidated.
- `.build-local/workspace-recovery-process-tests.log`: three process provenance
  tests passed, including a real owned non-system process and stale PID-instance
  rejection. A protected system-process probe showed that macOS can omit the
  environment entirely; this now produces an unavailable result, never a guessed
  default configuration root.
- `.build-local/diagnostics/workspace-native-provenance-1/report.json`: both real
  native CLIs exposed the exact disposable configuration root through the same
  kernel interface, and both repeated idle-resume checks passed.
- Brand/technical boundary checks and Python syntax validation passed. Targeted
  SwiftFormat checks passed for recovery files; the unchanged TmuxService baseline
  has existing formatting diagnostics outside the recovery edits.
- `.build-local/workspace-recovery-git-priority-tests.log`: the later 86-test run
  includes native launch-order assertions for both visible split sides, selected
  panes, detached windows and hidden tabs. A remote scene does not reorder local
  launches. Git/presentation evidence is recorded in [Stage 2](STAGE2_TODO.md).

Signed-App composition follow-up (2026-10-16, same source baseline plus
uncommitted changes):

- `Workspace Agent Recovery` passed **97/97 steps** in
  `.build-local/diagnostics/workspace-agent-app-acceptance/attempt-5/`.
  Two Codex and two Claude Code conversations use four disposable configuration
  roots in the same project. Two Agents share a split tmux window; another
  occupies a detached native window. The App uses real plugin cores, process
  discovery, journal capture and native resume, with synthetic loopback replies.
- An App restart with live tmux preserved each process. Simulated boot/tmux
  reconstruction retained all four persistent pane/conversation identities and
  exact configuration roots while remapping runtime IDs. Native history files
  remained the same, terminal accessibility content contained the previous reply,
  and no new model requests were made. Another App restart did not repeat resume.
- A second reconstruction delayed one real Claude `SessionStart` hook after
  native `--resume` had started. The other three conversations reconciled while
  that pane kept its durable launch intent. Quitting and relaunching the App
  retained all four native process PIDs, the pending launch UUID and the original
  hook process. Releasing that same hook completed reconciliation without a
  replacement process, history file or model request. The fixture redirects only
  its own hook socket and delays delivery; it does not invent Agent identities.
- The runner's stale exit-status warnings were checked against launchd for all
  six App instances. Each exited normally in **0.117–0.449 seconds**, before the
  runner's fallback. `quit-audit.json` and the filtered system log record this;
  the fixture model servers and private tmux were stopped after the run.
- The first fixture exposed a pre-existing isolation defect: the default Codex
  core used the installed Host's legacy pane-correlation store even with a private
  plugin state directory. Non-default state directories now own their records;
  the installed Host retains its legacy path. Two real core instances with the
  same `%1` verify that one instance's exit monitor cannot remove the other's ID.
- `.build-local/workspace-agent-isolation-tests.log`: **215 tests in 15 suites
  passed**, including correlation, session-end, core and recovery tests.
  `.build-local/workspace-agent-isolation-macos-build.log`: the updated Mac
  workspace Debug build succeeded, and its deep/strict code signature verified.
- Five focused Swift files passed SwiftFormat lint; Python syntax, brand and
  technical boundary checks and `git diff --check` passed. The final scenario
  source checksums are recorded with its evidence. This turn did not change iOS
  code or rerun its SDK build.

These tests use real CLIs but synthetic model replies; they do not validate a
provider account, arbitrary user startup hooks, remote clients or a real system
reboot. Native startup hooks may still run as documented in the design. The full
recovery goal remains in progress.
