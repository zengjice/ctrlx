# Two engines, one CtrlX browser

The default **vercel** engine adapts the unmodified, pinned agent-browser 0.38.1
executable. The original **ctrlx** engine is preserved as an explicit choice,
including its bounded page-action implementation. Neither selection changes CEF, creates a second
browser/profile, replaces WebKit New Browser, or enables remote browser control.

## Usage

Start Codex normally in a local CtrlX session; use the same `ctrlx browser` entry:

```sh
ctrlx browser engine                 # current Codex instance; default vercel
ctrlx browser engine vercel          # preference belongs to this process instance
ctrlx browser action open --url https://example.com
ctrlx browser action snapshot --tab <returned-id>
ctrlx browser action fill --tab <id> --selector '@e2' --text 'Hello'
ctrlx browser action click --tab <id> --selector '@e3'
ctrlx browser action read --engine ctrlx --tab <id>
ctrlx browser engine ctrlx           # restores original backend, keeps tabs/login
```

`--engine` overrides one action. A new Codex process defaults to Vercel; an
existing saved choice (including ctrlx) is preserved. Another instance is
unaffected. Commands still require explicit tab IDs.
No additional launcher, standalone browser, npm or system agent-browser is needed.

| Operations | Implementation with vercel selected |
|---|---|
| snapshot | Upstream interactive AX snapshot + element refs |
| click/type/fill/press/select/check/screenshot | Pinned upstream engine |
| tabs/open/navigate/show/close | CtrlX ownership and embedded tab lifecycle |
| read/wait/scroll | Original bounded CtrlX contract (compatible pagination, deadlines, containers) |

`snapshot` is new; `read` has not changed shape. Mutation results and screenshot
no-overwrite handling retain the existing CLI envelope. Unsupported combinations
fail explicitly, with no automatic engine switch or retry. A timed-out mutation
can have taken effect: inspect before deciding whether to repeat it.

## Extended page capabilities

Existing `action` syntax and original-engine behavior are unchanged. For the
larger Vercel page catalog, use `command`; it explicitly uses Vercel without
changing the saved preference:

```sh
ctrlx browser command --tab <id> -- get title
ctrlx browser command --tab <id> -- find role button click --name Continue
ctrlx browser command --tab <id> -- upload '#file' /absolute/approved-file.txt
ctrlx browser command --tab <id> -- frame '#frame'
ctrlx browser command --tab <id> -- frame main
ctrlx browser command --tab <id> -- network requests
ctrlx browser command --tab <id> -- network request <observed-request-id>
ctrlx browser command --tab <id> -- network har start --content all
ctrlx browser command --tab <id> -- console
ctrlx browser command --tab <id> -- set viewport 640 480
ctrlx browser command --tab <id> --output /tmp/new.pdf -- pdf
ctrlx browser command --tab <id> --output /tmp/new.png -- screenshot --full --annotate
ctrlx browser command --tab <id> --output /tmp/new.txt -- download '#download'
```

The root catalog is printed by `command --help`. It covers interaction/get/is/find,
scrolling, waits, page JS, DOM reading, owned frames, history, dialogs,
local/session storage, page-host cookies, file input/download/PDF/PNG/JPEG, console/errors,
request tracking/interception/HAR, headers/HTTP auth, emulation, baseline diffs,
React, WebMCP, Web Vitals and axe accessibility audits. Options for CtrlX precede `--`.
`vitals` reloads the page. Network tracking/HAR should be started before the traffic
being measured. Artifact output requires a new path, max 6 MiB.

Commands are allowlisted before ownership/engine access, then encoded as a
single-command JSON batch on stdin to the unchanged upstream binary. There is
no shell execution or global argv passthrough; empty strings, quotes, newlines,
Unicode and flag-looking text are preserved. Only the fixed screenshot output
flags (annotation/format/quality) are lifted into upstream argv. Providers and launch
flags remain stable until an explicit `setup`. `frame --name|--url` is translated
to the existing typed daemon action over its private same-UID socket: 0.38.1's CLI
parser lacks these options although its frame handler supports them. No raw CDP
or arbitrary daemon-command entry is exposed.

