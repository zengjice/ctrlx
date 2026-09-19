# CtrlX CLI socket API

Read for direct socket clients or JSON response fields. Ordinary CLI usage should
use command `--help`; layout and plugin workflows have separate references.
This API is **not** the sidecar stdio RPC or the hook-ingress socket.

## Wire protocol

AF_UNIX/SOCK_STREAM; each request/response is one JSON object followed by `\n`.
A connection can carry multiple requests. The CLI normally uses one per call.
Socket selection is `--socket` → `$CTRLX_SOCKET` → the system temp directory's
`ctrlx.sock`. Raw socket clients must supply context themselves; the CLI injects
`pane_id` from `$TMUX_PANE` only for commands that support it.

```json
{"id":"request-1","method":"pane.capture","params":{"pane_id":"%3"}}
```

```json
{"id":"request-1","ok":true,"result":{"content":"pane output\n"}}
```

```json
{"id":"request-1","ok":false,"error":{"code":"not_found","message":"Pane not found"}}
```

Echoed `id` correlates responses. Errors include `not_found`, `invalid_params`,
`method_not_found`, `internal_error`; layout adds `validation_error` and
`session_exists`. Check `ok` and error details, not just presence of stdout.
Transport/validation failures, plugin errors and layout errors may be stderr-only
in CLI JSON mode. `find-emoji --json` is a local array; `edit` emits no envelope.

## Response objects

