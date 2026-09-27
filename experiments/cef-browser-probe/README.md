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