### Managed expansion workflows

```sh
ctrlx browser command --tab <id> --output /tmp/new.jpeg -- screenshot --selector '#observed' --format jpeg --quality 80
ctrlx browser command --tab <id> --output /tmp/changed.png -- screenshot --if-changed --threshold 0.01
ctrlx browser command --tab <id> -- diff snapshot --baseline /absolute/before.txt
ctrlx browser command --tab <id> --output /tmp/diff.png -- diff screenshot --baseline /absolute/before.png
ctrlx browser command --tab <id> -- diff url https://example.com/a https://example.com/b
ctrlx browser command --tab <id> --output /tmp/url-diff.png -- diff url https://example.com/a https://example.com/b --screenshot
ctrlx browser command --tab <id> --input-file /absolute/approved.js -- eval
ctrlx browser command --tab <id> --input-file /absolute/params.json -- webmcp invoke <tool>
ctrlx browser batch --tab <id> --commands-json '[["get","title"],["get","url"]]'
ctrlx browser batch --tab <id> --continue-on-error --commands-json '[{"command":["get","title"]},{"command":["screenshot"],"output":"/tmp/batch-new.png"}]'
ctrlx browser command --tab <id> -- frame --url /observed-child
ctrlx browser setup --tab <id> --react --init-script /absolute/approved-init.js
ctrlx browser command --tab <id> -- reload
ctrlx browser command --tab <id> --input-file /absolute/approved-init.js -- init add
ctrlx browser command --tab <id> -- init list
ctrlx browser command --tab <id> -- init remove <returned-uuid>
ctrlx browser command --tab <id> -- react tree --raw-json
ctrlx browser command --tab <id> -- webmcp list
ctrlx browser record --tab <id> --seconds 3 --output /tmp/new.webm
ctrlx browser record --tab <id> --seconds 3 --format mp4 --fps 12 --cursor --output /tmp/new.mp4 --contact-sheet /tmp/new-sheet.png
```

- Conditional screenshots return `changed:false, artifactSkipped:true` without a
  file. Screenshot diffs also skip the file on exact match or dimension mismatch;
  inspect `match`/`dimensionMismatch`. Text baselines are regular UTF-8 files up to
  1 MiB; PNG baselines up to 6 MiB/16 MP. Symlinks and special files are refused.
- URL diff navigates the **same owned tab** to both URLs and leaves it on the
  second. It is not read-only. With `--screenshot` and mandatory `--output`, CtrlX
  composes navigation/snapshot/capture/image-diff because the upstream native
  handler ignores that CLI option. Returns `snapshotDiff` and `screenshotDiff`;
  matching images or incompatible dimensions skip the file as above.
- `--input-file` and `--input-stdin` before the delimiter accept UTF-8 JavaScript
  for `eval`/`init add` without inline code, or a JSON object for `webmcp invoke` without
  `--params`. Exclusive input modes; 48 KB including command arguments, regular
  files only, no symlinks. Stdin is read through EOF before sending any action.
- `network request <requestId>` inspects a tracked request and its available
  response body; binary/unavailable bodies retain upstream behavior. HAR start
  supports `--content all|text|none`; stopping still requires a new output path.
- `batch` accepts 1–32 argv arrays or `{command:[...], output?:"new path"}` objects
  (48 KB of arguments). All commands and distinct/new output paths are validated
  before execution under one tab lock. Default stops on first failure. Explicit
  `--continue-on-error` returns every attempted step with `success`; any failure
  makes the CLI exit nonzero with `ok:false`. No rollback/retry, including after
  uncertain failures. Artifacts export per step, not atomically; earlier effects
  and files remain after later failure. Conditional captures may skip their file.
