# Agent Browser (development integration — not release-ready)

Mac **Settings → Browser → New Browser → Engine** selects **Chromium** (default)
or **WebKit** for explicit New Browser actions. Chromium uses the same sandboxed
CEF runtime as Agent Browser, embedded as native child views in CtrlX's same
session tab strip and left/right split layout. No standalone browser window, no
ChatGPT extension, MCP server or browser-wide TCP debugging port is involved.
Apple Silicon only for the native Host runtime.

This device-local setting affects new human-created local tabs only. New Browser
in a Mac Viewer session now creates a Chromium page on the Host. Existing
tabs, restored WebKit tabs, terminal-link rules and Codex automation are unchanged;
it is unrelated to the `vercel` / `ctrlx` automation-backend selection. iOS has no
corresponding setting. Chromium tabs share CtrlX's dedicated Chromium profile and
logins, not WebKit's or system Chrome's. Chromium tabs remain transient and are
not restored after restarting CtrlX; WebKit layout restoration is unchanged.
If the native runtime is unavailable, creation reports an error instead of
silently substituting WebKit.

Regression coverage: `NewBrowserEngineTests` checks preferences, explicit local /
Viewer destinations, rename-safe child routing, errors and workspace cleanup;
`LayoutSnapshotMapperTests` protects existing WebKit restoration. Native
`tests/ownership.cc` rejects empty-owner human tabs. The isolated signed Mac UI
check also covers Chromium navigation/input, popup creation and shared test
cookies, switching the setting to WebKit, both engines side by side without
reloading existing pages, right-side popup inheritance and normal shutdown.

Release preparation for 3.0.41 also passed brand/technical boundary checks,
10 publisher regressions, the website build and the unsigned iOS device-target
compile check (no simulator or device installation). The full Swift run completed
2,217 passing tests; the same two `StopFinalityEvaluations` tests as 3.0.40 failed
because Apple Intelligence reports `deviceNotEligible` on this Mac. This is not
an all-green full-suite result. Logs: `/tmp/ctrlx-3.0.41-unit-tests.log`,
`/tmp/ctrlx-3.0.41-ios-compile.log`, `/tmp/ctrlx-3.0.41-website-build.log`.

Future product features, capability expansion/testing and optional external-browser
access are tracked in the [Agent Browser TODO](agent-browser-todo.md), with per-item
implementation status. Verified public capabilities and remaining limits are in
the [capability audit](agent-browser-capability-audit.md).

## Embedded routing

Open CtrlX on the **same Mac** as the terminal agent. Start `codex` normally;
there is no `ctrlx browser run` requirement. On `browser action open`, the CLI
identifies the real Codex process. The host resolves its fresh process ancestry
to a tmux pane/window/session, then inserts a Chromium tab in that workbench.
It does not infer the destination from the focused session, working directory,
or an inherited session-name environment variable. Missing/ambiguous sources
(including a pane linked into multiple sessions) fail without opening a window.
Routing reads pane metadata and shell PIDs in one live tmux query; it does not
reuse the UI refresh cache, which may still be loading or have deduplicated
linked sessions. The process tree is then matched against that live snapshot.

The control owner is the **Codex process instance**; the display location is the
**source session and split side**. Multiple agents in one session share its tab
strip, not control grants. Children inherit their opener's owner and location.
Switching tabs reparents the existing native view; it does not reload Chromium.
Transient Chromium tabs are excluded from WKWebView layout persistence. Browser
tabs are available to paired Mac/iOS Viewers through the typed remote surface below.