The CLI API builds these dictionaries with **snake_case** fields (unlike
sidecar `PluginEvent`'s camelCase fields). IDs refer to real local tmux objects.

```json
{
  "session": {"id":"work","name":"work","window_count":1,"is_attached":true},
  "window": {"id":"work:0","index":0,"name":"build","pane_count":1,"is_active":true,"session_id":"work"},
  "pane": {"id":"%3","index":0,"is_active":true,"command":"claude","cwd":"/path/to/project","width":120,"height":40,"window_id":"work:0","has_agent_session":true}
}
```

`system.identify` returns this container; any of its three entries can be null.
Session IDs are session names, window IDs are `session:index`, pane IDs are `%N`.
Pane `command` and `cwd` can be null. Discovery arrays contain the corresponding
objects below, without the surrounding `session`/`window`/`pane` keys.

## Methods

In the tables, `?` marks optional params; **Ack** is `{"ok":true}` inside `result`.
A target is not implicit in the wire protocol: pass `pane_id`/`session_id`/`window_id` as
appropriate. Check `system.capabilities` on the installed host for availability.

### System and discovery

| Method / CLI | Params | Result |
|---|---|---|
| `system.ping` / `ping` | `{}` | `{pong: true}` |
| `system.capabilities` / `capabilities` | `{}` | `{methods: [string]}` |
| `system.identify` / `identify` | `{pane_id?: string}` | `{session, window, pane}` as above |
| `session.list` / `list-sessions` | `{}` | `{sessions: [session]}` |
| `session.current` / `current-session` | `{}` | First attached session; not necessarily the caller's or the UI selection |
| `window.list` / `list-windows` | `{session_id?: string, pane_id?: string}` | `{windows: [window]}` |
| `pane.list` / `list-panes` | `{window_id?: string, pane_id?: string}` | `{panes: [pane]}` |
| `pane.capture` / `capture-pane` | `{pane_id?: string, scrollback?: bool}` | `{content: string}` |

For `window.list`/`window.create`, `session_id` wins over `pane_id`; for
`pane.list`, `window_id` wins over `pane_id`. The CLI falls back to the caller's
pane for these commands. `identify` sends `$TMUX_PANE`; `current-session` sends
no context. `capture-pane` is plain text by default, an envelope with `--json`.
`wait-ready` polls `system.ping` (default timeout 30s, interval 0.2s); it exits
nonzero on timeout rather than sleeping indefinitely.

### Session/window/pane mutations

| Method / CLI | Params | Result |
|---|---|---|
| `session.create` / `new-session` | `{name?: string, path?: string, title?: string, color?: string, if_missing?: bool}` | Session object plus `created: bool` |
| `session.select` / `select-session` | `{session_id: string}` | Ack |
| `session.close` / `close-session` | `{session_id: string}` | Ack |
| `window.create` / `new-window` | `{session_id?: string, pane_id?: string, path?: string, name?: string}` | Window object |
| `window.select` / `select-window` | `{window_id: string}` | Ack |
| `window.set_name` / `rename-window` | `{window_id: string, name: string}` | Ack |
| `window.close` / `close-window` | `{window_id: string}` | Ack |
| `pane.split` / `split-pane` | `{pane_id?: string, direction?: string, path?: string, shell?: string}` | New pane object |
| `pane.select` / `select-pane` | `{pane_id: string}` | Ack |
| `pane.set_layout` / API only | `{target: string, layout: string}` | Ack; `window_id` may replace `target` |

`if_missing` requires `name`; an existing session returns `created: false`.
Use that flag to avoid creating duplicate panes or rerunning initialization.
Window names must be nonempty. Split directions are left/right/up/down (default
right); `shell` starts that process instead of the default shell.

### Labels and feedback

| Method / CLI | Params | Result |
|---|---|---|
| `session.set_title` / `set-title` | `{title?: string, session_id?: string, pane_id?: string}` | Ack |
| `session.set_color` / `set-color` | `{color?: string, session_id?: string, pane_id?: string}` | Ack |
| `session.set_emoji` / `set-emoji` | `{emoji?: string, session_id?: string, pane_id?: string}` | Ack |
| `session.set_state` / `session-state` | `{state: string, session_id?: string, pane_id?: string}` | `{applied_to: int}` |
| `pane.set_progress` / `set-progress` | `{value: string, pane_id?: string}` | Ack |
| `notification.create` / `notify` | `{title: string, body: string, pane_id?: string, push?: bool}` | Ack |

Title/color/emoji always affect a whole session. The API can resolve `pane_id`
to its session, but the label CLI verbs accept only `--session` as an explicit
target, otherwise using `$TMUX_PANE`. Emoji names/keywords are resolved in the
CLI; the socket receives the glyph. See [workflows](workflows.md) for accepted
values, clearing labels, progress overrides and local versus iOS notifications.

### Input, editor and projects

| Method / CLI | Params | Result |
|---|---|---|
| `input.send_text` / `send` | `{text: string, pane_id?: string, enter?: bool}` | Ack |
| `input.send_key` / `send-key` | `{key: string, pane_id?: string}` | Ack |
| `editor.open` / `edit` | `{pane_id: string, file_path: string}` | Ack after editing finishes; CLI prints nothing |
| `project.list` / `list-projects` | `{}` | `{projects: [project]}` |
| `project.start` / `start-project` | `{path: string, args?: [string], plugin_id?: string}` | Session object |

Text is literal; `enter: true` appends Enter. Named keys: enter/tab/escape/
backspace/delete/up/down/left/right/space. The CLI's `edit` requires `$TMUX_PANE`
and blocks until the user finishes. Prefer an absolute file path.

Projects come from enabled plugins. Each contains `id`, `name`, `path`,
`plugin_id`, and ISO-8601 `last_used` (or null). `project.start` defaults to
`plugin_id: "codex"`; the CLI accepts `--agent <plugin-id>` to override it. Nonempty `args`
replace the plugin's default launch arguments. Missing/non-directory project
paths fail with `not_found`.

### Layouts, environment and plugins

`layout.apply` takes `{config, config_path?, rebuild?, detach?, dry_run?,
lenient?, require_create?}` and returns `{session_name, created, warnings,
planned_actions}`. Use the CLI to parse YAML/JSON and follow [layouts](layouts.md)
for idempotence, dry runs and destructive rebuild behavior.

`system.set_env` takes `{session_id: string, vars: {NAME: string|null}}` and returns
Ack; null unsets a variable. It has no dedicated CLI verb.

For `plugin.*` prefer the CLI and [plugin workflows](plugins.md), especially the
trust step. These methods have their own mixed-case fields; do not infer their
wire schema from the session tables or from sidecar stdio RPC.