- `setup` replaces up to four 48 KB UTF-8 init scripts and optional React hook.
  It disconnects the old tab daemon before changing its launch settings, then
  reconnects to the same CEF page with preview disabled. No implicit reload.
  Reload explicitly for injection before app mount. Refs expire; empty setup
  clears future injection, not effects already applied to the current document.
- `command … init add <source>` (or bounded file/stdin), `init list`, and
  `init remove <UUID>` manage dynamic scripts independently. They reuse upstream
  typed init actions; opaque IDs map only to scripts added this way, not setup/
  React hooks. IDs survive navigation but expire on setup, daemon idle shutdown or
  restart. The socket generation prevents recycled upstream IDs from removing a
  different script. Max 16 dynamic scripts; scripts affect future documents only,
  so reload explicitly. Use `setup` for scripts that must persist across engine restarts.
- WebMCP is a page-provided experimental Chromium API, not a Codex MCP server.
  `list/invoke/result/cancel` use owned page events; descriptions and results are
  untrusted website content. Parameters can be inline JSON or bounded CLI input.
  After `command` page operations (except WebMCP/init) and `action snapshot`, CtrlX
  asks the same private daemon for its catalog without invoking any tool. Changes
  appear in `webmcp` metadata (max 16 entries / 4 KiB, untrusted, schemas omitted);
  unchanged catalogs are suppressed and navigation/removal can emit an empty catalog.
  Read full schemas with explicit `list`. Discovery failure reports unavailable
  metadata without failing/replaying the completed page action (2 s socket timeout).
  Upstream's preliminary provider launch consumes its own proactive response, so
  `--no-webmcp` remains pinned and the adapter handles delivery. No MCP server is started.
- `record` is bounded WebM/MP4 capture (1–10 s requested, configurable 1–60 fps,
  default 10). Optional cursor overlay and PNG contact sheet reuse upstream;
  `--contact-sheet-threshold` is 0–1 (default 0.05), combined outputs max 6 MiB.
  Optional validated `--commands-json` runs during capture; a slow command can
  extend the requested duration, but the native attachment expires after 15 s.
  Only existing Homebrew ffmpeg at `/opt/homebrew/bin/ffmpeg` or
  `/usr/local/bin/ffmpeg` is exposed via a private PATH link. No automatic install,
  indefinite start/stop or recording-to-Skill product UI. Video/sheet paths must
  both be new; multi-file export is not atomic and may leave the completed video
  if exporting the sheet fails. No capture is automatically repeated.

## Isolation and lifecycle

- Codex kernel PID/start time remains the authority. Pane/session labels only
  determine where the existing native view is shown.
- The host mints a random capability for an exact live owner/tab. Its CEF server
  binds only `127.0.0.1` on an ephemeral port, with no target discovery or HTTP
  dashboard. Origin-bearing WebSocket requests are refused. Every CDP command,
  reply and forwarded event checks native ownership/liveness; only one connection
  may consume each capability. Close/owner exit/restart invalidates it.
- The engine gets a direct-page provider, not a browser endpoint. The native
  whitelist rejects arbitrary Target control, browser close, global cookie/storage
  export and browser-wide tracing. Iframe-only auto-attachment learns child
  sessions from this exact CefBrowser; unknown/cross-tab sessions are refused.
  Renderer frame trees are merged within that lineage for OOPIF selection.
  A recording may attach only the exact root target reported by that browser,
  once, with a native 15-second expiry. No target discovery or worker attachment.
  Page-scoped Network/Fetch/Runtime events are forwarded
  with `sessionId: ""`, matching upstream directPage event tracking (omitting the
  field silently loses events). `eval` runs page JavaScript, not native code/CDP.
  Upstream `Network.getAllCookies` is translated to `Network.getCookies` for the
  current URL; writes must match the page host. It never dumps the shared profile.
- Download setup is intercepted, **not** forwarded as browser-global settings.
  A per-tab CEF handler admits one download per 30-second request into the private
  engine directory, caps bytes and emits scoped completion events. CLI exports
  via exclusive creation. Managed dialogs use CEF callbacks, not AppKit modal
  loops; acceptance/dismissal, disconnect/owner-exit cancellation and reset are
  scoped to that browser. Engine disconnect/revocation also disables Fetch so
  orphaned interceptions cannot leave the native page blocked forever. It removes
  registered future init scripts, stops capture and detaches iframe sessions.
