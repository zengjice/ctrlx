# Embedded Chromium compatibility probe (macOS)

**Experimental, not a production CtrlX browser. Local CLI/internal CDP acceptance
passes; official ChatGPT extension connectivity remains unverified.**

The original experiment tested the official ChatGPT extension route. That route
stopped at native-host discovery. The user subsequently approved an **independent
CLI + internal CDP route**, without the extension or MCP. These are distinct
acceptance results; CDP success is not official-browser-tool compatibility.

No production targets, WKWebView implementation, Relay, iOS app, Codex settings,
native-messaging manifests, default browser, or existing Chrome profiles change.
There is no MCP server, TCP debugging endpoint, or extension spoofing.

## Browser extension characterization (2026-10-16)

The new `ExtensionProbe.mm` is a separate executable compiled into a disposable
copy of the signed probe App. It does not replace the older probe or production
CtrlX. It implements the compatibility gate in the
[browser extension design](../../docs/browser-extensions-design.md), using the
small local `extension-fixture/` extension, not the official ChatGPT extension.

```bash
python3 scripts/local_build.py run -- bash scripts/cef-browser-probe.sh build
bash experiments/cef-browser-probe/prepare_extensions_probe.sh
# Execute the exact use-artifact command printed by preparation.
```

The runner starts a private loopback fixture on an ephemeral port and a new
profile below this worktree's `.build-local/diagnostics/`. It loads only the
test extension, uses the established mock-keychain mode, and bounds the process
with a timeout. It closes all of its own windows, then checks native shutdown.
`report.json`, `native.log` and `popup.png` stay with that run's profile. Reusing
the App still creates a fresh profile; the runner does not clear another run.

The test first focuses an Alloy page while a Chrome-style extension manager is
open, then closes the manager and repeats, then tests a Chrome-style page. It
checks actual request headers at the fixture server, content-script messaging,
tab enumeration and current-tab queries, and a real action popup. The popup
itself reports its tab queries; these are not inferred from a background worker.
An exact popup target is then captured through a private flattened CDP session.
There is no TCP debugging listener or production Agent-gateway permission change.

Observed on the pinned CEF: scripts and DNR work in both styles; Alloy pages are
absent from extension tab queries, and `action.openPopup` reports no active browser
window. The Chrome-style control correctly identifies its page and opens/captures
the popup. The PNG was visually checked. A successful runner means **observation
completed**, not that all compatibility checks passed; consult its separate
`compatibility` fields. ENV-Plugin, store installation, CRX verification, updates,
remote input and multi-client lifecycle are outside this fixture's evidence.

Append `--native-drag` to the printed runner command to install during execution
through a private native pasteboard and the manager's unpacked-install API,
without the startup `--load-extension` switch. Append `--production-admin` instead
to compile/exercise the actual `BrowserExtensions.inc` implementation for install,
disable, enable, reload, list and uninstall around the same page/popup checks. These modes
still use only this test fixture and a new private profile.

`--dynamic-install` retains a negative characterization: the Chrome directory
picker does not call CEF's `CefDialogHandler`, so the bounded probe fails. A
successful CEF file-picker callback must not be assumed for product imports.

Swift ZIP/CRX validation is separate:

```bash
./scripts/unit-tests.sh -- --filter 'BrowserExtensionPackageTests|BrowserExtensionStoreTests|BrowserExtensionWebStoreTests|AgentBrowserDevToolsTests'
# Optional: set CTRLX_EXTENSION_ENV_SAMPLE to a local ENV CRX3 sample to run
# suppliedENVSample as well. No third-party package is stored in Git.
# Optional: CTRLX_EXTENSION_DOWNLOAD_TEST=1 also downloads ENV-Plugin from
# Google's update service and verifies the CRX3 identity. It does not install it.
```

For real ENV acceptance, first export a new runtime directory through the actual
Swift CRX validator. Both environment-variable paths must be absolute: the unit
test script changes into `CtrlxPackage`. An existing export directory is refused.

