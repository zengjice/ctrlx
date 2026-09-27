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
ctrlx browser command --tab <id> -- console
ctrlx browser command --tab <id> -- set viewport 640 480
ctrlx browser command --tab <id> --output /tmp/new.pdf -- pdf
ctrlx browser command --tab <id> --output /tmp/new.png -- screenshot --full --annotate
ctrlx browser command --tab <id> --output /tmp/new.txt -- download '#download'
```

The root catalog is printed by `command --help`. It covers interaction/get/is/find,
scrolling, waits, page JS, DOM reading, same-origin frames, history, dialogs,
local/session storage, page-host cookies, file input/download/PDF/PNG, console/errors,
request tracking/interception/HAR, headers/HTTP auth, emulation, snapshot diff,
Web Vitals and axe accessibility audits. Options for CtrlX precede `--`.
`vitals` reloads the page. Network tracking/HAR should be started before the traffic
being measured. Artifact output requires a new path, max 6 MiB.

Commands are allowlisted before ownership/engine access, then encoded as a
single-command JSON batch on stdin to the unchanged upstream binary. There is
no shell execution or global argv passthrough; empty strings, quotes, newlines,
Unicode and flag-looking text are preserved. Only the fixed screenshot output
flag `--annotate` is lifted into upstream argv. Providers and launch flags remain
identical on every call. Each mutating batch here contains exactly one command.

## Isolation and lifecycle

- Codex kernel PID/start time remains the authority. Pane/session labels only
  determine where the existing native view is shown.
- The host mints a random capability for an exact live owner/tab. Its CEF server
  binds only `127.0.0.1` on an ephemeral port, with no target discovery or HTTP
  dashboard. Origin-bearing WebSocket requests are refused. Every CDP command,
  reply and forwarded event checks native ownership/liveness; only one connection
  may consume each capability. Close/owner exit/restart invalidates it.
- The engine gets a direct-page provider, not a browser endpoint. The native
  whitelist rejects Target control, browser close, global cookie/storage export
  and browser-wide tracing. Page-scoped Network/Fetch/Runtime events are forwarded
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
  orphaned interceptions cannot leave the native page blocked forever.
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

This is not every upstream capability/option on every runtime. Cross-process
iframe attachment, full-profile state export/restore, global cookie clearing,
trace/profiler, video recording/ffmpeg, React hook injection, WebMCP, cloud/iOS
runtimes, external browsers and plugin/provider administration remain excluded.
They require separate lifecycle/security/dependency work, not more page-method
whitelisting. Same-origin iframe operations are verified. Geo setting still
depends on site permission; device emulation follows upstream viewport/UA behavior,
not a full physical phone or touch emulation. PNG `--full`/`--annotate` and in-memory
snapshot diff are exposed; JPEG/element/conditional screenshot and file-baseline
diff options are not. Upstream hidden-element wait remains defective in 0.38.1:
use the existing `action wait --state hidden`. No global clipboard control.

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
```

The isolated app must use bundle ID `com.ctrlx.embedded-acceptance`. Build the
normal native library (no `CTRLX_UPSTREAM_BROWSER_PROBE` flag); install the updated
CLI and prepared engine resources in that copy and sign it. Never overwrite the
installed app to run this harness. It uses a fresh profile/tmux server and real
kernel ancestry via **native Codex-named fixtures, not real Codex**. Keychain
prompts are always user-operated. See `managed_engine.py` for assertions.

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
