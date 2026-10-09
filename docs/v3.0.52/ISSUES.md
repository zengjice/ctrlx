# Viewer browser acceptance follow-ups

## Remaining acceptance

- Physical Mac Viewer ↔ Host and iPhone touch/Chinese IME testing has not been
  performed. The connected iPhone Air was unavailable during this implementation.
  Compile checks and native CDP text injection do not substitute for that UI test.
- Measure terminal latency under a throttled real link while sharing a page.
  Automated encrypted-loopback tests cover concurrent stalled captures, ordered
  keyboard progress and disconnect cleanup, not real WAN bandwidth/jitter.
- `expanded_capabilities.py` did not complete: repeated isolated runs sometimes
  reject a native fixture with “This Codex is not inside a local CtrlX tmux pane”.
  Failure diagnostics show both fixture PIDs still directly below their respective
  pane shells. Root cause is not established; do not call this a confirmed fixture
  issue or change the authority checks to work around it. The full `managed_engine.py`
  regression and focused native remote-surface test passed. Keep this gap explicit.
  Evidence: `/tmp/ctrlx-remote-browser-expanded-regression3.log`.

## First-version limits

- Chromium only; no migration/sharing of WebKit or existing Viewer-local pages.
- Bounded JPEG page sharing, not high-frame-rate video/audio streaming.
- No system/file dialogs, remote DevTools or Host clipboard readback.
- Closing CtrlX still ends its transient Chromium tabs; no restart restoration.
- Explicit Fit changes the Host page for everyone. Host resizing/reattaching the
  page can resize it again; there is no persistent viewport override or emulation.

No production application was replaced, no Relay was deployed, and no release
was published during implementation or validation.