- One managed upstream session per owned tab preserves refs without sharing a
  focused target. Both engines take the same per-tab CLI lock. Different tabs
  remain independent. Host navigation can interrupt actions; it is not retried.
- The private engine directory/config and provider credentials are mode 0700/0600.
  The process environment is allowlisted and the executable SHA-256 is verified
  before use; inherited providers/CDP/autoconnect/cloud credentials are ignored.
  Original upstream preview streaming is disabled before attaching a page.
- Every invocation pins the same provider and launch flags, including daemon
  bootstrap. A changed upstream launch fingerprint must never fall back to
  launching a separate default Chrome. Native regression checks the product
  daemon's preview state directly without changing its CLI startup settings.
- Idle upstream daemons exit after five minutes. Pages belong to CtrlX and stay
  open. Snapshot refs expire with navigation/daemon state; an expired daemon's
  `@ref` mutation is refused until the caller obtains a new snapshot.
- CLI timeout is 30 seconds with bounded file output; native CDP deadline is
  10 seconds, public command input 48 KiB, private CDP messages 2 MiB (vendored
  axe-core injection), results 8 MiB. Shutdown awaits the CEF server's
  completion before CEF teardown. No new Swift UI/main-actor polling is involved.

This is routing isolation, not a hostile same-UID sandbox. The website profile
remains shared; login/logout affects all instances. Snapshots can reveal more
page content than the original bounded read—do not assume identical redaction.

## Deliberate adapter limits

The [upstream capability audit](agent-browser-capability-audit.md) records actual
coverage and known gaps. Defaulting to Vercel does **not** expose its full CLI.

This is not every upstream capability/option on every runtime. Full-profile state
export/restore, global cookie clearing, trace/profiler, cloud/iOS runtimes, external
browsers and plugin/provider administration remain excluded. **Both** upstream
`trace` and `profiler` use browser-wide `Tracing` in 0.38.1, not page-scoped CPU
profiling. Opening them requires a separate scope/consent design; filtering the
output after global collection is not page isolation.

Geo setting still depends on site permission; device emulation is not a complete
physical phone. OOPIF pointer input under mobile emulation is explicitly refused:
the fixture observed a successful click response with no page effect. Restore a
desktop viewport with `set viewport W H` before child-frame pointer actions. Upstream
`eval` still uses the root document after `frame`; child readback uses `get` or
`snapshot`. CSS frame selection depends on the iframe name; use the explicit
`--name`/`--url` adapter for nested/unnamed frames. `wait --state hidden` remains
defective in 0.38.1: use existing `action wait --state hidden`. No global clipboard.

## Build, validation and updates

`scripts/build-agent-browser.sh` prepares both native runtime and the pinned
upstream binary/license. `scripts/prepare-agent-browser-engine.sh` verifies the
download and cached artifact before copying it to bundle resources. Do not
re-sign that resource binary without also revisiting the byte-level integrity
contract. Existing distribution archive gates remain in place pending transitive
license audit and hardened-runtime/notarization validation.

Tests:

```sh
swift test --package-path CtrlxPackage --filter 'AgentBrowserEngineTests|AgentBrowserIdentityTests'
python3 CtrlxPackage/AgentBrowser/tests/cli.py CtrlxPackage/.build/debug/GallagerCLI
clang++ -std=c++20 CtrlxPackage/AgentBrowser/tests/engine_identity.cc -o /tmp/codex
python3 CtrlxPackage/AgentBrowser/tests/managed_engine.py \
  '<isolated signed CtrlX.app with updated native library and CtrlXCLI>' \
  '<that app>/Contents/Resources/AgentBrowserEngine/agent-browser' /tmp/codex
python3 CtrlxPackage/AgentBrowser/tests/page_capabilities.py \
  '<isolated signed CtrlX.app with updated native library and CtrlXCLI>' \
  '<that app>/Contents/Resources/AgentBrowserEngine/agent-browser' /tmp/codex
python3 CtrlxPackage/AgentBrowser/tests/expanded_capabilities.py \
  '<isolated signed CtrlX.app with updated native library and CtrlXCLI>' \
  '<that app>/Contents/Resources/AgentBrowserEngine/agent-browser' /tmp/codex \
  '<React 18.3.1 UMD fixture assets directory>'
```

