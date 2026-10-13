# Agent iOS pane / Viewer implementation

- [x] Add pane default reuse, explicit `--new`, startup coalescing and live owner checks.
- [x] Detach/adopt local workspaces and update pane routes without closing devices.
- [x] Add capability-gated descriptors, read-only frame requests and bounded native JPEG encoding.
- [x] Wire shared preview admission/congestion limits and Mac/iOS Viewer surfaces.
- [x] Add regressions for reuse, shutdown during startup, workspace adoption, frame ownership/coalescing, screenshot priority, native bounds, restart and old-peer decoding.
- [x] Complete focused regressions, resource checks and changed-line formatting checks.
- [x] Build signed Mac App and compile the iOS Simulator SDK target.
- [x] Complete real iOS 27 helper and isolated Host window acceptance; clean up test resources.
- [x] Update capability/operations documentation with actual validation outcomes.
- [x] Fix Host simulator tab loss on session rename; cover route-first and UI-first migration, selection/split preservation, extra devices and real pane moves.
- [x] Preserve simulator selection and independent right-side placement when a window is reindexed; cover background refresh and `open` routing before/after UI remapping.
- [x] Share complete-snapshot rename detection with `open`; verify UI-first/open-first migration and real cross-session moves.
- [x] Synchronize simulator routes before ordinary pane-change broadcasts; cover external rename without another `open` or a layout event.
- [ ] Complete paired Mac/iOS Viewer UI acceptance over a real connection. Compilation and the checks below do not establish this result.

## Evidence (2026-10-13)

The retained local evidence is `.build-local/diagnostics/agent-ios-pane-viewing/`.
No installed App or running user session was replaced. No commit or merge was made.

- `swift-tests.log`: focused `Simulator|RemoteBrowser|WindowTabAction|ConnectedViewerLifecycle` run succeeded. Swift Testing reported 188 tests across the selected targets, with two opt-in native cases skipped. The new preview integration case was run separately; the unchanged storage round-trip was not repeated.
- `native-preview.log`: opt-in helper/pane run passed (10 tests). A new private iOS 27 device supplied valid 512 / 1024 / 2560 JPEG previews both headless and subscribed, then PNG capture still worked. The largest sample was 395,881 bytes. The test shuts down and deletes the private device. A preceding run reported missing live clock dependencies in the integration fixture; the corrected run explicitly uses live dependencies and passed.
- `macos-build.log`: `scripts/package-local-macos.sh --app-only` succeeded, including signing verification. Candidate: `.build-local/DerivedData/macOS/Build/Products/Release/CtrlX.app`. Both bundled skill copies match the source.
- `ios-build.log`: workspace `Ctrlx`, Debug, generic iOS Simulator build succeeded. This is SDK compilation with signing disabled, not an iPhone installation or Viewer UI run.
- `ui-verification.json`, `ui/`, and the adjacent CLI JSON: an isolated signed App with a private tmux socket, API socket, state root and mock browser keychain displayed an iPhone 18 Pro / iOS 27. Repeated `open` returned the same ID and UDID. Closing the workbench detached the view while preserving the device and agent writer; selecting the adopted tab in a reopened window restored a visible, input-ready picture. The caller was a native Codex ancestry fixture, not a model session. The device was then closed/deleted, the test App exited normally, and the private tmux and temporary root were removed.
- `skills.log`: 14 resource checks passed; SKILL is 4,967 bytes and operations is 13,792 bytes. Brand and technical boundaries and `git diff --check` passed.
- `style.log`: new Swift files and changed line ranges pass SwiftFormat except the added workspace registration line in `MainView.swift`, which retains the surrounding indentation. Whole-file lint also encounters existing violations and a `MainView.swift` parser failure reproduced against `HEAD`; unrelated formatting was left alone.

### Session rename review fix (2026-10-13)

Evidence is in the `rename/` subdirectory of the same diagnostics directory.

- `tests-before.log`: the new regression failed on the old routing behavior in all four route/UI ordering and split combinations (18 assertions). It uses the service and the same tab attachment/session migration functions as MainView.
- `tests-after.log`: 27 tests in `SimulatorPaneViewingTests`, `SessionRenameTests` and `RemoteBrowserTabSelectionTests` passed. A complete session rename preserves both the default and extra device tabs, their order, selection and split placement; a real pane move still detaches/attaches. Repeated `open` and `show` keep the existing device.
- `macos-build.log`: the updated signed Release App built successfully. No iOS target or wire model changed in this fix, so its earlier SDK compile is not repeated.
- `verification.json`, `after-ax.txt`, `split-after-ax.txt` and JPEGs: the isolated signed Host displayed a new iOS 27 device during two external tmux renames. The selected single-pane tab and then the selected right-side tab retained the native picture; `open` reused the ID/UDID, and `show` succeeded. This exercises Host UI reconciliation, not a paired Viewer network command. The native Codex ancestry fixture is not a model session. The device was closed/deleted, the test App exited with status 0, and the private tmux server and temporary directory were removed.
- Changed Swift line ranges and the test file pass SwiftFormat; full-file lint retains the existing violations and MainView parser failure, also reproduced against `HEAD`. Brand/technical boundary checks and `git diff --check` pass. No performance sampling or installed-App replacement occurred.

