---
name: ctrlx-cli
description: Inspect or control CtrlX sessions, windows and panes with the ctrlx CLI; send input, notifications, or manage layouts and installed plugins.
---

# CtrlX CLI

`ctrlx` controls the local CtrlX Mac app over a Unix socket. Prefer it to raw
tmux for operations it exposes. Use `ctrlx <command> --help` for flags supported
by the installed version; read only the reference needed for the task below.

## Connect and resolve the target

```bash
ctrlx ping
ctrlx identify --json
ctrlx list-sessions --json
ctrlx list-windows --session work --json
ctrlx list-panes --window work:0 --json
```

- Use IDs returned by these commands, not example IDs: sessions are names,
  windows are `session:index`, panes are `%N`.
- Most contextual commands infer the calling pane from `$TMUX_PANE`. Outside
  tmux, defaults may fall back to the active UI target; specify the target.
  `current-session` returns the first attached session, **not** necessarily the
  caller's or the UI selection; use `identify` for caller context.
- Target flags are command-specific even though help lists shared options:
  `send` uses `--pane`; window creation uses `--session`; pane listing uses
  `--window`; session labels use `--session` (not `--pane`/`--window`).
- Socket priority: `--socket` → `$CTRLX_SOCKET` → `$TMPDIR/ctrlx.sock`.
  This is **not** the tmux socket; do not pass it to `tmux -S`.

If the CLI is missing, check `/Applications/CtrlX.app/Contents/MacOS/CtrlXCLI`
or ask for **CtrlX → Install Command Line Tool…**. If unreachable, check the
app/socket; `wait-ready --timeout 30` waits for an expected startup. On
`not_found`, re-list once and resolve a fresh target; do not retry stale IDs.

## Common operations

| Intent | Command (replace example targets) |
|---|---|
| Read visible output | `ctrlx capture-pane --pane %3` |
| Create a session/window | `ctrlx new-session --name work --path /path/to/project`; `ctrlx new-window --session work --name logs` |
| Split / focus | `ctrlx split-pane right --pane %3`; `ctrlx select-pane %5` |
| Switch session/window | `ctrlx select-session work`; `ctrlx select-window work:1` |
| Rename a window tab | `ctrlx rename-window work:1 logs` |
| Type / submit / key | `ctrlx send 'text' --pane %3`; add `--enter` to submit; `ctrlx send-key enter --pane %3` |
| Close a window/session | `ctrlx close-window work:1`; `ctrlx close-session work` |

Inspection does not authorize input or closing sessions. `send` is literal text
without Enter unless `--enter` is given; submitting may execute a shell command.
Closing a window/session terminates its processes. Verify scope before either.

Capture the visible screen first; use `--scrollback` only for needed history.
For scripting, most `--json` results are `{id, ok, result}`; check exit status and
`ok` before using `.result`. Capture JSON contains `.result.content`.
`find-emoji --json` instead returns a bare array; `edit` produces no JSON result.

## Task-specific references

- [Session labels, progress, notifications, prompt editor and projects](references/workflows.md).
- [Reusable layouts, idempotent creation and raw tmux fallback](references/layouts.md).
- [Installed plugin inspection, trust, updates and removal](references/plugins.md).
- [Reading collaboration attachments, sharing artifacts and requesting completion](references/workflows.md#agent-collaboration).
- [Direct socket requests and response fields](references/api-reference.md).

Do not read all references for a simple command. Creating a new sidecar is a
different task from managing installed plugins; use `create-agent-plugin` if available.