```bash
CTRLX_EXTENSION_ENV_SAMPLE="$PWD/.build-local/diagnostics/browser-extension-source/env-plugin.crx" \
CTRLX_EXTENSION_ENV_RUNTIME_DESTINATION="$PWD/.build-local/diagnostics/browser-extension-source/env-runtime-new" \
  ./scripts/unit-tests.sh -- --filter BrowserExtensionPackageTests.suppliedENVSample
```

Append these arguments to the **printed use-artifact runner command**:

```text
--env-extension .build-local/diagnostics/browser-extension-source/env-runtime-new
--env-scenario experiments/cef-browser-probe/env-request-header.js
--env-restart-scenario experiments/cef-browser-probe/env-restart.js
```

The first phase installs ENV in the disposable profile, opens its real action
popup and verifies the current tab. The scenario creates a request-header rule
through that popup and checks active/paused/resumed requests at the local server.
Its private input binding sends CDP input only to that exact test popup; it is
never available through the product Agent gateway. The optional restart phase
fully shuts down CEF, starts a new process using the same **test-created** profile,
and checks runtime installation, saved configuration and actual requests without
reinstalling or writing configuration. Failed checks stay failed in `report.json`;
opening a popup does not count as a rule-effect pass.

For cross-origin request-header acceptance, append `--cors` to either the
`--production-admin` fixture run or the ENV run with `env-request-header.js`
(without restart, debugger or native-input modes). The real ENV scenario then
configures `x-maas-env: ark-chat-dev` through its popup. The fixture uses
`127.0.0.1` and `localhost` as distinct origins, served by the same private
loopback server. It checks actual received headers on GET, JSON POST, script
and redirect requests, response-header modification for the minimal extension,
and rejection of missing-origin permission and page-added forbidden headers
(including `x-maas-env` when added by page JavaScript itself).
`report.json` includes server-side `networkEvents` and strict `compatibility.cors`
checks. A CORS failure makes the command exit nonzero even when installation,
same-origin injection and orderly shutdown succeed.