### Window reindex review fix (2026-10-13)

Evidence is in the `reindex/` subdirectory of the same diagnostics directory.

- `tests-before.log`: all four new cases failed on the old routing behavior (22 assertions). They cover background refresh versus `open` discovering the reindex, each before or after MainView's window mapping.
- `tests-after.log`: 33 tests in `SimulatorPaneViewingTests`, `SessionRenameTests`, `WindowReorderTests` and `RemoteBrowserTabSelectionTests` passed. Default and extra devices retain their tab identities, order, selection, right-side placement and updated source associations. A change of stable window ID still detaches and reattaches.
- `macos-build.log`: the updated signed Release App built successfully and passed signing verification. No iOS target or wire model changed in this fix; the earlier iOS SDK compile is reused.
- `verification.json`, window listings, AX text and JPEGs: an isolated signed Host displayed a new iOS 27 device in an independent right-side tab. An external private-tmux window swap changed the source index from 1 to 2 while preserving stable window ID `@0`; after Host reconciliation, the selected tab, split and native picture remained. `open` reused the device ID/UDID and `show` preserved the split. The native Codex ancestry fixture is not a model session, and this is not paired Viewer network acceptance. The device was closed/deleted, the App exited with status 0, and its private tmux server and temporary root were removed.
- Changed service lines and the test file pass SwiftFormat. Brand/technical boundary checks and `git diff --check` pass. No performance sampling or installed-App replacement occurred.

### `open` before session-route refresh review fix (2026-10-13)

Evidence is in the `open-rename/` subdirectory of the same diagnostics directory.

- `tests-before.log`: the four added UI-migration/selection cases failed with 18 assertions when `open` ran before the batch route update. The previous rename tests covered `open` only after that update.
- `tests-after.log`: the filtered run reported 189 tests across 24 suites and succeeded, with two opt-in native integration tests skipped. The new cases preserve the default and extra devices, tab order, selection and split in both UI migration orders. Cross-session pane moves still reattach whether discovered by `open` or background refresh. A routing test confirms that the resolved caller and complete pane snapshot come from one tmux query, without mutating the UI cache.
- `macos-build.log`: the updated signed Release App built and passed signing verification. No iOS target, wire model or native renderer changed; their earlier compilation/performance evidence is reused.
- `verification.json`, AX text, JPEGs and CLI JSON: the isolated signed Host displayed a new iOS 27 device in a selected independent right-side tab. The native Codex ancestry fixture ran external `rename-session` followed immediately by `open`; the device ID/UDID, selection, split and native picture remained, and the returned view was input-ready. `show` also succeeded. Exact callback ordering is covered deterministically by the unit cases; this UI check does not force that order or exercise a paired Viewer. The device was closed/deleted, the App exited with status 0, and its private tmux server and temporary root were removed.
- Changed Swift ranges and the pane/viewing test file pass SwiftFormat; `style-fixtures.log` records the corrected formatting of the two updated initializer calls. Brand/technical boundary checks and `git diff --check` pass. No performance sampling or installed-App replacement occurred.

### Ordinary pane-refresh routing review fix (2026-10-13)

Evidence is in the `periodic-rename/` subdirectory of the same diagnostics directory.

- `tests-before.log`: both new cases failed on the old broadcast-only callback: the first broadcast retained the old session name and preview under the new name failed (four issues). A preceding fixture run also exposed missing clock dependencies; the fixture now supplies a live clock for real tmux subprocess timeouts.
- `tests-after.log`: 57 tests across eight suites passed. The new regression starts a private tmux server, renames externally, and invokes ordinary `refreshPanes` through the same callback wiring as AppCoordinator. Without a second `open` or a layout callback, the first broadcast contains the new routes for both default and extra devices, preview accepts the new session and rejects the old one, and selection/split state survives either UI migration order. Unchanged refresh adds no broadcast, and route synchronization adds no tmux query. Simulator process/preview I/O uses the existing test fixture; this is not a real paired Viewer or rendered simulator acceptance run.
- `macos-build.log`: the updated Release App built successfully and passed deep/strict signature verification; build stamp `20261013-061555`. The installed App was not replaced or launched.
- `tests-cleanup.log`: both new cases passed again after adding explicit removal of tmux's stale socket file. All private test servers stopped and their sockets were removed; the final check and source/build identities are in `verification.json`.
- Changed Swift ranges and the test file pass SwiftFormat; brand/technical boundaries and `git diff --check` pass. Only Host callback wiring changed, so existing native rendering, iOS compilation and performance evidence remains applicable; no new performance sampling or installed-App replacement occurred.

## Remaining acceptance boundary

Real paired Mac/iOS Viewer selection, reconnection and displayed images remain
unverified end to end. The current checks cover protocol compatibility, bounded
encrypted-envelope sizing, polling/restart, queue routing, native capture and local
Host lifecycle. Remote input, remote device management and continuous video remain
outside this implementation. Existing local performance evidence is reused; no new
latency, multi-device capacity or concurrent-Viewer performance claim is made.
