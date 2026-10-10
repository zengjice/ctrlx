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
- [x] Host capture flicker: remove CDP clip/scale, worker-side JPEG sizing and per-tab coalescing
- [x] Capture-coordinate review fix: include scrollbars in frame CSS dimensions and test screenshot-position clicks
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

## Capture-flicker regression (2026-10-10)

- Production native runtime and the CMake `remote_browser_frame_tests` target
  compiled. Image tests cover large raw sources (>512 KiB), output dimensions,
  aspect ratio, no upscaling, invalid/oversized input and the 180 KiB bound.
  Logs: `/tmp/ctrlx-browser-frame-build-final.log`,
  `/tmp/ctrlx-browser-frame-image-build.log`,
  `/tmp/ctrlx-browser-frame-image-tests.log`.
- Native remote acceptance: 11 checkpoints passed. The old clipped screenshot
  positively triggers transient descendant-view resize notifications; 12 new
  visible captures do not change native bounds, CSS dimensions, scroll or pixel
  ratio. Four simultaneous requests coalesce and keep identical frame state.
  Background nonblank capture, trusted Chinese text/click, wheel scroll,
  Tab/Shift+Tab, click/select-all/text after Fit, handoff and stale input refusal
  pass. Mean/max loopback capture: 103/121 ms, not WAN timing.
  `/tmp/ctrlx-browser-frame-native-tests.log`.
- Managed-engine regression: 18 checkpoints passed;
  `/tmp/ctrlx-browser-frame-managed-tests.log`.
- 23 related Swift tests passed with `--skip-build --no-parallel` (Swift sources
  are unchanged); `/tmp/ctrlx-browser-frame-swift-tests.log`.
- Brand/technical checks and Python syntax validation passed. Both successful
  isolated Hosts stopped normally; the failed monitor fixture's private tmux
  server was cleaned up. No installed app, personal profile or live session was
  changed. Physical iPhone/Mac Viewer and throttled WAN acceptance remain above.

## Scrollbar-coordinate regression (2026-10-10)

- The new screenshot-position test fails against the previous capture runtime:
  a 700×829 viewport returns 684×813, maps the pictured target to x≈637 and
  misses. `/tmp/ctrlx-browser-scrollbar-red.log`.
- Full screenshot dimensions now convert to CSS using the paired CDP
  physical/CSS viewport ratio and pinch scale; scrollbars are included before
  thumbnail downscaling. No CDP clip, surface resize or Viewer change is added.
- Native acceptance passes 15 checkpoints, including screenshot-derived clicks
  with both non-overlay scrollbars at 700×829, browser zoom 1.5, pinch zoom 1.5
  and Fit to 390×700. Existing no-flicker capture, coalescing, input, handoff and
  stale-input tests still pass. `/tmp/ctrlx-browser-scrollbar-native-tests.log`.
- Image unit tests cover full-image CSS dimensions at 1×/2×/3× scale and invalid
  ratios, alongside existing image/size limits.
  `/tmp/ctrlx-browser-scrollbar-image-tests.log`.
- Production native build/signing and 23 cached related Swift tests pass:
  `/tmp/ctrlx-browser-scrollbar-native-build.log`,
  `/tmp/ctrlx-browser-scrollbar-swift-tests.log`.
- Managed-engine regression passes 18 checkpoints;
  `/tmp/ctrlx-browser-scrollbar-managed-tests.log`. Python syntax, diff whitespace,
  brand/technical boundary and native signature checks also pass.
- These are isolated fixture checks, not physical iPhone/Mac Viewer acceptance.
  The installed app and Relay are unchanged.
- Mac 3.0.55 release preflight: 2,587 cached serial Swift tests pass (two
  unavailable Apple Intelligence evaluations excluded), plus website build,
  131 script, 19 publisher and 13 installer tests. Logs:
  `/tmp/ctrlx-3.0.55-{unit-tests,website-build,script-tests,publisher-tests,installer-tests}.log`.