The currently pinned prebuilt CEF **fails** this gate. The candidate source
patch and its uncompleted native-build acceptance are documented under
[Cross-origin header compatibility](../../docs/browser-extensions-design.md#cross-origin-header-compatibility).
Rebuilding only the probe executable does not apply a CEF source patch.

To exercise the product's generated key for unsigned ZIPs and immutable update
directories, export fixtures through the real store:

```bash
CTRLX_EXTENSION_FIXTURE_EXPORT="$PWD/.build-local/diagnostics/browser-extension-source/zip-update-new" \
  ./scripts/unit-tests.sh -- --filter BrowserExtensionStoreTests.exportNativeUpdateFixture
```

Then append `--fixture-packages` followed by the exported `fixture-packages.json`
path to a freshly prepared probe's printed runner command. This checks the exact
ID from Swift, version 1 → 2 → 1 → 2 across separate directories, page effects,
popup and confirmed uninstall. Explicitly restoring an older package tests the
native mechanism; it does not establish the Swift service's automatic failure
recovery. The probe confirms only its own fixture's exact native uninstall
dialog, never an arbitrary extension or another application's window.

For native-window transport characterization, append `--native-window-capture`
to an ENV scenario run. It captures only the source Chrome window belonging to
this process, including its native child popup, through ScreenCaptureKit's
`currentProcess` content. It does not request desktop capture. Append
`--native-window-input` instead to also click ENV's pause button through that
exact native window tree and check the actual HTTP header effect. It also checks
Unicode text insertion, Select All/Delete and rejection of a different source
window. The field must receive focus before native text insertion. Select All is sent as
an editing command to that same responder, rather than an application menu
shortcut. This mode
requires `--env-scenario` and runs separately from restart acceptance.

The mode also runs the product `ExtensionSurface.inc` against the same real
popup: bounded JPEG capture, native click, Unicode/editing input, wrong lease,
stale geometry, revoked input and rejection of Host clipboard shortcuts. It
temporarily makes the fixture's unrelated window key, then checks that input
restores the explicitly clicked owned window. These product-path assertions
must report `product-native-surface`; the helper-only checks are insufficient.

`product-surface-geometry` adds owned AppKit fixtures: a child window extends
outside its root, a sampled screenshot pixel must match that child's mapped
position, native input must reach its field, and a nested scroll view must move.
`inactiveBeforeInput` records whether the desktop actually left the probe inactive
after its deactivation request. A false value does not validate background focus.

Run `--native-manager-input` without ENV to capture the fixture's native removal
confirmation and click it through only the manager window's owned tree. Runtime
inventory must confirm removal before success. The popup and manager checks both
pass on the pinned SDK; they do not establish remote leases, typed wire commands,
all keyboard/scroll/drag combinations, or Mac Viewer/iOS product acceptance.

Use `--env-debugger` with the ENV header scenario for a separate debugger
coexistence check. The probe attaches through the real extension permission,
opens and waits for a visible, loaded native DevTools window, and verifies both
extension debugger access and CEF page control retain the exact source URL.
This does not test all ENV Data Mock or native messaging workflows.

## Local CLI / internal CDP (2026-09-22)

Implemented in `AutomationBridge.mm` and `browser_cli.py`. CEF's
`ExecuteDevToolsMethod` and `AddDevToolsMessageObserver` provide page control
in-process. `--probe-automation` explicitly opts in and opens **two native Alloy
views** using the separate `Automation` installation directory (no extension
required). It requests an in-memory cache context; login persistence is not an
acceptance claim. Fixture URLs have a unique per-launch query to ensure freshness.

Build in a separate output directory to leave the older running experiment intact:

```bash
CEF_PROBE_BUILD_NAME=build-cdp ./scripts/cef-browser-probe.sh build
./scripts/cef-browser-probe.sh serve
# In another terminal:
CEF_PROBE_BUILD_NAME=build-cdp ./scripts/cef-browser-probe.sh smoke-cdp
```

For interactive use, with the fixture server running:

```bash
'.build-local/cef-browser-probe/build-cdp/CtrlX Browser Probe.app/Contents/MacOS/CtrlX Browser Probe' --probe-automation
```

Use the **exact** `automation-socket` path printed by this process (it changes on
every launch); no socket/browser discovery or current-tab fallback:

```bash
python3 experiments/cef-browser-probe/browser_cli.py --socket '<path>' tabs
python3 experiments/cef-browser-probe/browser_cli.py --socket '<path>' read --tab '<id>'
python3 experiments/cef-browser-probe/browser_cli.py --socket '<path>' type --tab '<id>' --selector '#message' --text 'CDP 中文'
python3 experiments/cef-browser-probe/browser_cli.py --socket '<path>' click --tab '<id>' --selector '#apply'
python3 experiments/cef-browser-probe/browser_cli.py --socket '<path>' screenshot --tab '<id>' --output /tmp/new-probe-capture.png
python3 experiments/cef-browser-probe/browser_cli.py --socket '<path>' quit
```

Agent instructions are in `skills/ctrlx-browser-probe/SKILL.md`. They are not
installed globally and do not override the official Chrome/Browser skills.
The CLI returns JSON and nonzero status on error. `type` inserts at the field's
caret, does not clear it, and does not submit. Click uses CDP mouse press/release,
not a JavaScript `.click()`. Unique visible selectors are returned by `read`.
The read snapshot is top-document text (20k character cap, `truncated` flag) and
up to 100 controls; this is not a complete accessibility/iframe/shadow-DOM engine.

Security and lifecycle boundaries:

- Unix socket only, random instance directory mode 0700, socket 0600; peer UID
  checked. **Other processes running as the same user remain trusted**; this is
  not an app-identity or malicious-same-user security boundary.
- Only the two explicitly embedded views are registered, with random per-launch
  IDs. Popups, system Chrome, extension/internal/file pages are not exposed.
- No arbitrary CDP or JavaScript evaluation command, cookie/profile access,
  password/file input, browser launching fallback, or network forwarding.
- Bounded nonblocking socket work on CEF's UI loop, at most eight clients, one
  in-flight command per tab, request/response caps and finite deadlines.
- A timeout means **unknown outcome**, not guaranteed cancellation. Neither
  server nor CLI retries mutations. Re-read before deciding what to do next.
- Manual navigation or edits during an action are not coordinated in this
  prototype. Do not interact with the target while a command is in flight.
- Screenshot output is created exclusively, owner-only, without overwriting an
  existing file. Socket paths are removed on normal shutdown.

Acceptance evidence:

- Signed build and `codesign --verify --deep --strict` pass.
- `smoke-cdp` passes twice in fresh processes: two genuine native Alloy views,
  text/selector snapshot, Unicode/quote/backslash text insertion, real mouse
  clicks with result readback, PNG screenshot, and independent A/B state.
- Rejects unknown/stale IDs after restart, missing/ambiguous selectors,
  unsupported input, malformed/oversized requests and raw-CDP commands. A partial client cannot block another
  client's query. Confirms no browser-process TCP listener.
- Both processes quit normally and remove their Unix socket directories.
- The event fixture checks `isTrusted` to distinguish CDP input from a JavaScript
  click. This additional check initially exposed a cached older fixture; the
  tests now use unique per-launch fixture URLs and require the new marker before
  interaction, leaving all existing profiles intact. An empty cache-path setting
  alone did not eliminate the stale page in this pinned runtime.
- Original native load/close smoke and 21 Python unit tests pass; skill validator
  passes. One CDP viewport screenshot was visually inspected and shows the
  exact inserted message and `Count: 1`.
- The existing helper `Resources` sandbox-extension warning can still appear
  on teardown. It did not prevent these tests; no sandbox/signature bypass used.

Still out of scope: replacing production WKWebView, shipping the CEF runtime,
production tab/session ownership, multi-agent authorization, navigation-race
handling, uploads/downloads, remote Host/Viewer routing, iOS and Relay changes.
Those require integration work; this test does not establish production readiness.

## Build and run

Requirements: Apple Silicon Mac, Xcode command-line tools, CMake, Python 3, and an
installed Apple Development signing identity. This local-development build is not
notarized. Personal signing data is discovered locally, never committed. Set
`CEF_PROBE_SIGN_IDENTITY` to select an explicit installed identity if needed.

From the repository root:

```bash
./scripts/cef-browser-probe.sh build
./scripts/cef-browser-probe.sh serve
```

The second command serves only `fixture/` on `127.0.0.1:8769` and stays running;
stop it with Ctrl+C. In another terminal:

```bash
./scripts/cef-browser-probe.sh smoke
./scripts/cef-browser-probe.sh smoke-control
python3 -m unittest discover -s experiments/cef-browser-probe -p 'test_*.py' -v
```

Both smoke commands launch and close a test process. They require the exact local
fixture, have a 20-second in-app timeout and a 35-second process-group watchdog,
and fail if an existing instance merely accepts a relaunch. The final PASS is
emitted only after CEF shutdown returns, not on page load. A timeout only stops
that test's process group. Do not rebuild while a probe instance is open.

The app is at:

```text
.build-local/cef-browser-probe/build/CtrlX Browser Probe.app
```

For manual testing open that app in Finder. Normal mode embeds CEF's **Alloy**
browser in the application's NSView. The address field accepts Return; native
buttons open the fixture, extension manager, and official ChatGPT store listing.
The store button only navigates; it does not install or grant permissions.

`--probe-chrome-control` instead creates a separate CEF **Chrome-style** window
as a diagnostic control. It uses a different profile. Success there does not
prove that the embedded Alloy view works. Neither mode is branded Google Chrome.

## Original extension acceptance gates (separate, blocked)

The following gates describe the **original extension route**, not the new CDP
route. They must not be relabeled as passed by a CDP test:

1. `smoke` proves the CEF view is a descendant of the native container, uses Alloy,
   finishes an HTTP 200 fixture load, and exits cleanly. Re-run after rebuilding.
2. Visually confirm rendering, native resize, click, keyboard input, scrolling,
   window close and Quit. Native load callbacks alone do not prove visual output.
3. Manually install the unmodified official ChatGPT extension in the **Embedded**
   profile, review its requested permissions, and authorize it. Record the actual
   extension version and whether the store/extension manager supports this runtime.
4. Codex's official browser connection discovers this exact embedded browser. If
   discovery/native messaging cannot connect, stop and record that boundary; do
   not copy/patch manifests, extension source, browser IDs, or use CDP as a bypass.
5. Through the official tool, read `CTRLX-CEF-EMBEDDED-2026`, type a unique test
   message, click Apply and Increment, verify their results, scroll to
   `EMBEDDED-BROWSER-END`, and capture a screenshot. Ensure it is this view, not a
   copy of the fixture in system Chrome or the Chrome-style control window.
6. Quit/reopen, reconnect, and repeat. Installation and authorization should
   persist without weakening Chromium's sandbox or peer-signature checks.

An extension appearing in `chrome://extensions` is **not** evidence of official
tool connectivity. CEF embedding is also not evidence of Chrome extension parity.

## Current evidence (2026-09-22)

Environment: local Apple Silicon Mac, macOS 27.0 (26A428).

- Pinned CEF **152.0.8+g1ce985c**, Chromium **152.0.7977.134**.
- Download checksum verified, build and `codesign --verify --deep --strict` pass.
- Embedded callback reports `style=alloy`, `embedded-parent=verified`, 1120×692.
- **Native embedded smoke passes**, including repeated launches: HTTP 200 at
  the exact fixture URL, verified Alloy child NSView, native window close,
  `OnBeforeClose`, CEF shutdown and exit status 0.
- **Chrome-style control passes**, also loading the fixture and exiting cleanly.
  This is a separate profile/window and is not embedded-extension proof.
  The latest control run still emits a helper `Resources` sandbox-extension
  warning during teardown; it does not fail this load/close check, but is not
  evidence that all extension/helper functionality works.
- The original load stall had a browser worker blocked in
  `SecItemCopyMatching` → `SecKeychainItemCopyContent` → SecurityServer decrypt.
  The user confirmed and handled the keychain prompt; subsequent runs completed
  the HTTP load. No keychain values or browser credentials were read by the
  diagnostic tools. Renderer startup was already succeeding before authorization.
- Successful loading then exposed a separate teardown hang. UI created during
  startup now has a scoped autorelease pool instead of leaving temporary view
  references in main's process-lifetime pool. The application delegate is also
  restored after `CefInitialize`, following the CEF sample's initialization
  order. Native window teardown now releases the CEF child and exits cleanly.
- The initial `-67030` Info.plist signature errors disappeared after normalizing
  generated plists with `plutil` before signing. This did not resolve the load
  timeout. CEF framework versioned layout and repeatable symlink creation are
  handled in the build. No sandbox/peer validation bypass was introduced.
- The desktop tool still reports `cgWindowNotFound` for the probe. Visual and
  manual interaction checks remain pending. It explicitly disallows operating
  SecurityAgent; authorization stays user-operated, without an automation bypass.
- The user installed the official ChatGPT extension in the **Embedded** profile.
  The official read-only extension diagnostic confirms extension ID
  `hehggadaopoacecdllhhajmbjkdcmajg`, version `1.26.901.11451_0`, installed,
  registered and enabled. No disable reasons are present.
- **Official connection is blocked at native-host registration.** The probe's
  warning log repeatedly reports `Can't find manifest for native messaging host
  com.openai.codexextension`. Official-tool discovery still returns only the
  pre-existing system Chrome instance. No embedded official-tool interaction has
  been attempted or passed.
- All 9 smoke-runner unit tests pass and cover timeouts/interruption, false-success
  on relaunch, renderer readiness or page load without final shutdown, failed
  exit status, and separation of embedded vs. Chrome-style control results.
- Temporary verbose Chromium diagnostics have been removed. The probe retains
  lifecycle/status-only messages and warning-level framework logging.

### Keychain boundary

The pinned CEF uses Chromium's default `Chromium Safe Storage` / `Chromium`
keychain names. A separate profile directory does **not** isolate this encryption
key. The user has handled the prompt for this test, but the exact choice
(one-time vs. persistent permission) has not been recorded. If a prompt recurs,
have the user inspect and handle it; do not silently authorize it. Never automate
authorization, read/export the key, delete/reset it,
grant broad access, disable encryption, or disable the sandbox.

CEF merged configurable `keychain_service_name` / `keychain_account_name` in
upstream PR #4247. Those fields are absent from the pinned 152.0.8 SDK and also
from the inspected 154.0.23 beta source. Do not add unknown command-line switches
or claim that a normal app name/bundle ID changes the keychain namespace. A
future SDK exposing those settings can give the probe its own stable key names;
changing them after storing encrypted data requires a migration decision.

### Official extension connection boundary

The pinned Chromium source looks for user-level native hosts in
`DIR_USER_DATA/NativeMessagingHosts`, independently of whether an extension is
installed. CEF sets `DIR_USER_DATA` to this experiment's root cache directory.
The official read-only native-host diagnostic confirms the manifest is missing
from both locations applicable to this probe:

- `~/Library/Application Support/CtrlXBrowserProbe/Embedded/NativeMessagingHosts/com.openai.codexextension.json`
- `/Library/Application Support/Chromium/NativeMessagingHosts/com.openai.codexextension.json`

The same diagnostic reports valid manifests in its configured Chrome, Edge,
Brave, Opera and Vivaldi destinations. Those successful checks do not register
the isolated CEF profile. This establishes the current missing-bridge blocker,
not whether later browser-identification or extension API compatibility would
work after an officially supported registration.

Stop at acceptance gate 4. The Chrome skill requires native-host installation or
repair through the official Browser plugin UI, not manual manifest copying,
symlinks, host executables, profile redirection, or browser-identity spoofing.
Ask the user to reinstall the Browser plugin from the ChatGPT plugin UI; whether
that installer recognizes this custom CEF app remains unverified. Do not promise
that reinstalling will add CEF support. Resume only if the official setup can
register/discover this exact browser. Do not substitute system Chrome, desktop
automation or a CDP connection and label that an embedded-extension pass.

**This is a reproducible probe, not a usable integration or a
claim that the official extension supports CEF.**

## Isolation, size and cleanup

- Download, extracted SDK and build output stay in the ignored
  `.build-local/cef-browser-probe/` (roughly 1 GB; app about 340 MB).
- Development data is isolated in
  `~/Library/Application Support/CtrlXBrowserProbe/`: `Embedded`, `ChromeControl`,
  `Smoke`, `SmokeChromeControl`, `Automation`. No existing browser profile is read/copied.
  Keychain encryption names are **not** isolated in this SDK (see above).
- Close probe windows and stop the fixture server before cleanup. These two
  **probe-specific** directories can be moved to Trash manually; doing so loses
  only this experiment's downloaded/build artifacts and browser state, including
  any extension permissions granted in its profiles. Do not delete their parent
  directories or any Chrome/Codex/production CtrlX directories.
- Third-party CEF license and Chromium credits are copied into the app Resources.
  Redistribution and production security/update/signing work are not approved by
  this experiment.

## Source references

- [Official ChatGPT browser extension setup](https://learn.chatgpt.com/docs/chrome-extension)
- [CEF architecture](https://chromiumembedded.github.io/cef/architecture.html)
- [CEF build distribution](https://cef-builds.spotifycdn.com/index.html)
- [CEF macOS sample packaging](https://github.com/chromiumembedded/cef/blob/master/tests/cefsimple/CMakeLists.txt.in)
- [Pinned CEF macOS startup/close example](https://github.com/chromiumembedded/cef/blob/1ce985cb23056548b9cc51483bbef4faf68b1cd3/tests/cefsimple/cefsimple_mac.mm)
- [Chromium's cached Info.plist serialization](https://github.com/chromium/chromium/blob/main/base/mac/info_plist_data.mm)
- [Pinned Chromium keychain implementation](https://github.com/chromium/chromium/blob/152.0.7977.134/components/os_crypt/common/keychain_password_mac.mm)
- [CEF keychain customization change](https://github.com/chromiumembedded/cef/pull/4247)
- [Chrome native messaging registration and diagnostics](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)
- [Pinned Chromium native-host search paths](https://github.com/chromium/chromium/blob/152.0.7977.134/chrome/common/chrome_paths.cc)

The build script pins the actual archive and SHA-256; upstream documentation can
change independently. The downloaded SDK's `cef_types_mac.h` and
`cef_life_span_handler.h` define the embedded runtime and window-close contract.
