# Viewer browser implementation

- [x] Native bounded capture/input and Agent handoff gate
- [x] Host page lifetime independent of workspace visibility
- [x] Typed wire model and capability gate
- [x] Host authorization, bounded request admission and disconnect cleanup
- [x] Mac Viewer tabs and controls (wired and compiled; physical UI acceptance below)
- [x] iOS Tabs and controls (wired and compiled; physical UI acceptance below)
- [x] Unit/compatibility tests and Mac/iOS builds
- [x] Isolated native remote acceptance and managed-engine regression
- [x] Update browser documentation and record remaining limitations
- [x] Review fixes: discard input on lease loss, forward Mac hover, reconcile removed Host tabs
- [ ] Complete expanded-capability regression (process-routing failure recorded in ISSUES)
- [ ] Physical Mac Viewer / iPhone touch, keyboard, IME and paste acceptance
- [ ] Throttled WAN terminal-latency measurement

## Evidence (2026-10-09)

- Mac Release compile: `/tmp/ctrlx-remote-browser-mac-complete.log`.
- iOS device-target Release compile: `/tmp/ctrlx-remote-browser-ios-final.log`.
- Native production library: `/tmp/ctrlx-remote-browser-native-final.log`.
- Focused tests: 87 passed, `/tmp/ctrlx-remote-browser-unit-verified.log`.
- Native remote acceptance: 7 checkpoints, including background nonblank capture,
  committed Chinese input, both engine gates, unfinished-drag release, fit and
  stale-control/geometry refusal. `/tmp/ctrlx-remote-browser-native-complete.log`.
- Managed-engine regression: 18 checkpoints.
  `/tmp/ctrlx-remote-browser-managed-regression2.log`.
- Expanded regression did not pass; see [`ISSUES.md`](ISSUES.md).
- Review-fix regression: 109 related tests passed,
  `/tmp/ctrlx-browser-review-fixes-tests.log`. Covers late success/error after
  lease loss and retake, Mac tracking/hover/letterboxing/drag release, and Host
  catalog removal with browser/terminal/file selection and split collapse.
  The 23-test `RemoteBrowser` subset also passed three consecutive reruns
  (`/tmp/ctrlx-browser-review-repeat-{1,2,3}.log`).
- Review-fix iOS device-target Release compile passed (unsigned, not installed):
  `/tmp/ctrlx-browser-review-fixes-ios.log`.

These native tests use isolated signed copies and Codex-named fixture processes.
They are not end-to-end physical Viewer UI tests or real Codex acceptance. No
production application was installed or published during validation. Re-test both
Host and Viewer with updated builds together; the opaque Relay needs no
browser-specific update.
