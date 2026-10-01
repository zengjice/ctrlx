# Terminal Rendering Investigation: Garbled Output in Ctrlx Mirror

> **Historical status (PR #179):** The first fix moved live terminal bytes to `pipe-pane`, resolving corruption in the original String-based `%output` parser. In September 2026, terminal content moved back to control mode. The September 8 findings below correct two holes in that transition: connection identity and capture atomicity. `pipe-pane` remains scan-only for OSC side effects. The older diagrams and hypotheses below are historical; see `streaming-architecture.md` for the current data flow.

## iOS remaining layout cost (September 30, 2026)

After Mac scrolling became acceptable, iOS still rebuilt attributed strings and
CoreText layouts on every CoreGraphics draw: the existing moved-line cache was
Mac-only. Local-device packaging also hard-coded Debug, unlike Mac Release.
SwiftTerm `157d01c` shares that cache with UIKit, with viewport bounds,
font/color/mode invalidation and selection/dynamic-link bypasses. Local iOS
packages now default to Release; Debug remains separately selectable for A/B.
See `swiftterm-ios-scrolling.md` for the implementation and validation evidence.

This is a display-client optimization. Host, Relay, Codex launch, wheel step,
DEC 2026 and feed/input queues are unchanged. Cache/pixel regressions and the
iOS Release build passed, but no iPhone FPS or hand-feel measurement was made.
Dirty-region drawing and feed-budget tuning remain deferred until profiling.

## 3.0.40: remaining scroll cost after 3.0.39 (September 29, 2026)

The user confirmed the black/blurred first-frame regression was fixed, but still
reported stutter on all three display clients, especially scrolling down toward
the latest content. A Release-optimized native-window probe at `a2fe208` found
two independently avoidable costs:

- DEC 2026 completion invalidated the native layer without consuming the dirty
  range. The delayed `updateDisplay` then invalidated that same frame again:
  45 synthetic updates produced 90 draws. Commit the dirty range and final caret
  state before re-arming native display. Keep the re-arm for first-frame/timeout
  recovery, the sync barrier, and the 3.0.39 backing-scale/redraw-policy fix.
  Ordinary output and bytes following sync-end still use the existing scheduler.
- The Mac CoreGraphics cache was keyed by buffer row. DECSTBM moves intact line
  objects to different rows, losing almost every cache hit. Key by line identity
  plus generation and columns, retaining only visible line objects. Rebuild
  row-dependent Kitty placeholder data when its row changes; selection and
  dynamic link highlighting still bypass the cache. Existing font/color/mode
  invalidation remains intact.

SwiftTerm fix: `4abe9a486d80ec0d9e820dbd6c6a48f112b0fe7e`. No transport,
wheel sensitivity, Codex launch settings, or Relay protocol change is included.
The shared presentation fix applies to Mac and iOS; moved-line caching is Mac
only. Each display client needs its updated binary; Relay needs no deployment.

For the same synthetic 197-column/61-row Retina fixture, Release measurements
were: 45 updates → **45 draws** rather than 90; region-scroll first-draw medians
about **7–8 ms**, rather than 15.4 ms plus a second 14.9 ms draw; cache hits
**58/61** rather than 4/61. Full content rewrites still took about 15.3 ms per
draw and do not receive the moved-line benefit. These are isolated CPU drawing
measurements, **not real three-device FPS or subjective smoothness acceptance**.

A private Codex `/status` fixture (no requested model work) was rerun after
rejecting an initial attempt that sent commands before startup was ready. The
valid run used 16 up and 16 down wheel events in fullscreen mode, returned to
the original latest screen, and preserved the composer. Replaying its captured
byte stream through the fixed Release renderer produced one draw per wheel
group, no repeat draws, a visible final input prompt and no pending dirty range.
Downward replay p95 was still about 18 ms versus 9 ms upward; contents differ,
so neither the directional cause nor perfectly smooth scrolling is established.
The isolated tmux server was stopped; existing user sessions were untouched.

Validation: new dirty-range/native-window tests failed before the fix and passed
after it. Full SwiftTerm regression passed: **518 Swift Testing + 85 XCTest**
tests, including black-first-frame, scale changes, sync timeout, cursor, Metal,
selection, and cache lifetime/mutation/row-dependency coverage. Test logs:
`/tmp/ctrlx-scroll-{commit-red,commit-green,swiftterm-full,release-fixed-verified,real-replay}.log`.
CtrlX resolved the published pin independently through SwiftPM and Xcode, with
no other dependency revision changes. Its 144 focused rendering/input/feed/
scroll regressions passed; the workspace Mac Release and iOS device-target
Debug compile checks passed (unsigned, not installable release artifacts).
Logs: `/tmp/ctrlx-scroll-{integration-tests,mac-build,ios-build}.log`.
The shared presentation test source also type-checked against the iOS SDK and
the newly built SwiftTerm module (`/tmp/ctrlx-scroll-ios-test-typecheck.log`);
the standalone check requires Xcode's TestingMacros plugin search path.
Native iOS execution and affected-device hand-feel acceptance remain separate
from Mac tests and compilation. No app installation or publication is part of
this implementation step.

Release preparation for **3.0.40**: brand/technical boundaries, ten offline Mac
publisher tests, website build and the versioned iOS device-target compile
passed. The full CtrlX run completed with 2,197 passing tests and only the same
two `StopFinalityEvaluations` failures as 3.0.39: this Mac reports Apple
Intelligence `deviceNotEligible`. This is not an all-green full test run.
Logs: `/tmp/ctrlx-3.0.40-{unit-tests,website-build,ios-compile}.log`.
The Qcloud Mac-only publisher verifies the signed artifact and public download;
local Mac/iPhone installation and real-device scrolling acceptance are not part
of this publication. Relay and the Linux lock are unchanged.

## 3.0.38 Mac regression: black first frame and blurry text (September 29, 2026)

A second Apple Silicon Mac on macOS 27 showed a black terminal until scrolling,
then visibly blurry text. Ordinary shell tabs were affected too, so Codex's TUI,
tmux mouse mode and the remote transport were not prerequisites. A standalone
native-window probe reproduced both defects locally against SwiftTerm `e21a8f5`:

- The new `TerminalDisplayLayer` replaced AppKit's default backing layer but
  retained the default view redraw policy. AppKit consumed ordinary view
  invalidations without drawing: the initial frame and a later plain text feed
  both produced zero `draw` calls. Explicit layer invalidation (including a
  DEC 2026 end) could mask the black frame.
- The custom layer stayed at `contentsScale == 1` in a 2x Retina window. Once
  drawn, it rasterized at 1x; scaling the result caused the blurry text.

The previously installed local app was a `3.0.37 / 20260929-045206` development
build, not the published `3.0.38 / 20260929-062024` artifact. Both included the
custom-layer code. A working local view was therefore not evidence against this
regression, and artifact/signature/hash checks did not exercise first paint.

The minimal correction is pinned at SwiftTerm `a2fe20899518a9d66200065d124c62fa4cd6be15`
and belongs in its **Mac** `TerminalView`: explicitly
use `.onSetNeedsDisplay`, initialize the layer's pixel scale, and synchronize it
on window attachment and backing-property changes. Invalidate after a scale
change without resetting the font, terminal grid, cursor, selection or buffer.
Keep the DEC 2026 display barrier and stable caret; do not add periodic refresh,
forced scrolling, input replay, transport resubscription or a renderer switch.

The earlier presentation tests explicitly called `layer.display()` or
`displayIfNeeded()`, which bypassed the missing native invalidation path. New
`MacBackingLayerLifecycleTests` use real windows (including a SwiftUI host),
service the native run loop **and yield the main executor**, and never force a
layer display to obtain the result. They cover ordinary first/next frames,
Retina scale, 1x/2x changes, window reparenting, hidden-tab restoration, resize,
sync-end and sync timeout without further output. Existing pixel/caret/Metal
tests still guard against exposing incomplete synchronized frames.

Validation checkpoint: the same nine lifecycle tests failed against `e21a8f5`
and passed against `a2fe208` (the first-frame test also covers both AppKit and
SwiftUI hosts). Full SwiftTerm regression passed: 515 Swift Testing tests and
81 XCTest tests. CtrlX's focused rendering, input, selection, sizing and scroll
regression passed: 208 tests. The workspace Mac Release build and
`codesign --verify --deep --strict` passed using the remotely resolved fixed pin.
Logs: `/tmp/ctrlx-mac-backing-{baseline,green,swiftterm-full,integration-tests,release-build}.log`.
The SwiftTerm fix was committed and pushed; this validation did not install or
publish CtrlX, deploy Relay, or commit the CtrlX worktree.

Rollout is Mac display clients: update a Mac used locally or as a Viewer.
There is no Relay change, iOS rendering change or protocol migration. Passing
local native-window tests is not a substitute for acceptance on the affected Mac.

Release preparation for **3.0.39**: boundary checks, all ten offline Mac
publisher tests, the website build and the iOS device-target compile passed.
The full CtrlX test invocation finished with 2,197 passing tests and the same
two `StopFinalityEvaluations` failures as 3.0.38: Apple Intelligence reports
`deviceNotEligible` on this Mac. This is an environment-limited eval run, not
an all-green full suite; no other test failed. Mac-only publication does not
require a local Docker engine, Linux lock regeneration or a Relay deployment.
No iOS package/install is part of this patch release. Release preparation logs:
`/tmp/ctrlx-3.0.39-{unit-tests,website-build,ios-compile}.log`.

## Fullscreen scroll feel, without disabling Codex's new TUI (September 29, 2026)

The user confirmed smoother scrolling with `codex --no-alt-screen` but wants to
keep the new fullscreen transcript/fixed composer. Do **not** change the launch
default or persist a Codex TUI setting. A private 0.158.0 A/B probe confirmed
the difference in ownership: fullscreen used the alternate screen with zero
tmux history; inline accumulated 203 history lines. Eight fullscreen wheel
inputs produced 27,318 output bytes (first output 1.35–10.77 ms locally), whereas
inline did not redraw its transcript in response. These timings are not remote
latency or displayed-frame measurements.

[Codex 0.158.0's transcript mouse handler](https://github.com/openai/codex/blob/rust-v0.158.0/codex-rs/tui/src/transcript_view/input.rs)
hard-codes three rows per wheel event and ignores events outside the transcript
unless selecting. CtrlX's previous touch/trackpad conversion assumed one row per
event; a 30-cell-height drag therefore requested 90 rows, not 30. iOS additionally
discarded the pan's final translation, stopped immediately on release, and sent
wheel coordinates following the finger into the fixed composer.

Current client-side correction:

- Shared `TerminalMouseScrollAccumulator` conserves fractional motion and resets
  on direction/profile/gesture changes. Known Codex + alternate screen uses a
  three-cell-height threshold for precise gestures. Other agents, inline mode
  and discrete Mac mouse-wheel notches keep their existing sensitivity. Agent
  identity comes from existing pane metadata, never terminal text matching.
- Host Mac and Viewer Mac use the same native view. AppKit continues to own
  momentum; its gesture-end to momentum-start transition retains the remainder,
  while a new gesture or cancelled/finished momentum resets it.
- iOS keeps fullscreen Codex's wheel coordinates at the initial touch area,
  consumes the final pan delta and adds a short, capped coast. The deceleration
  math is elapsed-time based, using the native fast decay rate. A common-mode
  display link generates ordinary wheel events, not animated screenshots.
- Touch-down, input, selection, inactive panes, teardown, changed agents/modes
  and background/stalled clocks stop coasting. The display-link target owns only
  a weak reference; no native view/run-loop retain cycle is introduced.

There is no output dropping, speculative cursor/arrow input, snapshot replay,
new queue/relay protocol, or SwiftTerm dependency change in this correction.
The three-row Codex step and remote network latency still exist: this fixes
over-amplification, interruption and touch coasting, **not pixel-smooth scrolling**.
Do not equate fewer wheel packets or passing tests with measured frame-rate gains.
Update each display client (local Host Mac, Viewer Mac, iOS) to receive its fix;
Relay needs no deployment.

Regression coverage: common motion/distance tests, Mac native wheel/selection/
modifier tests, existing native click encoding and input FIFO/transport tests.
iOS native gesture tests cover anchored coordinates, gesture-end motion and
cancellation; device execution and subjective acceptance remain separate checks.

Validation checkpoint: 60 targeted Swift tests passed (30 Mac input/mouse/raw
transport, 8 shared click/routing, 22 motion/input-queue tests). Mac Release and
iOS device-target Debug builds passed; iOS `build-for-testing` also compiled the
native scroll and selection fixtures. No simulator runtime or installed app was
changed. The native iOS fixtures have **not** been executed on an iPhone in this
pass. Logs: `/tmp/ctrlx-fullscreen-scroll-{tests,mac-build,ios-test-build}.log`.

Release preparation checkpoint for 3.0.38: the full Swift test invocation
completed with 2,197 passing tests. Two `StopFinalityEvaluations` tests failed
because this Mac reports Apple Intelligence `deviceNotEligible`; this is not
an all-green full suite. Brand/technical boundaries, the website build and ten
offline publisher tests passed. The signed iOS package was unpacked and its
signature and SHA-256 verified, then copied to `Documents/Inbox`. Mac-only
publication uses the maintainer's Mac publisher, without local Docker or a
Relay redeployment; it does not validate the Linux build/lock in this pass.

## Synchronized presentation and stable caret (September 29, 2026)

The input-path change below did not restore pre-upgrade scrolling smoothness.
A private Codex 0.158.0 fixture moved **three rows per SGR wheel event**. That
application-owned step is separate from a shared SwiftTerm presentation defect;
this fix does not remap/drop wheel input or promise pixel-smooth TUI scrolling.

At SwiftTerm `42611d3`, `updateDisplay` and `queuePendingDisplay` respected DEC
2026, but AppKit/UIKit draw callbacks and Metal's delegate did not. A native
pixel probe drew `INCOMPLETE` before sync-end. Cursor visibility commands also
removed/added the caret subview inside the frame. A 120-frame probe measured
120 removals and 120 additions; a live Mac stack sample showed that path reaching
SwiftUI platform-view layout invalidation. These identify mechanisms, not a
measured three-device FPS improvement.

The shared Apple renderer now:

- Defers `CALayer.display` before the native backing store is cleared/replaced,
  retaining the last completed image. Both platform `draw` entries and the
  shared CoreGraphics routine also guard against painting an incomplete frame.
  No scrollback snapshot, per-frame screenshot or extra debounce is introduced.
- Re-arms native invalidation at sync-end, including the existing timeout,
  reset and resize paths. First presentation must recover without another byte.
- Stops Metal before acquiring a drawable during sync; the last presented
  drawable remains on screen. Test-runner resource-bundle lookup also checks
  the package's code bundle/products directory rather than only the runner.
- Keeps the caret attached, updates visibility in place, and defers position,
  visibility and style until frame completion. Switching back from Metal must
  preserve a hidden caret. Gesture routing, selection/IME, terminal dimensions,
  byte transport and input ordering are unchanged.

`SynchronizedPresentationTests` exercises native backing-store pixels, direct
draw guards, first frame, 120 cursor cycles with zero subview additions/removals,
scrollback, timeout, reset/resize, style and the Metal drawable boundary. The
Mac selection and modified-arrow/IME regressions remain part of the fork suite.

This is a **display-client change**: update the Host Mac for its local view,
the Viewer Mac for its view, and iOS for its view. Relay needs no deployment.
The earlier input-path optimization remains Host-only. Native iOS execution and
three-device subjective scrolling acceptance are separate from compilation and
Mac regression tests; do not infer them from a successful build.

Validation and dependency checkpoint:

- The implementation and 10 new presentation regressions were committed and
  pushed to the SwiftTerm fork as `e21a8f566e5bb2593a5bb57a6fdb8f8becb555ad`.
  Its full Mac suite passed (506 Swift Testing tests plus 81 XCTest tests);
  the new suite also passed with Swift Build's test runner.
- CtrlX's 39 targeted input/mouse/metrics/routing tests passed using that local
  dependency and again using the published fixed revision. Full concurrent
  CtrlX runs terminated with SIGPIPE twice. A serial server run completed 969
  tests with one tmux working-directory assertion failure; both pane-split tests
  passed when rerun independently. This is **not** an all-green full CtrlX suite.
- Mac Release and iOS device-target Debug builds passed with the local fork.
  The new presentation tests also type-checked against the iOS SDK; they were
  not executed on a phone. A separate Mac Debug build failed linking GallagerCLI
  against IssueReporting; no unrelated dependency-source changes were made.
- Temporary workspace/SwiftPM local overrides were removed. CtrlX's manifest
  and both lockfiles now pin `e21a8f5`; SwiftPM and Xcode resolution independently
  checked out that published revision. All other locked dependencies are
  unchanged. The CtrlX changes remain uncommitted; no installed app was replaced.

## Application-managed scrolling input (September 29, 2026)

Codex CLI 0.158.0 was observed using the alternate screen and mouse reporting.
Its transcript scrolling therefore needs an input event to reach Codex before
the resulting output can be drawn; it is not just local terminal scrollback.
The fixed composer is expected. It does not establish the cause of every stall.

The local Mac raw-input path and both remote viewers' Host command executor
were spawning `tmux send-keys -H` for each mouse batch. They now reuse the
pane's existing control connection through `PaneStreamManager`, just as local
keyboard input does. The byte encoder validates the pane ID and the entire
4096-byte budget, then hex-encodes the bytes without UTF-8 conversion. Larger
payloads and unavailable connections retain the original process fallback.
There is no new connection, debounce delay, input dropping, gesture change,
resize or snapshot policy. The local key/raw FIFO and remote connection FIFO
remain the ordering owners.

Only an explicit **no-write** result permits fallback. Pending commands at
disconnect now fail with `processTerminated`, not `notConnected`: they may
already have executed, so replaying them could duplicate clicks or keys. The
pre-write missing-stdin guard still reports `notConnected`. This also closes
the same ambiguity in the existing local keyboard fast path.

`RawTerminalInputTests` checks encoding, bounds, no-connection behavior,
fallback and ambiguous failures. A private tmux/PTY fixture receives 120 wheel
batches with direction/coordinate changes, a click/release and interleaved
keyboard batches through local, viewer-command and legacy process routes.
It checks the received byte digest, zero input subprocesses on the fast paths,
and one shared control client. Timings printed by this fixture measure input
delivery/acknowledgement, **not Codex frame rate or remote network latency**.

Diagnostics reuse bounded aggregate metrics: local raw input now participates
in `localInputToSend/Write/Acknowledgement/Output/Feed` and the existing input
queue gauge; `rawInputQueueWait` measures remote Host FIFO wait, and
`rawInputSend` measures Host send duration. Output/feed correlation is
best-effort against the first later pane output, not a causal frame marker.

Rollout is **Host Mac only** (the Mac running the Codex sessions). Existing Mac
Viewer/iOS clients and Relay protocol are unchanged. Actual three-device
scrolling smoothness still needs user acceptance after installing the Host;
whole-line mouse scrolling and iOS inertia are separate follow-ups if needed.

## Host resync subscription races (September 28, 2026)

An intermittent report described input reaching tmux but not appearing in the
Host mirror or remote viewers until reopening the session. A live test did not
capture a persistent stall, but deterministic tests against a private tmux server
reproduced two defects in the shared Host `PaneStreamManager`:

1. `runResyncLoop` copied `ReaderContext` before awaiting a dimension query, then
   wrote the entire old value back. A subscriber joining during that await could
   receive its initial snapshot yet disappear from the live delivery set. The
   same write resurrected removed subscriber IDs and reverted changed titles.
2. Resync suppressed live output pane-wide but sent its replacement snapshot only
   to the subscriber IDs present at the start. Even after fixing the stale write,
   a newly ready subscriber missed output between its own snapshot and the shared
   resync boundary.

The fix rereads the current reader after the await, verifies its identity and
cancellation/shutdown state, and updates only dimensions. The resync snapshot
and its buffered tail go to all currently ready subscribers. Subscribers still
bootstrapping continue buffering raw output against their own snapshot boundary;
the pane-wide tail must not be appended to those private buffers a second time.
Capture failure also notifies newly ready subscribers affected by suppression.

`PaneStreamConsistencyTests` pauses one dimension response through the existing
`ProcessRunner` dependency while retaining real tmux capture, manager subscription
logic and headless SwiftTerm rendering. Coverage includes join/leave, title
changes, resize- and backpressure-triggered resync, query failure, shutdown,
output during the suspended resync, and repeated resyncs during concurrent joins
and Chinese output. Tests compare final terminal cells with tmux, not just counts.

Rollout is **Host Mac only**: rebuild/restart the Mac running the sessions and
reconnect mirrors. No iOS/Viewer protocol, Relay, SwiftTerm, selection or resize
policy changes are involved. This establishes the repaired race mechanisms, not
proof that every historical display failure has the same cause. A separate
mistaken GUI-as-CLI second process was observed but not established as causal;
this fix does not stop or otherwise alter that process.

## 3.0.28 (September 11, 2026): Mac selection disappears during output

The affected Mac's Codex panes reported zero for `mouse_standard_flag`,
`mouse_button_flag`, `mouse_all_flag` and `mouse_any_flag`. That snapshot does
not support Codex actively capturing the mouse as the explanation. It does not
by itself measure the mirror's state or explain the old/new-pane asymmetry.

An isolated reproduction using CtrlX's shared Mac terminal view established a
separate deterministic defect: a plain or Shift drag established a local
selection, then a cursor-visibility sequence (`CSI ?25h`) cleared it without
any mouse report being sent. SwiftTerm's `feedPrepare` and Mac `linefeed`
callback cancelled selection whenever `allowMouseReporting` was true. That is
an embedding permission (true by default on Mac), not the application's current
mouse mode. Static gesture tests in 3.0.27 did not interleave output with drags.

The fix keeps Mac local selection independent of output delivery. The terminal
model invalidates selection on actual buffer replacement/reset and grid resize;
existing scroll handling translates anchors or discards evicted selections.
Unchanged AppKit layout does not discard selection. Explicit clicks, committed
text, paste and CtrlX's directly routed shortcuts still end the selection;
copying does not. Output is never deferred and application mouse routing is
unchanged. The UIKit selection/gesture policy is not changed.

`MacSelectionLifecycleTests` and `SelectionLifecycleTests` cover the SwiftTerm
boundaries. `MacTerminalMouseRoutingTests` interleaves fragmented output with
drag events in both pane positions and through both Mac feed entry points,
checking visible output, retained selection, no leaked mouse input and auto-copy.
These regressions establish the repaired mechanism, not an end-to-end claim
that every new-pane failure on the affected Mac had this cause. Update the Mac
displaying the pane (Host or Viewer) for device acceptance; Relay is unchanged.

## 3.0.25 (September 8, 2026): Relay reorders remote terminal frames

Both Macs running 3.0.24 could still show a mostly blank Viewer with no composer.
The later Host capture had its composer intact; that observation was not a
simultaneous capture of the failing Viewer. A separate lossless localhost test
against the real Relay reproduced an ordering defect: all 600 mixed-size opaque
frames arrived once, but `0,1,2` became `2,1,0`. Text and binary frames both
failed. These deliberately mixed-size loads are not production failure rates.

The pinned WebSocketKit async `onText`/`onBinary` overload creates an independent
Task for each frame. The old `RelayGate` only gated validation; once open, full
decode/validate/forward operations raced across actor suspension points. Smaller
later frames overtook larger earlier ones. Per-frame encryption and total
snapshot byte counts do not authenticate or verify stream order, so late erase
or cursor commands can destroy an otherwise complete terminal screen.

The fix is confined to the Relay:

- Register synchronous text/binary handlers in the synchronous upgrade callback,
  before starting async validation. Both append to the same `RelayInboundQueue`.
- One worker validates the connection, then awaits each complete forward in FIFO
  order. The connected notification is a barrier behind early registration frames.
- Bound queued traffic to 1024 frames and 8 MiB after validation, retaining the
  1 MiB pre-validation limit. Overflow discards the queue and closes the socket;
  continuing after a silently dropped terminal frame is never safe.
- Close/replacement stops the consumer and clears queued frames. Raw forwarding
  rechecks the source socket in `ConnectionHub` immediately before sending, so
  an old in-flight frame cannot escape after its source was replaced.

`RelayInboundQueueTests` covers validation, suspended forwards, byte/count bounds,
close and cancellation. `ViewerReconnectRoutingTests` covers six combinations of
direction/framing, immediate-upgrade traffic and stale sockets. On macOS it also
feeds chunked initial/reset snapshots with 3000 CJK/emoji history rows, split
ANSI/UTF-8, a snapshot/live boundary within one chunk, and live updates through
the real Relay, the shared snapshot accumulator and headless SwiftTerm. Assert
exact forwarded bytes and final cells, including the composer and status row.
The license and minimum-client-version gate regressions must continue to pass.

Deploy this **Relay** change, then reconnect the Viewer to replace any already
corrupted buffer. Existing 3.0.24 clients are compatible; no client viewport,
selection gesture, resize policy or SwiftTerm revision changes are needed.
The ordering defect is reproduced, but a failing production Viewer's complete
stream was not captured: real-session acceptance is still required, and this
does not claim to explain every historical rendering symptom.

## 3.0.23 (September 8, 2026): Host-local duplicate output and missing composer

The same corruption occurs directly on the Host Mac, before Relay or iOS are involved. New screenshots show repeated adjacent lines as well as erased composer text. A viewport-only fix cannot repair a terminal buffer already changed by duplicate or mispositioned escape sequences.

### Reproduced causes

1. **Pane target mistaken for connection identity.** Discovery stored the reader under its real session (`coding`), but `subscribe(target: "%6")` enabled output on a new connection keyed by `%6`. Capture and unsubscribe still used `coding`. This both broke the ordered snapshot boundary and left the other source enabled. On a later subscription through the named target, one real tmux `LIVE_ONCE` update was rendered twice. Read-only process inspection also found the installed CtrlX process owning both session-targeted and pane-targeted control clients.
2. **Concurrent connection creation.** `getClient` suspended while setting actor callbacks before publishing the client in its dictionary. Eight concurrent first requests returned eight distinct clients. `@MainActor` does not prevent reentrancy across `await`.
3. **Inconsistent snapshot state.** History, cursor and visible cells were queried with separate awaited commands. A real tmux pane moving a `FRAME` marker between rows reproduced a snapshot with the marker on one row and the restored cursor on an empty row. Later relative cursor motion therefore edits the wrong rows even if transport bytes are otherwise ordered.

### Minimal corrective changes

- Resolve an unknown pane's owning session once; enable, capture and disable using the same reader session. Stable `%paneId` remains the **command target**, so window renumbering remains safe.
- Share one in-flight connection task per session, and cancel/reap it on shutdown.
- Send history capture, visible capture and cursor query as one non-blocking command list. Mark the stream boundary only at the last response. tmux drains non-waiting commands in the list before returning to pane I/O; on command error it skips the remainder of that group ([tmux 3.7b command queue](https://github.com/tmux/tmux/blob/3.7b/cmd-queue.c)).
- Retain timed-out response slots until drained; otherwise a late response would be mistaken for the next snapshot.

### Regression coverage and rollout

`PaneStreamConsistencyTests` uses private tmux sockets and a raw echo pane, without a user shell configuration. It checks stable-ID and on-demand subscriptions, reopen/duplicate output, eight concurrent connects, failed command lists, ten viewers joining during 80 lines of Chinese output, and 80 changing-screen captures both with and without history. `BlockParsingTests` checks the final-response boundary and late-response draining. Compare rendered SwiftTerm cells with real tmux capture, not just serialized byte counts.

These fixes are in the **Host Mac** capture/stream layer. Update and restart CtrlX on the Mac running the affected tmux sessions, then reconnect viewers; updating iOS or Relay alone cannot activate them. This change does not alter the iOS selection gestures, SwiftTerm dependency, or manual-resize policy. Real-session acceptance is still required after installation; regression success is not proof that every historical rendering symptom had this cause.

## iOS viewport synchronization (September 8, 2026)

The Host fix above does not repair an independently stale UIKit viewport. An
iOS Simulator reproduction using the previously pinned SwiftTerm revision `6b61f169`
confirmed that the emulator can report `scrollPosition == 1` while
`contentOffset.y` still hides the bottom rows. Reducing the grid from 10 to 5
rows before the native height changed left the viewport 75 points (5 cells)
behind, including after native layout and an idle wait. A new output line
repaired it, matching the "quiet session stays wrong until new output" symptom.

Two missing synchronization paths explain this:

- `processSizeChange` updated the scroller only if it also resized the grid.
  Ctrlx correctly resizes the emulator before feeding bytes in the new geometry;
  when Auto Layout catches up, the grid already matches, so no native scroll
  update happened. Insets could change the scroll limit without resizing the
  grid either.
- `scroll(toPosition:)` skipped `scrollTo(row:)` when the logical row was
  unchanged, bypassing that method's existing same-row pixel synchronization.

Keep the fix in SwiftTerm: synchronize the native viewport after size/inset
changes even when no grid resize is necessary, and pass repeated explicit
scroll requests through the same row-scrolling path. Reuse the existing
`updateScroller` rules for active dragging, history momentum and fractional
history offsets; layout is not a request to scroll to the tail or clear a
selection. Ctrlx's first-presentation gate waits for attachment and usable bounds,
while later reset/resize corrections belong to the same native layout path.

`IOSViewportSynchronizationTests` covers same-row requests, Host resize, snapshot
replacement, inset-only changes, manual history with a selection, active dragging,
history deceleration, and unchanged-layout no-ops. Run these on **iOS Simulator**:
macOS `swift test` cannot execute the UIKit-only cases. The earlier shared Host
tests remain necessary for byte/capture consistency, but do not establish native
iOS viewport correctness. The iOS app must build against the fixed SwiftTerm
dependency; editing the sibling checkout alone does not update a remote revision
pin. Ctrlx now pins the published fork fix at `728936318595b408262ed50f93343767c0818d0a`.
Relay does not need changes for this client-side fix.

## Problem Statement

When mirroring complex terminal applications (like Claude Code) that use extensive cursor positioning, the Ctrlx mirror window shows:
1. **Mispositioned text** — content appears at wrong row/column locations
2. **Incorrect colors** — some text displays with wrong SGR attributes

The issue is reproducible. A tmux-rec recording of the same session replayed via raw PTY bytes renders **correctly**, proving the data from tmux is fine but Ctrlx's processing introduces the problem.

## Evidence

- Side-by-side screenshots of the same tmux session at roughly the same point in time — the Ctrlx mirror (text displaced, colors wrong) vs. a tmux-rec replay (correct rendering) — confirmed the mirror was at fault. (The screenshots contained a real working session and were removed from the repo before open-sourcing.)
- E2E scenario screenshots in `E2ETests/16-terminal-rendering-bugs/` visually confirm H17 and scrollback corruption

## Architecture Summary: How Data Flows

```
┌─────────────────────────┐
│    tmux pane (pty)       │
└──────────┬──────────────┘
           │
    ┌──────┴──────┐
    │             │
    ▼             ▼
[pipe-pane]   [control mode -C]
 (tmux-rec)    (Ctrlx)
    │             │
    │         ┌───┴────────────┐
    │         │                │
    │    Initial Capture   Live Stream
    │    (capture-pane     (%output events)
    │     + heavy filter)
    │         │                │
    │         ▼                ▼
    │    filterToColorCodesOnly  unescapeOutputBytes
    │    (strips ALL non-SGR)    + filterTmuxEscapeSequences
    │         │                  (only strips ESC k...ESC \)
    │         └───────┬────────┘
    │                 │
    │          SwiftTerm.feed(byteArray:)
    │                 │
    ▼                 ▼
 ✅ Correct       ❌ Garbled
```

## Key Difference: `pipe-pane` vs Control Mode

| Aspect | tmux-rec (pipe-pane) | Ctrlx (control mode) |
|--------|---------------------|--------------------------|
| **Initial state** | `capture-pane -e -p` → raw bytes, ALL escapes | `capture-pane -e -p` → **filtered**: only SGR (colors) kept |
| **Live data** | Raw PTY bytes (every byte) | `%output` events (octal-escaped, newline-delimited) |
| **Cursor positioning** | `\e[5A`, `\e[10C`, `\r` all preserved | Preserved in `%output`, **stripped from initial capture** |
| **Private modes** | `\e[?2026h/l` etc. preserved | Preserved in `%output`, **stripped from initial capture** |
| **Screen clearing** | `\e[2J`, `\e[K` preserved | Preserved in `%output`, **stripped from initial capture** |

---

## Hypotheses

### H1: `filterToColorCodesOnly` in Initial Capture Strips Critical Escape Sequences

**Likelihood: HIGH**

The function `filterToColorCodesOnly` (TmuxService.swift:394-434) keeps ONLY CSI sequences ending with `m` (SGR for colors/styles). It **strips**:
- Cursor positioning (`\e[H`, `\e[A`, `\e[B`, `\e[C`, `\e[D`, `\e[f`)
- Line/screen clearing (`\e[J`, `\e[K`)
- Scrolling (`\e[S`, `\e[T`)
- Private mode set/reset (`\e[?...h`, `\e[?...l`)
- Any non-CSI escape sequences (like `\e(B` for charset selection)

**Why this matters:** The visible area capture (Part 2) also passes through `filterToColorCodesOnly` (line 373). This means if the visible screen captured by `capture-pane -e -p` contains embedded cursor positioning or other non-SGR codes, they are silently removed. The content is then output sequentially line by line, which **assumes each line is self-contained text + colors**, but tmux's `capture-pane -e` output may include inline positioning within lines.

**How it could cause garbled output:** If the initial screen state is rendered incorrectly (text in wrong positions, incomplete color state), then all subsequent `%output` updates build on top of a corrupted base. The live stream applies cursor moves relative to wrong positions, compounding the error.

**Test:** Compare `capture-pane -e -p` raw output with what `filterToColorCodesOnly` produces. Check if any non-SGR sequences are semantically meaningful for correct rendering.

---

### H2: Non-CSI Escape Sequences Silently Dropped

**Likelihood: HIGH**

The `filterToColorCodesOnly` function (line 422-426) handles non-CSI escapes:
```swift
} else {
    // Non-CSI escape sequence, skip
    i = input.index(after: i)
}
```

This skips the ESC byte and moves on, but the **next byte** (which is part of the escape sequence) is treated as regular text and **appended to the output**. For example:
- `\e(B` (Select ASCII charset) → ESC is skipped, `(` is output as literal text, then `B` is output as literal text
- `\e)0` (Select VT100 graphics charset) → ESC skipped, `)` and `0` output as literal characters

This is a **bug**: non-CSI sequences should skip the **entire** sequence (ESC + type byte + optional params), not just the ESC byte.

**How it could cause garbled output:** Stray characters like `(`, `B`, `)`, `0` appearing in the output would shift all subsequent text positions.

---

### H3: Dimension Mismatch Between Capture Terminal and Mirror Terminal

**Likelihood: MEDIUM-HIGH**

The initial capture is done with `capture-pane -e -p` which captures based on the **tmux pane's dimensions** (e.g., 202×68 from the recording). The mirror terminal may have a **different number of rows** (rows are calculated dynamically from the container height in `recalculateRowsAndResize`).

The code attempts to handle this (lines 335-387) by:
1. Not using explicit row positioning for visible lines
2. Outputting lines sequentially with `\r\n`
3. Calculating `lastMeaningfulLine` to avoid trailing empties

**But:** If the mirror has fewer rows, the content scrolls differently. The cursor position `\e[Y;XH` at line 387 is calculated from the tmux pane's row, not the mirror's. If lines were scrolled off due to size mismatch, the cursor ends up at a wrong position.

**How it could cause garbled output:** With the cursor at a wrong row after initial state, subsequent `%output` data that uses relative cursor movements (like `\e[5A` = cursor up 5) moves relative to the wrong starting point.

---

### H4: `capture-pane -e -p` Output Format Assumptions Are Wrong

**Likelihood: MEDIUM**

The initial capture processes `capture-pane` output by splitting on `\n`:
```swift
visibleContent.split(separator: "\n", omittingEmptySubsequences: false)
```

**Assumptions:**
1. Each `\n`-separated segment corresponds to one terminal row
2. Lines contain only text + SGR codes (after filtering)
3. Lines are independent (no cross-line escape sequences)

**Potential issues:**
- `capture-pane -e -p` may output `\r\n` (CR+LF) line endings — the code handles this for scrollback (line 315-316) but not explicitly for visible content
- Wide characters (CJK, emoji) in `capture-pane` output may span differently than expected
- If a line contains a newline character within escape sequence parameters, the split creates incorrect segments

---

### H5: Timing/Ordering Issues Between Initial State and Live Stream

**Likelihood: MEDIUM**

The code captures initial state and then registers for live updates:
```swift
// PaneStream.connect()
let initialContent = try await tmuxService.capturePaneWithScrollbackForStreaming(target)
try await controlClientManager.registerPane(...) { data in self?.onData?(data) }
return initialContent
```

There's a potential gap:
1. Initial content is captured at time T1
2. Control mode registration happens at time T2 > T1
3. Any terminal output between T1 and T2 is **lost**

For fast-updating terminals like Claude Code (which frequently redraws), this gap could mean:
- SGR state changes between T1 and T2 are missed (wrong colors going forward)
- Cursor position changes are missed (text at wrong positions)

**How it could cause garbled output:** If Claude Code redraws part of the screen between capture and stream start, the mirror has an inconsistent state: initial capture shows one thing, but the stream continues from a different point.

---

### H6: Control Mode `%output` Octal Unescaping Loses or Corrupts Data

**Likelihood: MEDIUM**

The `unescapeOutputBytes` function (TmuxControlClient.swift:387-438) handles tmux's octal escaping. Control mode represents non-printable bytes as `\xxx` (octal).

**Potential issues:**
- The function handles `\\` (escaped backslash) and octal `\NNN`, but what about other escape characters like `\n`, `\r`, `\t`? tmux control mode may use these.
- If tmux outputs a literal backslash followed by digits that happen to look like an octal code, the function may misinterpret it.
- The function checks for octal digits `0-7` but reads up to 3 digits. If tmux uses `\0` (single octal digit), it may not be handled correctly depending on what follows.

**Test:** Create a test case with known byte sequences, run through `unescapeOutputBytes`, verify output.

---

### H7: Private Mode Sequences (`\e[?...h/l`) Affecting Terminal State

**Likelihood: MEDIUM**

The live `%output` stream preserves private mode sequences like:
- `\e[?2026h` — synchronized output (begin)
- `\e[?2026l` — synchronized output (end)
- `\e[?25h/l` — cursor visibility
- `\e[?1049h/l` — alternate screen buffer
- `\e[?7h/l` — auto-wrap mode

These are **correctly passed through** in the live stream. But:

1. **SwiftTerm may not support all of them** — if SwiftTerm doesn't handle `?2026` (synchronized output), it could cause rendering issues where partial screen updates are visible
2. **Initial state doesn't set up private mode state** — after the initial capture, the terminal's private mode flags are at defaults, not matching the tmux pane's actual state

**How it could cause garbled output:** If the real tmux pane has auto-wrap disabled (`\e[?7l`) but the mirror starts with auto-wrap enabled, text that should stay on one line wraps to the next, displacing everything below.

---

### H8: SwiftTerm Terminal Size vs Tmux Pane Size Discrepancy

**Likelihood: MEDIUM**

The mirror terminal's rows are calculated dynamically:
```swift
// TerminalContainerView.swift:354
let newRows = max(1, Int(containerSize.height / cellHeight))
```

But columns come from tmux:
```swift
// TerminalContainerView.swift:276
terminalView.getTerminal().resize(cols: columns, rows: rows)
```

**Issue:** The SwiftTerm terminal buffer has `rows` rows, but the tmux pane has `height` rows. If `rows != height`:
- Cursor positioning sequences from `%output` (e.g., `\e[68;1H` for row 68) may exceed the mirror's row count
- SwiftTerm may clamp or ignore out-of-bounds positions
- Relative cursor moves (`\e[5A`) may wrap or stop at different boundaries

**Critical:** The recording shows dimensions 202×68. If the mirror window is smaller (fewer rows), the entire bottom portion of the screen is unreachable.

---

### H9: `filterToColorCodesOnly` on Visible Area Breaks Hyperlink/URL Sequences

**Likelihood: LOW-MEDIUM**

Modern terminal applications (like Claude Code) may emit OSC sequences for hyperlinks:
- `\e]8;;URL\e\\text\e]8;;\e\\` — hyperlink
- `\e]0;title\e\\` — set window title
- `\e]52;c;data\e\\` — clipboard operation

These are OSC (Operating System Command) sequences, not CSI. The `filterToColorCodesOnly` function doesn't handle them at all — it would skip the ESC, then output the `]` as literal text, corrupting the line.

**How it could cause garbled output:** Literal `]`, `8`, `;;`, URL text appearing as visible content would shift subsequent text positions.

---

### H10: UTF-8 Boundary Issues in Initial Capture's String Processing

**Likelihood: LOW-MEDIUM**

The initial capture processes content as Swift `String` (via `stdoutString`), which is valid UTF-8. But `capture-pane -e -p` may output bytes that form incomplete or unusual character sequences when escape codes are interspersed.

The `filterToColorCodesOnly` function iterates character-by-character through a Swift String. If `capture-pane` output contains raw bytes that Swift interprets as multi-byte characters spanning across escape sequence boundaries, the function could:
- Miss escape sequence starts (if ESC is consumed as part of a multi-byte char)
- Produce incorrect output

**Likelihood is lower** because `capture-pane -p` should output valid UTF-8.

---

### H11: Line Splitting with `omittingEmptySubsequences: false` Produces Extra Lines

**Likelihood: LOW-MEDIUM**

```swift
let visibleLines = visibleContent
    .split(separator: "\n", omittingEmptySubsequences: false)
    .map(String.init)
```

If `capture-pane` output ends with `\n` (which is trimmed on line 342-344) and there's content like `\n\n` mid-output, the split creates empty strings. These empty lines are output to the terminal:
```swift
output += "\u{1b}[2K" // Clear current line
output += filterToColorCodesOnly(line) // empty string
if index < linesToOutput - 1 {
    output += "\r\n"
}
```

This correctly outputs a cleared empty line, but the `lastMeaningfulLine` calculation (lines 353-362) might include or exclude lines incorrectly, especially around blank lines near the cursor position.

---

### H12: SGR State Carryover Between Lines

**Likelihood: MEDIUM**

Each scrollback line gets an explicit `\e[0m` reset before and after:
```swift
output += "\u{1b}[0m" + filtered + "\u{1b}[0m\r\n"
```

But the **visible area lines do NOT get resets**:
```swift
output += "\u{1b}[2K" + filterToColorCodesOnly(line)
```

If one visible line's SGR state carries over to the next line differently than `capture-pane` intended, colors could be wrong. The `capture-pane -e` output includes SGR codes within each line, but there's no guarantee each line starts with a reset. If `filterToColorCodesOnly` drops a non-SGR sequence that was interleaved with SGR codes, the resulting SGR state machine could be in a different state than intended.

**Example scenario:**
- tmux outputs: `\e[31m` (red) `\e[1A` (cursor up) `\e[32m` (green) text
- After filter: `\e[31m` `\e[32m` text
- The cursor-up was supposed to move to a different line before applying green, but without it, green applies to the current line

---

### H13: `\e[2K` (Clear Line) Before Content May Fight With SwiftTerm's Buffer State

**Likelihood: LOW**

The visible area rendering clears each line before writing:
```swift
output += "\u{1b}[2K" // Clear current line
output += filterToColorCodesOnly(line)
```

SwiftTerm processes `\e[2K` by clearing the entire current row. If the terminal's current cursor column isn't at position 0, the clearing happens but subsequent text still starts at the current cursor position (not column 0). The code doesn't explicitly move to column 0 before the content.

Wait — actually `\r\n` at the end of the previous line moves to column 0 of the next line. And the first line starts after `\e[H` which positions at (1,1). So column 0 should be correct. This is likely **not** an issue.

---

### H14: Race Condition in `readabilityHandler` → `processIncomingData`

**Likelihood: LOW-MEDIUM**

```swift
handle.readabilityHandler = { [weak self] handle in
    let data = handle.availableData
    guard !data.isEmpty else { return }
    Task { [weak self] in
        await self?.processIncomingData(data)
    }
}
```

`readabilityHandler` fires on a background thread, then dispatches to the actor's serial queue via `Task`. But multiple `readabilityHandler` calls can create multiple `Task`s that are enqueued **in order** but potentially processed with interleaving if the actor is busy.

Actually, since `TmuxControlClient` is an `actor`, `processIncomingData` calls are serialized. But `readabilityHandler` could fire rapidly, and the `Data` reads might lose atomicity — if the handler fires between `handle.availableData` calls of two concurrent handlers, data could be split at arbitrary boundaries.

The byte-level buffering (`byteBuffer`) handles this correctly for line-splitting, but it's worth verifying there's no reordering of tasks.

**Revised likelihood:** Low — actor serialization should handle this correctly.

---

### H15: The Batching Layer (TerminalStreamService) Introduces Ordering Issues for Remote Viewers

**Likelihood: MEDIUM (for iOS only)**

`TerminalStreamService` batches data with:
- 8KB max batch size
- 16ms fixed-cadence timer

The batching is simple append + flush, which preserves ordering. **But:** dimension change messages are sent **outside** the batching pipeline:
```swift
private func handleDimensionChange(paneId: String, width: Int, height: Int) async {
    let message = TerminalStreamMessage.dimensionChange(...)
    await streamSender.sendTerminalStream(message, to: subscribers)
}
```

If a dimension change arrives between data chunks, the iOS side might receive:
1. Data chunk 1 (for old dimensions)
2. Dimension change
3. Data chunk 2 (for new dimensions)

But if chunk 1 contained data that was generated *after* the dimension change (buffered), the iOS side applies old-dimension data at old dimensions, then resizes, then applies new data. The data in chunk 1 may have been rendered for the new dimensions already.

**How it could cause garbled output:** On the iOS side, cursor positions in batch 1 could exceed the old-dimension bounds, causing wrapping or clamping.

**Note:** This doesn't explain macOS mirror issues (no batching there).

---

### H16: SwiftTerm's Handling of `\e[2K` Followed by SGR-Only Content

**Likelihood: LOW**

After `\e[2K` clears a line, the cursor remains at its current position. If `filterToColorCodesOnly` outputs SGR codes that change background color before text, the cleared line may show the background color filling from the cursor to end-of-line. This could cause color "bleeding" across lines.

---

### H17: tmux `capture-pane -e` Output Differs From PTY Stream

**Likelihood: HIGH (root cause contributor)**

This is a fundamental architectural concern. `capture-pane -e -p` generates a **reconstruction** of the screen, not a replay of the original bytes. It:
- Outputs text content with SGR codes to recreate the visual appearance
- May re-encode colors differently than the original application output
- Inserts its own escape sequences for formatting

Meanwhile, `pipe-pane` (tmux-rec) captures the **original PTY bytes** — exactly what the application wrote.

The `%output` control mode events also provide original PTY bytes (what the pane's program outputs). So after the initial capture:
- Initial state: tmux's reconstruction (may differ from original)
- Live stream: original program bytes

This mismatch means the initial state may set up SwiftTerm's internal state (colors, cursor, modes) differently than the live stream expects, causing compounding errors.

---

## Proposed Testing Strategy

### E2E Test Design

Create a test that:
1. Sets up a tmux session with known dimensions
2. Sends a complex terminal output sequence (with cursor positioning, colors, alternate screen, etc.)
3. Captures the pane via `capture-pane -e -p` (ground truth)
4. Connects Ctrlx's streaming pipeline
5. Feeds the initial capture + subsequent `%output` events to a SwiftTerm instance
6. Compares SwiftTerm's buffer content with ground truth

**Specific test cases:**
- Cursor up/down/left/right within a single `%output` chunk
- SGR codes interleaved with cursor positioning
- Private mode sequences (synchronized output, alternate screen)
- Rapid redraws that involve `\e[H` (home) + full screen rewrites
- Content with `\e[2J` (clear screen) followed by `\e[H` and new content

### Replay Test Using tmux-rec Recording

Use the existing `.tmrec` recording to:
1. Replay the raw bytes into a SwiftTerm instance (ground truth)
2. Separately, process the same bytes through the Ctrlx pipeline:
   - Pass initial snapshot through `capturePaneWithScrollbackForStreaming`'s processing
   - Pass incremental data through `unescapeOutputBytes` + `filterTmuxEscapeSequences`
3. Compare terminal buffer state at key timestamps
4. If buffers differ, identify exactly which processing step introduced the discrepancy

---

## Recommended Investigation Order

1. **H1 + H2** (initial capture filtering) — Highest impact, most likely root cause
2. **H17** (capture-pane vs PTY byte mismatch) — Architectural concern
3. **H5** (timing gap) — Could explain intermittent issues
4. **H3 + H8** (dimension mismatch) — Window sizing differences
5. **H7** (private mode state) — Terminal mode initialization
6. **H12** (SGR state carryover) — Color issues specifically
7. **H6** (octal unescaping) — Data corruption in live stream
8. **H9** (OSC sequences) — If Claude Code uses hyperlinks

## Quick Diagnostic Experiment

Before diving into code changes, a simple diagnostic:
1. Record the session with tmux-rec (already done)
2. At a point where garbling is visible, also run `tmux capture-pane -e -p` on the same pane
3. Feed ONLY the `capture-pane` output (unmodified) to a fresh SwiftTerm — does it look correct?
4. Feed the `capture-pane` output through `filterToColorCodesOnly` to SwiftTerm — does garbling appear?
5. If yes → H1/H2 confirmed
6. If no → the issue is in the live stream processing, focus on H5-H7

This would isolate whether the problem is in initial capture processing or live stream handling.

---

## Test Results (TerminalRenderingTests.swift + TmuxControlClientTests.swift)

69 tests across 19 suites. **All 69 passing** after fixes.

### All Tests Passing

| Hypothesis | Test | Status |
|-----------|------|--------|
| **H1** | 6 basic filter tests | Pass — `filterToColorCodesOnly` correctly preserves SGR, strips CSI cursor/erase/mode |
| **H2** | `nonCSIDoesNotLeakBytes` | Pass (was failing) — charset selection bytes no longer leak |
| **H2** | `vt100GraphicsCharsetDoesNotLeak` | Pass (was failing) — `\e)0` fully consumed |
| **H2** | `multipleNonCSIDontAccumulate` | Pass (was failing) — multiple non-CSI escapes handled correctly |
| **H9** | `oscDoesNotLeakContent` | Pass (was failing) — OSC payload no longer leaks as text |
| **H3/H8** | `absoluteCursorClampedToTerminalSize` | Pass (was failing) — cursor clamped to last row |
| **H3/H8** | `relativeCursorAfterClamping` | Pass (was failing) — relative movements consistent from clamped position |
| **H7** | `syncUpdatePattern` | Pass — synchronized output renders correctly |
| **H12** | `sgrStateLeaksBetweenLines` | Pass — visible area SGR carryover confirmed |
| **H17** | `sgrStatePreservedAfterCapture` | Pass (was failing) — SGR state restored after capture reconstruction |
| **Integration** | `inputAreaRedrawMatchingDimensions` | Pass — redraw correct when dimensions match |
| **Integration** | `inputAreaRedrawWithMismatch` | Pass (was failing) — redraw correct with clamped cursor |
| **Integration** | `fullScreenRedraw` | Pass — EraseDisplay + CursorHome works |
| **Integration** | `accumulatedCursorDrift` | Pass — 50 cycles of relative Up/Down stays correct |
| **Pipeline** | `filterThenLiveStream` | Pass — filter + live stream matches unfiltered for SGR-only content |

### Key Conclusions

1. **H2 was a definite bug** that corrupted output by leaking stray bytes from non-CSI escape sequences. **Fixed** by properly skipping charset selections (3 bytes) and standard non-CSI escapes (2 bytes).

2. **H3/H8 (dimension mismatch)** was the most likely root cause of the "garbling worsens over time" observation. When the mirror terminal has fewer rows than the tmux pane, cursor positions were unclamped, and all relative cursor movements operated from wrong positions. **Fixed** by clamping cursor to `min(cursorY, linesToOutput - 1)`.

3. **H9 (OSC leaks)** contributed to corruption — OSC title-setting sequences (`\e]0;Title\a`) leaked their content as literal text. **Fixed** by adding OSC sequence handling that consumes bytes until BEL or ST terminator.

4. **H17 (capture-pane vs raw SGR state)** explained color mismatches: the initial capture's `\e[0m` resets left SwiftTerm in a different SGR state than the live stream expected. **Fixed** by adding `extractActiveSGR` helper that walks visible lines to the cursor position and re-emits the active SGR code after cursor positioning.

5. **H12 (SGR carryover)** is a secondary color issue — visible area lines inherit SGR state from previous lines without explicit resets. Not yet addressed; may be mitigated by the H17 fix for the re-capture path.

---

## Resolution

### Fixes Applied (TmuxService.swift)

All production fixes are in `CtrlxPackage/Sources/CtrlxServerFeature/Services/TmuxService.swift`.

#### H2: Non-CSI escape byte leaking → Fixed

The `else` branch in `filterToColorCodesOnly` only skipped the ESC byte, leaking the following byte(s) as literal text. Now properly handles:
- **Charset selections** (`ESC ( X`, `ESC ) X`, `ESC * X`, `ESC + X`) — skips 3 bytes
- **Standard non-CSI escapes** (`ESC X`) — skips 2 bytes

#### H9: OSC sequence leaking → Fixed

Added a new `else if input[nextIndex] == "]"` branch in `filterToColorCodesOnly` that consumes OSC sequences (`ESC ] ... BEL` or `ESC ] ... ESC \`) in their entirety. Handles both BEL and ST terminators, plus unterminated sequences.

#### H3/H8: Cursor position out of bounds → Fixed

In `capturePaneWithScrollbackForStreaming`, the cursor Y position is now clamped:
```swift
let effectiveCursorY = min(cursorY, linesToOutput - 1)
```
This prevents sending `\e[Y;XH` with Y beyond the output content, which previously caused relative cursor movements from live stream data to operate from wrong positions.

#### H17: SGR state lost after capture → Fixed

Added `extractActiveSGR(from:cursorX:cursorY:)` method that walks the unfiltered visible lines up to the cursor position, tracking SGR state changes. After cursor positioning in the capture output, the active SGR code is re-emitted. The method stops scanning at the cursor column to avoid processing trailing `\e[0m` resets that tmux appends per line.

#### H5: Timing gap between capture and stream → Fixed

Rewrote `PaneStream.connect()` to route capture commands through the control client's `sendCommand()` instead of subprocesses. Since commands and `%output` events are serialized in the same control mode stream, the capture results are precisely ordered relative to live data — no gap, no overlap.

Key changes across four files:
- **TmuxControlClient.swift**: Added per-pane buffering (`startPaneBuffering`/`stopPaneBuffering`) that silently discards `%output` events during capture, plus FIFO command queue and initial attach response skipping
- **TmuxControlClientManager.swift**: Pass-through methods for `sendCommand`, `startPaneBuffering`, `stopPaneBuffering`
- **TmuxService.swift**: Extracted `processCapturePaneForStreaming` as a pure method, added `capturePaneViaControlMode` that sends capture commands through control mode
- **PaneStream.swift**: New ordering: buffer → register → capture via control mode → unbuffer

#### Cursor off-by-one on re-attach → Fixed

Two bugs caused typed text to appear one row above the correct position after re-attaching to a Claude Code session:

**Bug 1: `capture-pane` trims trailing empty lines.** When the cursor sits on an empty row (common in Claude Code where the cursor is at the very bottom of the pane), the capture returns fewer lines than the pane height. The old code used `min(lastMeaningfulLine, visibleLines.count)` for `linesToOutput`, which clamped the cursor to the last captured line instead of the actual cursor row. **Fixed** by using `max(cursorY + 1, visibleLines.count)` and padding with blank `\e[2K` lines beyond the captured content.

**Bug 2: Mirror terminal rows derived from window height instead of tmux pane height.** The mirror's SwiftTerm terminal had rows calculated from the container's physical height (e.g., 24 rows in a small window), while the tmux pane had 37 rows. Absolute cursor positioning in live `%output` events (e.g., `\e[33;1H`) referenced row numbers that didn't exist in the smaller mirror, getting clamped to the wrong position. **Fixed** in `TerminalContainerView.swift` by locking mirror rows to the tmux pane height via `updateTerminalDimensions(cols:rows:)`. Also switched the initial capture to use relative cursor positioning (`\e[nA` + `\e[nG`) instead of absolute (`\e[Y;XH`).

#### H12: Multi-row background band loses its background on re-capture → Fixed (#578)

A Codex composer's full-width gray background band rendered correctly on first view but lost the background on its continuation rows after navigating away and back. `tmux capture-pane -e` (without `-N`) **trims trailing spaces**, so a multi-row band — drawn with the `\e[48;5;…m` setter on its first row only and carrying the bg across rows via tmux's cross-line SGR state — captured as a setter followed by *empty* continuation rows, byte-identical to genuinely-blank rows. `processCapturePaneForStreaming` rebuilt each row independently with an SGR reset between rows, so the continuation rows rendered black. (The first view is correct because the band is painted by the live byte stream; re-viewing rebuilds from `capture-pane`.)

**Fixed** by capturing the visible area with `-N` (preserve trailing spaces without `-J`'s wrapped-line joining) so continuation rows keep their real bg spaces, and restoring the SGR state carried into each rebuilt row (`accumulateSGRState`) so those spaces inherit the band's background. Empty rows skip the carry, so genuinely-default rows stay default and the #411 leak does not return. The old pad-to-width heuristic (PR #353/#413, issue #429) is removed — `-N` supplies the real trailing cells, so only genuine band rows are full-width. Proven by the `Composer Band Recapture` E2E scenario (full gray band with the fix; continuation rows black without it).

#### H12 follow-up: same fix extended to the scrollback capture → Fixed (#580)

The #578 fix above applied `-N` + cross-line SGR carry to the **visible-area** capture only; the **scrollback** capture was left on plain `-e` and Part 1 of `processCapturePaneForStreaming` still reset the SGR state per line. A multi-row background band that has *scrolled into history* therefore lost its background on its continuation rows in exactly the same way (band setter on the first row only, continuation rows captured as empty/short and rebuilt with a per-line reset).

**Fixed** by applying `-N` to the scrollback capture too (both `capturePaneWithScrollbackForStreaming` and `capturePaneViaControlMode`) and carrying the SGR state across scrollback rows in Part 1, mirroring Part 2. The one extra concern unique to scrollback is reflow permanence: the visible area is redrawn on the resize SIGWINCH, but scrollback is static history that is never redrawn, so a preserved full-width row of *default*-bg spaces would wrap into **permanent** blank continuation rows on a narrower resize (the #429 class, but permanent). `trimTrailingDefaultBackgroundSpaces` drops the now-preserved default-bg trailing spaces back off plain rows (keeping a band's non-default-bg spaces) so plain rows stay short and SwiftTerm's reflow trims their NULL tail. Proven by the `Scrollback Band Recapture` E2E scenario and unit tests `multiRowBackgroundBandSurvivesInScrollback` (band keeps its bg in the scrollback buffer) and `scrollbackNoBlankRowsAfterReflowNarrower` (no reflow blanks after a narrower resize).

### Test Results Update

69 tests across 19 suites. **All 69 passing** after fixes.

New tests added:
- Per-pane buffering state management (start/stop/cleanup)
- `processCapturePaneForStreaming` with nil scrollback, trailing newlines, cursor position
- Dimension mismatch: 37-row tmux output fed to 24-row SwiftTerm terminal
- Live typing and cursor-up movement after initial capture with cursor mid-screen
- Cursor beyond visible lines pads output to reach cursor row

### Remaining Issues

- **~~H12 (SGR carryover between visible lines)~~**: Resolved (#578, extended to scrollback in #580). The rebuild captures both the visible area and the scrollback with `-N` and restores the cross-line SGR state carried into each row, so multi-row background bands keep their background on continuation rows whether they are on screen or have scrolled into history. See the two H12 fix entries above.
- **Scrollback corruption after re-capture**: Documented in the E2E scenario (Phase 2). Re-capture replaces the mirror's accumulated scrollback with tmux's captured content, causing duplication/truncation/reordering. This is a separate architectural issue.
- **~~H6 (octal unescaping)~~**: No longer applicable — pipe-pane delivers raw bytes, no octal unescaping needed.
- **H7 (private modes)**: Not yet investigated with targeted tests. May contribute to edge cases.
- **~~Truecolor animation rendering artifacts (Test 16)~~**: Resolved by pipe-pane rewrite (PR #179). See section below for historical investigation.

---

## Investigation: Truecolor Animation Rendering Artifacts (Test 16)

> **RESOLVED (PR #179):** The pipe-pane rewrite eliminated these artifacts entirely. The root cause was the `%output` processing pipeline (octal unescaping, line-boundary splitting, per-callback `Task {}` reordering). By delivering raw PTY bytes via FIFO with AsyncStream ordering guarantees, all truecolor rendering artifacts were eliminated. A regression E2E test (`TruecolorRenderingScenario`) runs 5 gradient animation variants with 0.00% diff baselines.

### Problem Statement

Test 16 of `terminal-debug/term-stress.py` (Synchronized Output / Mode 2026) produces rendering artifacts in the Ctrlx mirror window:
- Gradient extends beyond the intended 50-column bounds
- Literal escape sequence parameters (e.g., `m`, `2;5H`) appear as visible text
- Colored blocks appear beyond the gradient area
- Artifacts appear in **both** "Without synchronized output" and "With synchronized output" sections
- Artifacts are intermittent — frequency varies, sometimes appearing on the first frame, sometimes after several

### Investigation Timeline

Three debugging sessions systematically eliminated suspects. Key finding: **the data pipeline is clean and SwiftTerm's buffer contains correct data, but rendering output is wrong.**

### Proven Facts

1. **Data pipeline delivers complete, well-formed frames.** Feed logging at the SwiftTerm boundary showed 158/160 feeds with complete truecolor frames (250 background sequences per animation frame), zero split escape sequences.

2. **SwiftTerm's terminal buffer is correct after feeding.** Buffer dumps performed immediately after `feed()` calls show the exact expected content — correct characters at correct positions with correct attributes.

3. **The issue is in SwiftTerm's draw/display pipeline or AppKit compositing.** Since buffer contents are correct but rendered output shows artifacts, the bug is between the terminal buffer and what appears on screen.

### What Was Tried and Eliminated

All fixes below were tested experimentally but **none resolved the artifacts**. They are documented here as eliminated causes — the code changes were not merged.

#### 1. TCP Read Splitting → Escape Sequence Fragmentation (IDENTIFIED, FIX DID NOT RESOLVE ARTIFACTS)

**Discovery:** The pipe's `readabilityHandler` delivers data in ~1024-byte chunks, each creating a separate `Task` on the `TmuxControlClient` actor. Animation frames are ~4,500 bytes (3-5 TCP reads), so a single frame's data arrives across multiple Tasks. Without coalescing, escape sequences get split at arbitrary 1024-byte boundaries.

**Evidence:** Feed logging showed ~70 out of 500 feeds with `STARTS_DIGIT!` flag — feeds beginning with digits like `4;50;41m` (middle of a CSI sequence). Many feeds were exactly 1024 bytes — the TCP read buffer size.

**Attempted fix:** Per-pane output accumulator in `TmuxControlClient` with generation counter + 2ms delay coalescing. Each `processIncomingData` increments a counter; a scheduled flush only fires if the counter hasn't changed after sleeping, ensuring all TCP reads from the same burst are coalesced into a single delivery.

**Result:** Effectively eliminated frame splitting (158/160 complete frames, zero `STARTS_DIGIT` entries). But **artifacts persisted**, proving TCP read splitting is not the sole cause. The coalescing approach is sound and worth implementing, but does not fix the rendering issue.

**Key insight on actor Task scheduling:** Swift actor task scheduling does NOT guarantee strict FIFO ordering between independently-created Tasks. A "flush" Task created by `processIncomingData` can execute BEFORE the next `processIncomingData` Task, even though the next TCP read was already queued by `readabilityHandler`. `Task.cancel()` based coalescing is unreliable because the flush Task may already be executing. The generation counter + delay approach is the only reliable method found.

#### 2. `needsLayout = true` After Every Feed (IDENTIFIED, FIX DID NOT RESOLVE ARTIFACTS)

**Discovery:** `InteractiveTerminalView` was calling `needsLayout = true` after every `feed()` call and in the `rangeChanged` delegate callback. This triggered `layout()` → `terminalView.frame.size.height = bounds.height` → unnecessary AppKit display invalidation, creating a layout cascade that interfered with SwiftTerm's incremental display updates.

**Attempted fix:**
- Changed `feed()` and `feedPreservingScroll()` to use `terminalView.needsDisplay = true` instead of `needsLayout = true`
- Changed `rangeChanged` delegate to no-op (was triggering layout cascade on every data update)
- Added guard in `layout()`: only assign `terminalView.frame.size.height` when it differs from `bounds.height`

**Result:** Cleaner display cycle, but **artifacts persisted**.

#### 3. Full-View `needsDisplay = true` (TESTED, DID NOT HELP)

Setting `terminalView.needsDisplay = true` after every feed should force a full-view redraw rather than SwiftTerm's partial dirty rect approach. **Artifacts persisted.**

#### 4. Synchronous `displayIfNeeded()` (TESTED, DID NOT HELP)

Calling `terminalView.displayIfNeeded()` immediately after `needsDisplay = true` forces an immediate synchronous draw, eliminating any timing issues between feed and display. **Artifacts persisted.** This proves the issue is NOT about AppKit display cycle timing or deferred rendering.

#### 5. Flush Per TCP Read (TESTED, MADE THINGS WORSE)

Removing the timer-based coalescing and flushing at the end of each `processIncomingData` call delivered each ~1024-byte TCP read as a separate feed to SwiftTerm. **Artifacts were worse** — more frequent and more severe.

#### 6. `feedPreservingScroll()` Scroll Position Restoration (TESTED, NOT THE CAUSE)

`feedPreservingScroll()` captures scroll position before feed and restores it after via `scroll(toPosition:)`. Hypothesis: this shifts `yDisp`, causing row position miscalculations in `drawTerminalContents`. Tested by bypassing to simple `feed()` path. **Artifacts appeared on first try.** Scroll preservation is NOT the cause.

### SwiftTerm Rendering Pipeline Analysis (macOS)

Deep analysis of SwiftTerm's macOS rendering path revealed several architectural details:

```
feed() → feedPrepare() → terminal.feed(buffer:) → feedFinish()
  → queuePendingDisplay()
    → DispatchQueue.main.asyncAfter(.now() + 1/60) [16.67ms]
      → updateDisplay()
        → terminal.getUpdateRange() → clearUpdateRange()
        → setNeedsDisplay(partialRegion)  ← PARTIAL dirty rect (macOS only)
          → drawTerminalContents()
            → firstRow = displayBuffer.yDisp + Int((boundsMaxY - dirtyRect.maxY) / cellHeight)
            → loop over dirty rows, build attributed strings, draw backgrounds, draw text
```

**Key differences between macOS and iOS:**
- **macOS:** `updateDisplay()` calculates a partial `CGRect` covering only changed rows → `setNeedsDisplay(region)`
- **iOS:** `updateDisplay()` uses `setNeedsDisplay(bounds)` — always full redraw
- **macOS:** `startDisplayUpdates()` / `suspendDisplayUpdates()` are no-ops
- **iOS:** These control CADisplayLink

**`drawTerminalContents` row calculation:**
```swift
firstRow = displayBuffer.yDisp + Int((boundsMaxY - dirtyRect.maxY) / cellHeight)
```
This derives which terminal buffer rows to draw from the dirty rect's pixel coordinates. If `cellHeight` has fractional components or the dirty rect doesn't align perfectly with cell boundaries, row selection could be off.

**`Terminal.resize()` interaction:**
- Calls `refresh(0, rows-1)` to mark all rows dirty
- Does NOT call `clearUpdateRange()` — so a resize during animation could accumulate update ranges from different dimension states

### Remaining Suspects (Not Yet Tested)

These are the areas NOT yet eliminated that could explain why artifacts persist despite clean data:

#### A. SwiftTerm's `drawTerminalContents()` rendering bug

The drawing function converts dirty rects to buffer row ranges using floating-point division. With truecolor animation producing rapid full-screen updates:
- Fractional `cellHeight` could cause row misalignment in `firstRow` calculation
- The `yDisp` offset (scroll position in buffer) combined with partial dirty rects could select wrong rows
- Background color fill pass and text drawing pass might use slightly different row calculations

#### B. AppKit layer compositing with `wantsLayer = true` / `masksToBounds = true`

`InteractiveTerminalView` sets `wantsLayer = true` and `layer?.masksToBounds = true`. The terminal view is wider than its container (e.g., 227 columns at full tmux width) and relies on clipping:
- Layer-backed views use different compositing paths than non-layer views
- `masksToBounds` clips the rendered content but doesn't prevent the terminal from drawing beyond bounds
- Rapid partial redraws of a view wider than its layer could cause compositing artifacts

#### C. Terminal view wider than container

The SwiftTerm TerminalView is sized to fit all columns (e.g., 227 columns), which is wider than the visible window. `InteractiveTerminalView` provides horizontal scrolling. The dirty rect calculations in `drawTerminalContents` may not account for the view being partially off-screen, causing incorrect row/column mapping when the view extends beyond the visible area.

#### D. External resize events during animation

`Terminal.resize()` calls `refresh(0, rows-1)` without clearing the update range. If a resize event arrives during animation (e.g., from `updateContainerSize`), it could accumulate dirty ranges from different dimension states, confusing the partial dirty rect calculation in `updateDisplay()`.

### Suggested Next Steps

1. **Test without InteractiveTerminalView wrapper**: Use SwiftTerm's `TerminalView` directly (no horizontal scrolling, no layer masking) to see if artifacts disappear. This isolates the wrapper/layer setup.

2. **Test with a smaller terminal size**: If the terminal is 80 columns (fits in window without scrolling), the wider-than-container scenario is eliminated.

3. **Test without `wantsLayer`/`masksToBounds`**: Remove layer backing on InteractiveTerminalView to test if AppKit compositing is the issue.

4. **Test with iOS-style full-bounds redraw**: Override SwiftTerm's macOS `updateDisplay` to use `setNeedsDisplay(bounds)` instead of partial regions, matching iOS behavior.

5. **Instrument `drawTerminalContents`**: Add logging to capture the `firstRow`/`lastRow` calculation from dirty rects and compare against expected rows for each frame.

### Diagnostic Techniques Used

These approaches were used during the investigation and can be re-created if needed:

- **Feed logging**: Logging every `feed()` call to `/tmp/ctrlx-feeds.txt` with size, first/last bytes, truecolor BG count, bare CSI parameter detection, and starts-with-digit detection. Add to `TerminalContainerView.Coordinator.handleData`.
- **Frame capture**: Binary capture of all frames fed to SwiftTerm to `/tmp/ctrlx-frames.bin` with 4-byte little-endian length prefix per frame. Enables offline replay and analysis.
- **Frame replay**: `terminal-debug/replay-frames.py` replays captured binary frames in a real terminal for visual comparison against the mirror window.
- **Buffer dump**: Direct SwiftTerm buffer content extraction immediately after `feed()` calls, comparing buffer state against expected content. Confirms whether data reaches the terminal buffer correctly.