The host initializes CEF before use, then enters `CefRunMessageLoop` from a
deferred AppKit RunLoop callback, never a Swift serial main-actor job. CEF's
native macOS loop continues to dispatch AppKit events and RunLoop sources and
holds Chromium's application keep-alive. The old external timer pump missed that
keep-alive: closing the last Chrome-style DevTools window could start global
renderer fast shutdown even though Alloy page tabs were still open.
Browser creation resumes on CEF's loop after async process discovery. Closing a
tab detaches only that native child, never CtrlX's parent NSWindow. Shutdown waits
for page/tools close callbacks, transports and the cookie store's asynchronous
flush completion, then calls `CefQuitMessageLoop`. Only after the loop returns
does it call `CefShutdown`. This uses CEF's
[FlushStore completion contract](https://cef-builds.spotifycdn.com/docs/125.0/classCefCookieManager.html),
not a fixed sleep or disabled cookie encryption.

Host workspace unregistration retires its UI representations, then parks the same
native views in an off-screen NSWindow. Pages remain alive for Viewers and are
adopted again when the matching workspace opens. Existing Viewer-local pages
retain their old close-on-workspace-disposal behavior. Explicit tab close still
closes the native page; quitting CtrlX closes all pages. For local installation
acceptance, verify the running process's loaded executable and dylib paths/inodes
as well as bundle hashes; replacing the App on disk does not replace a library
already mapped by an older process.

## Viewer browser surface

Mac Viewer tabs marked **Host** and iOS **Tabs → Browsers on Host** show the same
Host Chromium pages, including manual, Agent and popup tabs. New Browser on Host
creates an ownerless human page in that session. Existing Viewer-local tabs are
marked **Local** and are not migrated. WebKit remains device-local. Page DOM,
login state, local network access and localhost resolution all stay on the Host;
the Viewer does not load a second copy of the URL or receive browser credentials.

- `supportsBrowserSharing` and optional tab metadata extend session snapshots.
  Older Hosts reject the feature locally before any new command enum is sent.
  `BrowseBrowser` operations and frame replies use the existing paired E2EE
  command channel; the opaque Relay requires no browser-specific deployment.
- The native surface exposes only bounded capture/navigation/input operations,
  never a raw remote CDP/JavaScript gateway. There is at most one outstanding
  frame per visible surface, a 180 ms delay between replies, JPEG quality 50,
  a 1024-pixel longest side and a 180 KiB encoded-image budget. Four captures
  globally and four requests per Viewer bound work. Congested terminal output
  pauses new captures; this is interactive page sharing, not a video stream.
  Capture uses the existing render surface without CDP `clip`/scale, which would
  temporarily resize the live Host renderer on every frame. ImageIO generates
  the bounded JPEG on a CEF worker; unscaled screenshots stay on the Host (8 MiB
  private response limit, 64-megapixel image limit). Concurrent requests for the
  same tab coalesce, with at most four waiting replies. Frame CSS dimensions cover
  the full captured image, including scrollbars: the paired CDP physical/CSS
  viewport ratio and pinch scale convert source pixels before JPEG downscaling.
  Input coordinates remain independent of thumbnail pixels. Navigation/resize/
  close invalidates pending results, and shutdown waits for image workers.
- Selection is per Viewer. Agent-created tabs do not steal Viewer focus.
  Disappearing/background surfaces stop polling and release control; they do not
  close the Host page. Only explicit Close closes it.
- Agent pages start read-only. **Take Control** acquires one lease per page;
  another surface/Viewer cannot steal it. Manual pages attempt acquisition on
  first display. **Return to Agent / Release Control**, Host **Take Back**,
  disconnect or a 20-second lease expiry release it (expiry checked every 5 s).
  Acquisition refuses in-flight Agent work/recording. Both CLI backends,
  including existing Vercel gateway attachments, reject commands during handoff.
  The Host page blocks direct keyboard/pointer input until Take Back.
- Viewers scale the existing viewport by default. **Fit to This Device** is an
  explicit shared Host viewport change. Inputs carry the last displayed page /
  geometry generation and an exact surface/control identity. Stale inputs fail,
  never replay. Input is ordered, bounded to 32 queued items, with consecutive
  moves/wheel deltas coalesced. Losing the lease cancels the input task and clears
  the queue; retaking control never promotes old input to the new lease.
  Transport failure releases control.
- Mac uses native IME composition; iOS commits UITextView composition before
  sending text, with explicit Keyboard and Paste buttons. One finger scrolls;
  two fingers drag. System/CEF popup UI, file chooser, remote clipboard reads,
  remote audio/video streaming and remote DevTools are not included.

Validation scope and outstanding physical-device acceptance are tracked in
[`v3.0.52/STAGE1_TODO.md`](v3.0.52/STAGE1_TODO.md). Native acceptance:
`tests/remote_browser.py <isolated-app> <engine> <codex-fixture>` after
`tests/prepare_upstream_probe.sh`; uses a per-test API socket/profile and fixture
processes, **not real Codex or an end-to-end iPhone UI test**.
The native test calibrates transient child-view resize detection against the old
clipped screenshot path, then checks continuous visible capture, shared concurrent
frames, background capture and remote input. It also forces both scrollbars and
clicks a target located from the JPEG through the Viewer coordinate mapping,
including browser zoom, pinch zoom and Fit. Image-only regression is available
without launching CEF: build the CMake `remote_browser_frame_tests` target and run
`.build-local/agent-browser/remote_browser_frame_tests` (invalid/oversized sources,
landscape/portrait/no-upscale JPEG output, full-image CSS dimensions and the
180 KiB bound).

## Ownership and data

- One persistent, CtrlX-specific profile per Mac:
  `~/Library/Application Support/CtrlX/AgentBrowser/Default`.
- On first browser use, one Codex process gets a fresh random control identity;
  session/window/pane labels are display hints, not credentials.
- Start Codex normally, including by typing `codex` in an existing terminal.
  `ctrlx browser action` walks its kernel process ancestry to the nearest native
  `codex` executable. Shells and `codex-code-mode-host` are not agent identities.
  Existing Codex instances attach on first use without restarting. A bounded
  ancestry walk fails closed if identity is unavailable; it never uses focus,
  tmux pane labels, or `CTRLX_BROWSER_CONTEXT` as credentials.
- Contexts live privately in `~/.ctrlx/agent-browser/runs/<pid>-<start-time>/`.
  Their random credentials and initial registration are protected by a file lock,
  so concurrent tools reuse one group. Nested/sibling Codex instances are separate;
  PID reuse cannot inherit a prior identity. Shared profile/login is unchanged.
  `ctrlx browser identity` diagnoses the owner without opening a browser or
  printing credentials. `browser run` remains only an optional exec convenience;
  CtrlX project launches no longer wrap or alter the user's Codex command.
- The local socket checks its peer UID and requires the runtime secret, browser
  epoch, PID/start time and exact tab ownership for operations. There is no
  focused-tab fallback. Same-user processes are trusted; groups are routing
  isolation, not a security sandbox against malicious software under that UID.
- Login cookies/site storage are shared across groups. Account changes and
  logout therefore affect other groups. System Chrome's profile is never used.
- Human-created Chromium tabs carry an explicit workspace/session/viewer-host
  route and an empty control owner. They are not exposed to agents through this
  protocol, even when opened in an agent's session; neither focus nor a shared
  profile grants control. WebKit tabs remain outside the protocol as well. The
  embedded UI does not offer ownership transfers. Child tabs inherit their
  parent's owner and exact display route (including human-only ownership).
- Page input actions reveal and focus their explicitly authorized native tab before
  dispatching real input. They never use the currently selected tab as a target.
- Agent exit revokes its authority but retains pages. Browser restart invalidates
  old grants. This iteration does not restore the old tab layout after restart.

## Bounded page actions

The original engine remains explicitly selectable and retains this contract. The
default managed Vercel backend adds a scoped local WebSocket transport and accessibility
snapshots; see [dual engines](agent-browser-engines.md) for selection and limits.

The original engine provides 15 operations: tabs/open/read/click/type/fill/press/
scroll/wait/select/check/screenshot/navigate/show/close. The Vercel adapter adds
`snapshot` (16 stable `action` operations). The separate `browser command --tab ID -- …`
entry now exposes a bounded catalog of Vercel page capabilities including eval,
files, network events and same-origin frames; see [dual engines](agent-browser-engines.md).
Both entries reuse the exact-tab, live-runtime ownership check. Raw CDP and
browser-wide control remain private; runtime secrets, epoch and process identity
stay in the native bridge. The following details describe the original action contract.

- `fill --selector … --text …` replaces a normal text input or textarea;
  an empty value clears it. `type` still inserts. Neither submits implicitly.
- `press --key …` sends native CDP key-down/key-up to page focus, optionally
  focusing a unique `--selector` first. Supports navigation/editing keys and
  modifiers, including Shift+Tab and Meta+A; clipboard/browser shortcuts and
  arbitrary printable key strings are rejected.
- `read` accepts an optional root selector, text and control offsets/limits.
  Responses expose next offsets, ordinary form values, checked/disabled/readonly/
  focus state and native select options. The existing `controls` list also
  includes readable/named targets (`kind: region`) and scroll extents, so agents
  can discover selectors for result-text waits and nested scrolling without
  inventing them. Password/file/hidden values are omitted.
  Text/control pages cap at 20000/100, individual values at 2000 characters and
  option lists at 100; truncation is explicit. This is not a full DOM or AX dump.
- `scroll --delta-y … [--delta-x …]` scrolls the page or a specified container
  by CSS pixels (±10000); returns actual position, extents and whether it moved.
- `wait` polls every 100 ms without blocking the native UI. Default is page
  ready or selector visible; attached/hidden/enabled and text conditions are
  also supported. Deadline defaults to 5 seconds and caps at 10. It follows
  navigation of the same owned tab and rejects old-document results. Other
  actions retain navigation cancellation; no mutation is automatically retried.
  The first probe is immediate, including at the 100 ms minimum timeout, and a
  native deadline remains effective even if the renderer stops responding.
- `select` sets an exact enabled option value on a native single-select and
  emits synthetic input/change events (not trusted OS popup interaction).
- `check` sets native checkbox/radio state with a real CDP click, verifies the
  result and returns `changed: false` if already correct. It never blindly
  toggles; clearing a radio or ambiguous indeterminate state is rejected.

Actions serialize per tab. Other tabs can operate while a wait is pending;
closing a tab, exiting the owning agent or losing the renderer cancels the wait.
For the original engine, cross-origin frames, rich text editors, uploads/downloads and debugging remain
outside this increment. Use human interaction for unsupported widgets.

## Human developer tools

The wrench button at the right of an **Agent Browser** tab's address bar opens
CEF's native Developer Tools for that exact page. It is a separate tools window
inside the same CtrlX application, not another browser app or a WebKit tab.
Repeated clicks focus the existing tools window. Closing the tools preserves
the page; closing the page or quitting CtrlX also disposes its tools.
Navigation keeps the inspector attached to the same page tab.

This is an explicit local, human debugging entry point (DOM/CSS, Console,
Network), not an expansion of agent authority. DevTools use a dedicated CEF
client and are never added to the agent tab registry or restored as ordinary
tabs. Creation runs on CEF's native loop; shutdown waits for tools and pending
creation as well as page browsers. Human-created Chromium tabs use the same
inspector; WebKit's existing inspector behavior is unchanged.

There is no new HTTP/WebSocket debugging listener and no system-browser launch.
The upstream CLI `inspect`, `stream`, and `dashboard` commands remain unavailable;
managed-engine streaming remains disabled. Remote browser viewing/control and
operation-history UI are deferred, not implied by this local inspector.

Regression entry points: `AgentBrowserDevToolsTests` (injected native boundary),
`tests/devtools.py <isolated-signed-app> <pinned-engine> <identity-fixture>`, and
`tests/background_tabs.py <isolated-signed-app> <pinned-engine> <identity-fixture>`.
The background regression keeps two tabs in the **same workspace**, checks the
original document/unsaved DOM after closing the last inspector, then exercises
both public engines, repeated closes, other workspaces and normal host shutdown.
Its default background idle is 120 seconds (`--idle 0` for a quick run).
Both native tests require the acceptance-only `CTRLX_UPSTREAM_BROWSER_PROBE`
runtime and exercise the same native method as the button; they are not
toolbar-click or real-Codex tests. No automatic reload/replay recovery is used.

## Build and checks

For the historical unmodified Vercel engine compatibility proof, see
[upstream probe](agent-browser-upstream-probe.md). The subsequent
[dual-engine integration](agent-browser-engines.md) uses CEF's native WebSocket
server, not that test's Python proxy or test-only raw-CDP hook.

`bash scripts/build-agent-browser.sh` builds and development-signs the native
runtime/framework and sandboxed helpers;
`scripts/package-local-macos.sh` builds it before packaging CtrlX. Ordinary Xcode
builds without the prebuilt runtime leave the feature unavailable. Archives
with the development runtime are deliberately blocked until runtime and
distribution validation are complete. Packaging does not install the app.
The standalone acceptance recorded below is **historical** and does not prove
the new embedded UI. Embedded acceptance uses a separate signed CtrlX test copy,
an isolated tmux server, private profile and the repository's E2E API socket.
Run only one E2E host at a time. Never replace the production app for this test.

The repository-local `plugin/ctrlx/skills/agent-browser/SKILL.md` documents the
bounded CLI operations. It is not installed into a running Codex automatically.

Focused identity/launch tests (18) cover ancestry, nested/sibling instances,
PID reuse, concurrent first calls, private paths and unmodified launch commands.
CLI subprocess checks detach from any calling Codex to verify fail-closed
behavior and inherited-token refusal without accidentally opening a browser.
They also cover argument quoting and optional launcher shell functions.
Ownership unit tests
can run without a GUI:

```sh
swift test --package-path CtrlxPackage --filter 'AgentBrowserIdentityTests|SessionLaunchPreparationTests|SessionDirectoryResolverTests'
clang++ -std=c++20 CtrlxPackage/AgentBrowser/tests/ownership.cc -o /tmp/ctrlx-browser-ownership-test
/tmp/ctrlx-browser-ownership-test
clang++ -std=c++20 -fno-exceptions CtrlxPackage/AgentBrowser/tests/helper_paths.cc -o /tmp/ctrlx-helper-paths-test
/tmp/ctrlx-helper-paths-test
clang++ -std=c++20 -fobjc-arc -framework Foundation \
  CtrlxPackage/AgentBrowser/tests/page_keys.mm -o /tmp/ctrlx-browser-keys-test
/tmp/ctrlx-browser-keys-test
python3 CtrlxPackage/AgentBrowser/tests/cli.py CtrlxPackage/.build/debug/CtrlxCLI
clang++ CtrlxPackage/AgentBrowser/tests/identity.cc -o /tmp/ctrlx-browser-test-identity
python3 CtrlxPackage/AgentBrowser/tests/embedded.py \
  '<signed copy with bundle ID com.ctrlx.embedded-acceptance>/CtrlX.app' \
  /tmp/ctrlx-browser-test-identity --restart-check
```

The embedded harness checks two source sessions with opposing focus, native
view attachment, child routing, trusted input, bounded page actions, shared
storage and per-run ownership. `--restart-check` additionally verifies child/
parent closing, DOM preservation on reattachment, graceful quit/restart,
persistent and session cookie survival, old-grant rejection, and new crash
reports, then exits the test app. Without that flag it leaves the test host
alive for manual tab/split/close inspection. Quit only that test app afterwards.
Its shells use a private `ZDOTDIR` configuration without personal startup files
or shell history. First-use Keychain prompts are always user-operated;
`--interactive-setup` permits a supervised unbounded first load.
If the initial authorization outlives a bounded test, `--resume <printed state
directory>` reuses the exact live host and fixture grants. It refuses to replay
a run once any page mutations have begun. Never print `fixture-grants.json`:
it contains private test credentials, not acceptance evidence.
The identity helper is a real process inside each test pane, **not real Codex**;
real-agent acceptance must be reported separately.

### Embedded verification status (2026-09-23)

- Complete Mac Release build and deep/strict signature verification passed.
- 56 focused Swift tests passed (identity, routing, layouts, launch, shutdown,
  existing WebKit/remote URL policies), plus native ownership/helper-path/key
  tests, CLI refusal/parsing tests, setup-wait tests and skill validation.
- After user-operated Keychain authorization, the isolated two-session native
  acceptance passed: opposing-focus routing, attached browser views, trusted
  Chinese input/clicks, the bounded page-action suite, cross-run refusal, child
  inheritance/closing, parent DOM preservation on reattachment, and closing a
  tab without closing the parent CtrlX window or the other session's page.
- The full graceful-restart check passed: localStorage, persistent cookies and
  session cookies survive; old epoch grants are rejected; both test launches
  exit normally with no new browser/Helper crash reports.
- This check caught two additional defects: using the UI refresh cache could
  miss a source pane during startup (and hide linked-session ambiguity), and
  immediate CEF teardown could lose pending cookie writes. Live, non-deduplicated
  routing and awaited cookie flushing fix these causes. Regression coverage is
  in `AgentBrowserRoutingTests` and `tests/embedded.py --restart-check`.
- Native acceptance evidence: `/tmp/ctrlx-embedded-final-acceptance.log` and the
  test state's `acceptance.json` (state directory printed in that log).
- Desktop UI inspection is unavailable in this environment. Visual layout,
  mouse/drag split-tab behavior and **real Codex embedded-host acceptance** are
  not claimed by the deterministic native-process fixture. The earlier real
  Codex standalone results below do not prove the new embedded UI.
- At that checkpoint, production CtrlX was not restarted or replaced. No
  commit, push or release was performed.

### Host startup regression (2026-09-27)

The first production install exposed a host-side rollout-reader defect that
the isolated browser fixture could not cover. `CodexRolloutPostureReader` used
`readToEnd()` on the entire transcript when the latest turn context was outside
its 256 KiB tail. A real multi-day transcript caused an approximately 3 GB read;
the embedded process trapped in Chromium while Foundation allocated that read.
The previous installed app was restored before changing the reader.

The reader now walks backward from a captured EOF, requesting at most 256 KiB
per read, retaining at most a 1 MiB record and scanning at most 8 MiB per lookup.
It preserves complete JSON/UTF-8 across chunk boundaries. An oversized record,
truncation/read failure or exhausted scan budget returns `user` (keep permission
notifications), not an older `auto_review` result or a snapshot fallback. This
can conservatively show a permission notification for an unusually large turn;
it does not change Codex's actual approval configuration.

Regression coverage includes sparse 3 GiB files without allocating/writing
3 GiB, oversized and multi-chunk records, byte/newline boundaries, and a plugin
integration test proving an inconclusive scan cannot suppress an approval form.
Run `swift test --package-path CtrlxPackage --filter CodexPluginCoreTests`.

Local validation after this fix: 192 Codex-core tests passed; the Mac Release
build and deep/strict signature verification passed. The fixed build replaced
`/Applications/CtrlX.app` with a recoverable backup, preserved both live tmux
sessions, and ran for over 13 minutes without a new CtrlX crash report. The
existing real Codex process (no wrapper/restart) successfully opened and read
`https://example.com` through the installed CLI; `tabs` confirmed its source
session/pane routing and `embedded: true`, then `visible: true` after `show`.
This is a real-agent smoke test, not a claim that every browser operation or
visual layout has been manually accepted. No commit, push or release.

## Historical standalone acceptance (before embedding)

The `integration.py` standalone launcher and `real_codex.py` below describe the
old companion architecture. They are retained as regression fixtures/evidence,
not as launch instructions for the embedded host. In particular a Codex spawned
outside a CtrlX tmux pane now fails routing instead of opening a separate app.

The integration test uses a new private temporary profile and local HTTP fixture.
Its `page_actions.py` fixture covers fill/clear/insert, Chinese/multiline/email
inputs, trusted keyboard events, Shift+Tab, select-all, form idempotence, input
redaction, pagination, scrolling, condition deadlines, navigation, concurrent-tab
availability, parameter bounds, and cross-group refusal for every new verb.
It tests cross-group refusal, trusted input, child inheritance, cookie/storage
persistence, process revocation and stale grants. **Five consecutive runs passed
on 2026-09-23 after the fixes below (ten browser launches).** The tests use real
CDP input (`isTrusted=true`), switch to the other instance's tab before each
input/click, and wait for the fixture's asynchronous update without replaying
mutations. Click/type now explicitly reveal and focus their authorized native
CEF tab; setting DOM focus alone did not ensure the hidden tab received input.

First-use authorization must not race the automated load deadline. In a captured
failure, macOS recorded browser PID 66572 exiting at 09:46:20, followed by the
user approving Always Allow at 09:48:08 and Security reporting
`errSecCSNoSuchCode` (-67065). The stored item ACL still lacked Agent Browser.
The stale prompt outlived the timed-out test process; repeated relaunches only
added more prompts. The user had correctly entered the password.

For supervised first-use setup, append `--interactive-setup` to the integration
command. This keeps the same process alive without an initial page-load deadline;
the user handles macOS authorization locally, and Ctrl+C cancels. Do not rebuild
or launch additional copies while waiting. All subsequent test assertions retain
bounded deadlines, including restart persistence. Routine runs retain the
30-second load deadline (`CTRLX_TEST_LOAD_TIMEOUT` can override it). The helper
does not read, modify or automatically approve Keychain permissions. Regression
checks: `python3 CtrlxPackage/AgentBrowser/tests/wait_policy.py`.

With the first-use process kept alive, user authorization was saved for the
current Agent Browser. Rebuilding with the same signing identity and the ten
subsequent test launches required no further intervention; both persistent and
session fixture cookies survived browser restart. System authorization must
remain user-operated: do not disable cookie encryption, export keychain
credentials or automatically approve access.

## Real Codex acceptance (2026-09-23)

**Historical wrapper-based acceptance, before automatic identity discovery:**
passed with two real `codex-cli 0.155.1` processes (`gpt-6-astra`), not mock
agent identities.** The opt-in harness starts `codex exec --ephemeral` through
the packaged `CtrlXCLI browser run`, copied the exact packaged skill into each
isolated test workspace, and records actual CLI calls plus independent fixture
events. It does not install a plugin into the user's active Codex configuration.

```sh
python3 CtrlxPackage/AgentBrowser/tests/real_codex.py \
  .build-local/DerivedData/macOS/Build/Products/Release/CtrlX.app --manual-ui
```

This test consumes Codex quota and uses the normal CtrlX Agent Browser profile,
with only a loopback page and a uniquely named, fake login cookie/storage entry.
No real account or system Chrome profile is accessed. `--manual-ui` keeps A alive
while the operator creates the printed Manual URL in a new native tab and assigns
it to A, then creates the printed `ui-done` marker. Omit it for automated checks.

The current harness uses **plain `codex exec`**, with no browser wrapper or
context environment variable. It checks that each CLI-discovered kernel PID is
the actual Codex PID, in addition to the page actions and isolation checks below.
The earlier results in this section describe the prior wrapper-based runs.

Verified:

- CLI lazily opens the companion from inside the complete signed Mac bundle.
- Both agents load the packaged skill, open/read their own pages, type Chinese,
  click and take PNG screenshots. Independent fixture events confirm exactly one
  submission per agent, with both input and click `isTrusted=true`.
- A opens a child tab into its own group. B sees only B's tab and cannot read A's
  exact tab ID while A is still running.
- B sees A's fake login without logging in again. Cookie/storage survival across
  browser restart also passes the deterministic integration test against the
  **nested, packaged** companion executable (two additional browser launches).
- Native UI assignment moves a Manual tab to A; A's final CLI listing includes
  it. B's exited instance disappears from the assignment choices.
- After both real Codex processes exit, their saved contexts are rejected and
  the native UI marks the groups Ended without closing their pages.
- A separate CtrlX run using the existing E2E isolation flags opens the companion
  from its toolbar. The original New Browser action and terminal remain present.
  The production CtrlX process and its tmux sessions were not restarted.

This acceptance caught and fixed a packaging-only startup crash: CEF's default
top-level bundle lookup selected the outer `CtrlX.app`, not the nested companion.
`main_bundle_path`, `framework_dir_path` and `browser_subprocess_path` now point
explicitly into the executable's own bundle. Standalone-only tests had missed it.
The first real run correctly failed; the rerun after the fix passed.

Local proof artifacts are under
`.build-local/agent-browser-acceptance/20260923-real-codex/`: `acceptance.json`,
independent `fixture-events.jsonl`, A/B Codex transcripts and page screenshots,
plus toolbar, manual-assignment and ended-instance UI captures. They are ignored
build evidence, not source files or authentication credentials.

Still outside this acceptance: real-site OAuth compatibility, iOS/remote browser
control (not in scope), tab-layout restoration, and distribution-grade hardened
runtime / notarization. The archive gate remains intentional. The local DMG is a
development artifact, **not** a published release. No Qcloud upload, production
installation, commit or push was performed.

### Expanded CLI acceptance (2026-09-23)

The next increment passed two real Codex instances using the rebuilt complete
Mac package and its updated 69-line skill. Both performed fill → Meta+A → type
→ click → text wait, idempotent checkbox setting, native select, nested scroll,
scoped/paginated read and screenshots. Independent fixture events confirmed
exactly one checkbox change and one submission per instance, trusted key/input/
click events, Beta selected and scroll position 120. Select events are explicitly
synthetic. Shared fake login, child ownership, cross-instance refusal and
post-exit revocation also passed. Actual transcripts verify successful invocation
of every new operation; this is not just an agent's self-reported result.

The first expanded real run exposed a usability gap: the old read response gave
the result paragraph's text but not its selector, so Codex correctly refused to
invent a selector for `wait`. Read now includes readable/named regions and scroll
metadata alongside controls. The rerun passed without supplying fixture selectors
in the prompt. Cold-start timeout errors now also distinguish startup from an
unsafe path and make clear that no page action was sent.

A final deadline regression reproduced the minimum-timeout bug before the fix:
delaying the first probe by 100 ms consumed the entire 100 ms timeout even on a
ready page. The first probe is now immediate. Tests also deliberately block the
fixture renderer for 1.5 seconds: a 300 ms wait still times out in under a second,
other tabs stay available, and late renderer responses cannot complete an expired
request. No page mutation is retried.

Deterministic CEF action/ownership regressions, bounded-key tests, CLI parsing/
identity tests, 3 setup-wait tests, 9 Swift launch tests, skill validation, complete
Release build and deep/strict signature verification passed. Evidence is in
`.build-local/agent-browser-acceptance/20260923-page-actions/` (including the
first-run failure log); `final/acceptance.json` records the second successful
two-Codex run against the final deadline-fixed signed package. The production
app remains untouched; no install,
commit, push, public release or real-site OAuth validation is implied.

### Post-install helper crash regression (2026-09-23)

User testing exposed a gap in the preceding acceptance: page operations and the
browser's own exit status passed while a late Helper crashed at shutdown. This
was reproduced against `/Applications/CtrlX.app`; it was not just an old dialog.
The crash was in CEF's framework-bundle path initialization. Ordinary child
processes inherit the explicit path switches, but auxiliary launches can omit
them and resolve the outer CtrlX bundle instead of the companion.

`Helper.cc` now supplies missing framework/main bundle switches from its own
canonical executable location before sandbox initialization and CEF execution.
Existing switches, argument boundaries and Chromium's sandbox are preserved.
The path unit test covers standalone/nested bundles, spaces, helper variants and
invalid layouts. Integration checks now watch for new browser/helper `.ips`
reports, including a five-second reporting window after each graceful shutdown;
redacted report paths are handled as well. Run these checks without other Agent
Browser instances generating crash reports concurrently. The pre-fix installed
binary fails this check; the corrected nested companion passes it.

### Automatic caller discovery acceptance (2026-09-23)

Passed against the development-signed complete Mac build `20260923-083441`:

- 18 Swift identity/launch tests; CLI parsing, detached/no-Codex refusal,
  inherited-context refusal; ownership/helper-path tests; skill validation.
- The current, already-running Codex was identified by the packaged CLI with
  `CTRLX_BROWSER_CONTEXT` removed, without restarting it or opening the browser.
- Two plain `codex exec --ephemeral` instances (no wrapper, no context env)
  passed the full `real_codex.py` fixture. Discovered PIDs exactly matched both
  real processes. Repeated page actions kept each runtime's own group; B could
  not read A's tab. Shared fake login, trusted input, child tabs, pagination,
  waits, controls and screenshots passed. After exit both grants were rejected.
- The first concurrent-context test exposed Foundation's mkdir/attribute timing
  window. Private directories now use atomic `mkdir(..., 0700)`; parallel first
  callers then consistently reused one identity and registration.
- Complete Release build and deep/strict signing verification passed. The first
  build encountered obsolete static Swift modules after dependencies became
  shared frameworks; moving those generated caches aside allowed a clean link.

Proof: `.build-local/agent-browser-acceptance/auto-discovery-k83ga_bm/`.
This increment does not install the app, refresh the user's installed skill,
commit, push or publish. Install the new app **and refresh the Agent Browser
skill** for ordinary use; the previously cached skill still requires the old
wrapper. No shell startup files or `codex` executable were modified.
