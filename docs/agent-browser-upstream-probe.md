# Upstream agent-browser compatibility proof

Historical feasibility checkpoint. The subsequent product adapter is
documented in [dual engines](agent-browser-engines.md); Vercel is now the default,
with the original engine retained. The test-only bridge below is not used by that adapter.

## Result (2026-09-27)

The unmodified official **agent-browser 0.38.1 darwin-arm64** binary successfully
controlled real native CEF child views inside an isolated CtrlX acceptance app.
No system Chrome, standalone browser window, ChatGPT extension or MCP was used.
This proves the engine-adapter route is feasible, **not a finished integration**.
The installed `/Applications/CtrlX.app`, live sessions and personal browser
profile were not changed. Test agent identities are native fixture processes,
not real Codex processes. The production `ctrlx browser` backend is unchanged.

Primary upstream contracts:
[release](https://github.com/vercel-labs/agent-browser/releases/tag/v0.38.1),
[browser.provider / directPage](https://github.com/vercel-labs/agent-browser/blob/v0.38.1/docs/src/app/plugins/page.mdx).
The binary is pinned by SHA-256:
`2e61287259053ea964d39e77002c6a34af0e589e55ccff25e659efae7e892e0d`.

Thirteen assertions passed, followed by a completion marker:

- Native embedding and source-session routing with two independent owners.
- Upstream accessibility snapshots and element references.
- Reference-based fill/click with trusted Chinese input.
- Opposing focus does not redirect input to another owner's page.
- Shared fixture localStorage, persistent cookies and session cookies.
- Upstream operations continue after CtrlX-managed navigation.
- Child tabs inherit their owner's session; independent per-tab engine state,
  parent DOM preservation and cross-owner refusal.
- PNG screenshot of the native embedded page.
- Native cross-owner read/input rejection, independent of proxy routing.
- Browser-wide target enumeration/attach, cookie export and close rejection.
- Unauthenticated gateway connection rejection.
- Engine disconnect leaves CtrlX and its native tabs alive.
- Closed targets fail instead of falling back to another tab.

Evidence from the final run: `/tmp/ctrlx-upstream-probe-4.log`. Its printed private
artifact directory contains `summary.json`, `commands.json` and `upstream.png`.
The host stopped normally (`hostStopped: true`). Do not publish `*-provider.json`,
`endpoint.json` or private state: they contain test credentials.

## Reproduce without replacing CtrlX

Requires Apple Silicon, a current embedded-browser CtrlX app built from matching
sources/CEF, its cached CEF SDK/wrapper, an Apple Development signing identity,
Python 3.9+ with `websockets >= 15`, and tmux at `/opt/homebrew/bin/tmux`.
No simulator or Chrome download is needed. The preparation downloads only the
pinned upstream executable and APFS-clones the source app.

```sh
bash CtrlxPackage/AgentBrowser/tests/prepare_upstream_probe.sh /path/to/CtrlX.app
# Run the exact python3 command printed by preparation.
```

Preparation only changes its new `.build-local/upstream-browser-proof.XXXXXX`
directory. It compiles `CTRLX_UPSTREAM_BROWSER_PROBE` into that copy's native
library, sets a distinct test bundle ID and verifies its signature. The harness
also requires `--e2e-test`, uses a fresh private profile/state and dedicated tmux
socket, and refuses another live E2E host. Run only one acceptance host at a time.
Any macOS Keychain authorization is user-operated. A first-load timeout keeps
the exact test host alive for diagnosis; quit that isolated app manually before
retrying. Normal completion quits only the acceptance app and its own daemons.

## What must remain CtrlX-owned

The test uses the upstream provider's `directPage: true`: each engine session
gets a tokenized loopback WebSocket bound to one exact native owner/tab. CtrlX
retains tab creation, selection, close, source routing and shared profile. A
child gets another scoped engine session. No browser-wide debug port is exposed.
Native ownership validation still runs on every command/event read.

The probe forwards upstream-generated page JavaScript **only in the disposable
test app**. Its broad test domain allowlist is not a reviewed production policy.
Normal builds do not enable the compile flag. Do not distribute the probe app.

Compatibility details discovered by running the actual engine:

- Read-only `Browser.getVersion` must work for its liveness check; denying it
  causes reconnects and invalidates snapshot references.
- Pass provider launch flags only when starting a scoped engine session; reuse
  that session for later commands so reference state remains stable.
- Upstream enables a preview stream; the fixture disables it after attach.
  A production integration needs an explicit preview/network policy from start.
- It probes `WebMCP.enable` despite the launch option used here; the gateway
  refuses it and the tested ordinary CDP operations still work.

Before product integration: implement/review the managed adapter behind the
unchanged `ctrlx browser` interface; explicitly map tab lifecycle and errors;
define the supported command/CDP surface, output bounds, concurrency, timeouts
and revocation behavior; prevent configuration/provider escape to other browsers;
then test with real Codex and validate packaging/licensing/notarization.
Uploads, downloads, cross-origin frames, dialogs, browser-level state export and
the entire upstream command catalog are **not validated** by this proof.
Track upstream releases with pinned versions/checksums and regression checks;
do not silently execute an untested `latest` binary or maintain a fork by default.