The isolated app must use bundle ID `com.ctrlx.embedded-acceptance`. Build the
normal native library (no `CTRLX_UPSTREAM_BROWSER_PROBE` flag); install the updated
CLI and prepared engine resources in that copy and sign it. Never overwrite the
installed app to run this harness. It uses a fresh profile/tmux server and real
kernel ancestry via **native Codex-named fixtures, not real Codex**. Keychain
prompts are always user-operated. See `managed_engine.py` for assertions.
The expansion suite includes the previous page-capability regression by default.
It requires `websockets`, local ffmpeg/ffprobe, and React 18.3.1 development UMD
files named `react.js` and `react-dom.js` (upstream packages' `umd/*.development.js`).
These test-only assets are served on loopback, not bundled into the product.

Upstream is not forked. To update, change the pinned version/hash in preparation
and `ManagedAgentBrowser`, refresh license/dependency review, run both engines'
unit/CLI/native acceptance tests, and rebuild. No runtime `latest` upgrade.

### Local validation (2026-09-27)

- 18 focused Swift tests (2 suites; parameterized key cases included) passed.
- Existing CLI refusal/parsing/quoting checks and skill validation passed.
- Normal native library + updated CLI built and signed in an isolated app;
  managed acceptance passed using the actual bundled engine and native gateway.
  Covers both engines on the same page, AX refs, trusted Chinese fill/click,
  type/press/select/idempotent check, shared login, child tabs, screenshot,
  navigation, cross-owner/global-CDP/Origin refusal, expired refs and owner exit.
- Evidence: `/tmp/ctrlx-managed-engine-3.log`, with its printed private artifact
  directory's `summary.json` and `managed.png`. The app exited normally. This
  remains fixture acceptance, not a new real-Codex end-to-end result.
- No production app replacement, commit, push or release was performed.

### Default and broader capability audit (2026-09-28)

Vercel is now the default; saved original-engine choices survive. All managed
invocations pin the same provider/launch flags. 19 focused Swift tests and the
17-check native dual-engine regression passed, including preview-disabled state.
The separate [capability audit](agent-browser-capability-audit.md) has 177 records,
with errors, response-only checks and explicit omissions retained. It is **not**
a claim that all upstream capabilities are supported or verified in CtrlX.

### Public page-capability expansion (2026-09-28)

The new `page_capabilities.py` acceptance invokes **public CtrlX commands**, not
raw upstream shortcuts. DOM effects, uploaded file contents, downloaded bytes,
PNG/PDF signatures, actual log/error/network events, mocked and restored responses,
HAR entries, HTTP headers/auth, viewport/media/device/offline effects, iframe
content, real prompt answers, cookie host isolation, history, Vitals and axe
violations are asserted. The host exits normally; no production app replacement.
See [audit follow-up](agent-browser-capability-audit.md#补齐后的公共入口验收) for evidence.

### Managed expansion acceptance (2026-09-28)

34 related Swift tests, CLI parsing/refusal tests and skill validation pass.
`expanded_capabilities.py` passes 28 checkpoints including prior page regressions;
`managed_engine.py` passes 18 including both backends, malformed emulation options,
exact-target capture, expiry and stale-session refusal. Both isolated hosts exit
normally. These are real CEF/public-CLI effects with native identity fixtures,
not a new real-Codex reasoning acceptance. Current evidence and explicit partial
support are at the top of the [capability audit](agent-browser-capability-audit.md).
