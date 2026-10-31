# CtrlX CLI API Reference

`ctrlx` is a command-line interface for controlling the CtrlX macOS app. It communicates with the app over a Unix domain socket using JSON-RPC, enabling programmatic control of sessions, windows, panes, input, and notifications from scripts or shell environments.

---

## Quick Start

```bash
# Check that CtrlX is running
ctrlx ping

# List all tmux sessions
ctrlx list-sessions

# Create a new session and switch to it
ctrlx new-session --name work
ctrlx select-session work

# Send text to the active pane
ctrlx send "echo hello\n"

# Send a desktop notification from a script
ctrlx notify --title "Build done" --body "Tests passed"

# Same notification, also pushed to paired iOS devices
ctrlx notify --title "Build done" --body "Tests passed" --push

# Open a file in the in-app prompt editor (blocks until submitted)
ctrlx edit /tmp/prompt.txt
```

---

## Configuration

### Socket Path Resolution

`ctrlx` connects to the app through a Unix domain socket. The path is resolved in this order:

1. `--socket <path>` flag (highest priority)
2. `$CTRLX_SOCKET` environment variable
3. `$TMPDIR/ctrlx.sock` (fallback for manual use outside a managed session)

Inside CtrlX-managed tmux sessions, `$CTRLX_SOCKET` is set automatically. Scripts running in those sessions do not need any additional configuration.

### Output Format

By default, commands print human-readable output. Pass `--json` to receive raw JSON-RPC response objects, which is useful for scripting and piping into `jq`.

```bash
ctrlx list-sessions --json | jq '.result.sessions[].name'
```

---

## Commands

### Agent Workflows

`workflow attachments` returns the files authorized for the current accepted
Agent invocation:

```bash
ctrlx workflow attachments --invocation '<UUID supplied with the task>' --json
```

**JSON-RPC:** `workflow.attachments`, with only `invocationId` (UUID string).
The Host verifies socket process ancestry, the live Agent binding and current
run authorization, then verifies each file's size, format and SHA-256. It checks
the binding and authorization again before returning. The result contains
`invocationId` and `attachments`, whose entries contain `id`, `name`, `mediaType`,
`sha256`, `path` and `readWith`. Paths refer to this Host's imported copies, not
the Viewer's filesystem. Converted files also include `conversion` with
`sourceName`, `sourceSHA256` and `description`. This describes provenance, not
permission to read the retained original. Video samples and their notes must be
read together; the notes identify sampling limits and excluded audio.
Images (PNG/JPEG, up to 20 MiB) must be inspected using
the Agent's image-reading tool; text (UTF-8 plain text/Markdown, up to 2 MiB)
must be read in full. Audio/video require explicit conversion. This command
always prints JSON and permits a response up to 256 KiB within 30 seconds.
It does not grant arbitrary file access or prove that an Agent read the files.
Pausing handoffs retains access for an already accepted, still-running invocation.
Expired, ended, unaccepted and completed invocations cannot read files.
Target overrides and self-reported caller identities are not accepted.

`workflow share` snapshots one local artifact for the current invocation:

```bash
ctrlx workflow share --invocation '<UUID supplied with the task>' --file report.md --json
```

Share required files before providing the final answer. The CLI reads a regular
file, checks for changes while reading, and sends 64 KiB chunks with a SHA-256
digest. It never asks the Host to open a caller-supplied path. Supported formats
are PNG/JPEG, UTF-8 text/Markdown, WAV/MP3/M4A and MP4/MOV, up to 1 GiB per file;
the receiving Agent's reading or conversion limits still apply. Storage success
does not prove model media support.

**JSON-RPC:** `workflow.artifact`, common params `invocationId`, `uploadId` (UUID
strings) and `action`: `begin` adds `name`, `mediaType`, `size`; `append` adds
`offset` and Base64 `data`; `finish` adds `sha256`; `cancel` adds no fields.
The Host checks the socket caller, active accepted invocation and live binding
before and after disk I/O. The upload belongs to that invocation; another
invocation cannot adopt or cancel it. Finish records the attachment metadata and
invocation reference atomically. Up to 32 artifacts can be shared per invocation.
They become downstream input only after verified successful completion; fan-out
reuses the same immutable IDs, and fan-in keeps configured source order.

Receipts contain `invocationId`, `uploadId`, `offset`; finish also includes
`artifact` with `id`, `name`, `mediaType`, `size`, `sha256`. The CLI prints only
the final receipt, always as JSON. Each request has a 30-second timeout and
64 KiB response limit. Failed transfers attempt cancellation without resending
chunks. A lost finish reply may mean the artifact was already saved: inspect
the workflow record before sharing again. Mentioning a path in prose does not
publish an artifact. An accepted invocation can keep sharing while handoffs are
paused; the snapshots stay with its result until an operator continues the run.
Expired, ended and completed invocations cannot publish new artifacts; an already
committed snapshot is never overwritten.

`workflow finish` requests completion of the current, explicitly authorized
workflow invocation. Workflow creation and the full runtime are still under
development; this command alone does not start a workflow.

```bash
ctrlx workflow finish --invocation '<UUID supplied with the task>' --reason 'Review passed'
```

**JSON-RPC:** `workflow.finish`, params `invocationId` (UUID string) and `reason`
(nonblank UTF-8 text, maximum 8192 bytes). No other params are accepted. The Host
reads caller identity from the Unix socket and verifies the live Agent process,
conversation and run grant. Claimed process IDs or pane IDs cannot grant access.
The command must originate from the authorized Agent's process tree; ordinary
Viewer commands cannot impersonate that caller.

Success returns `runId`, `invocationId`, `status` and a `message`.
It means the request was saved and new handoffs have stopped. The Agent must still
provide its final answer; completion requires the Host's native result check.
The status is `finishing` unless the workflow was already paused. A paused run
retains the request and final answer without advancing; an operator must continue
it before completion is settled. The command never resumes a paused workflow.
Repeating the same active invocation does not replace its accepted reason.
Expired, ended, superseded or unauthorized invocations return
`workflow_denied`. `--pane`, `--session` and `--window` overrides are rejected.
The CLI allows 30 seconds for the response and at most 64 KiB of response data;
transport failure is reported without automatically repeating the command.

### Sessions

#### `list-sessions`

List all tmux sessions managed by CtrlX.

```bash
ctrlx list-sessions
```

**JSON-RPC**
- Method: `session.list`
- Params: _(none)_
- Response:
```json
{
  "id": "1",
  "ok": true,
  "result": {
    "sessions": [
      { "id": "main", "name": "main", "windowCount": 3, "isAttached": true },
      { "id": "work", "name": "work", "windowCount": 1, "isAttached": false }
    ]
  }
}
```

---

#### `new-session`

Create a new tmux session. Use `--path` to set the starting directory for the first pane; if omitted, the session opens in the user's home directory. Use `--title` to set the sidebar description and `--color` to set the sidebar dot at creation time so a single command lands the session fully labelled.

```bash
ctrlx new-session
ctrlx new-session --name myproject
ctrlx new-session --name myproject --path /Users/me/code/myproject
ctrlx new-session --name myproject --title "My project" --color blue
```

Valid colors: `red`, `orange`, `yellow`, `green`, `blue`, `purple`, `pink`, `gray`. Aliases `violet` (→ purple), `magenta` (→ pink), and `grey` (→ gray) are accepted; case is ignored.

**JSON-RPC**
- Method: `session.create`
- Params: `{ "name": "myproject", "path": "/Users/me/code/myproject", "title": "My project", "color": "blue" }` _(all optional; `path` defaults to `$HOME`; unknown color names return `invalid_params`)_
- Response:
```json
{
  "id": "2",
  "ok": true,
  "result": { "id": "myproject", "name": "myproject", "windowCount": 1, "isAttached": false }
}
```

---

#### `select-session <id>`

Switch the app to a session by ID.

```bash
ctrlx select-session work
```

**JSON-RPC**
- Method: `session.select`
- Params: `{ "session_id": "work" }`
- Response: `{ "ok": true }`

---

#### `current-session`

Show the currently active session.

```bash
ctrlx current-session
```

**JSON-RPC**
- Method: `session.current`
- Params: _(none)_
- Response:
```json
{
  "id": "3",
  "ok": true,
  "result": { "id": "main", "name": "main", "windowCount": 2, "isAttached": true }
}
```

---

#### `close-session <id>`

Close a session and all its windows.

```bash
ctrlx close-session work
```

**JSON-RPC**
- Method: `session.close`
- Params: `{ "session_id": "work" }`
- Response: `{ "ok": true }`

---

#### `set-title <text>`

Set or clear the sidebar title for a session. The title is persisted as the `@ctrlx-description` tmux user option so it survives an app restart. Pass an empty string to clear.

Titles always apply at session scope — every window in the session shows the same title. To rename the tab label of a single window, use [`rename-window`](#rename-window-id-name) instead.

```bash
ctrlx set-title "Workers" --session work    # explicit session
ctrlx set-title "Builds"                    # current pane's session via $TMUX_PANE
ctrlx set-title ""                          # clear
```

**JSON-RPC**
- Method: `session.set_title`
- Params: `{ "title"?: string, "session_id"?: string, "pane_id"?: string }` _(omit or pass empty `title` to clear; `pane_id` is used to look up the calling pane's session and is sent automatically from `$TMUX_PANE` when no flag is given)_
- Response: `{ "ok": true }`

---

#### `set-color <color>`

Set or clear the sidebar dot for a session. The choice is persisted as the `@ctrlx-color` tmux user option so it survives an app restart. Pass `none` (or an empty string) to clear.

Like `set-title`, colors always apply at session scope.

```bash
ctrlx set-color blue --session work          # explicit session
ctrlx set-color purple                       # current pane's session via $TMUX_PANE
ctrlx set-color none                         # clear
```

Valid colors: `red`, `orange`, `yellow`, `green`, `blue`, `purple`, `pink`, `gray` (plus the `violet`/`magenta`/`grey` aliases accepted by `new-session --color`).

**JSON-RPC**
- Method: `session.set_color`
- Params: `{ "color": string, "session_id"?: string, "pane_id"?: string }` _(empty `color` clears; unknown colors return `invalid_params`)_
- Response: `{ "ok": true }`

---

#### `set-emoji <emoji-or-name>`

Set or clear the sidebar emoji icon for a session. The choice is persisted as the `@ctrlx-emoji` tmux user option so it survives an app restart. Pass `none` (or an empty string) to clear.

Like `set-title` and `set-color`, emoji icons always apply at session scope. The argument accepts either an emoji character directly (`"🚀"`, `"🐛"`) or a Unicode name / description (`rocket`, `bug`, `"smiling face heart"`). Name lookup uses `Unicode.Scalar.Properties.name` locally — an exact match short-circuits to a single result, ambiguous queries print the candidate glyphs with their names and exit non-zero so you can rerun with a more specific phrase. Use `find-emoji` to browse matches without committing. Input that's neither an emoji nor a recognised Unicode name is rejected with a validation error so arbitrary text doesn't get persisted.

```bash
ctrlx set-emoji "🚀" --session work          # literal emoji character
ctrlx set-emoji rocket --session work        # same — looked up by Unicode name
ctrlx set-emoji "smiling face heart"         # any word-set substring of a Unicode name works
ctrlx set-emoji "🐛"                         # current pane's session via $TMUX_PANE
ctrlx set-emoji none                         # clear
```

**JSON-RPC**
- Method: `session.set_emoji`
- Params: `{ "emoji": string, "session_id"?: string, "pane_id"?: string }` _(empty `emoji` clears)_
- Response: `{ "ok": true }`

---

#### `find-emoji <query>`

Search the Unicode emoji database by name and print one match per line as `<glyph>  <name>`. Every whitespace-separated word in the query must appear in the candidate's name (case-insensitive); results are sorted shortest-name-first so the most canonical candidate floats to the top. Pure local lookup — this command does not contact the relay or tmux, so it works even when CtrlX isn't running.

```bash
ctrlx find-emoji rocket
ctrlx find-emoji "smiling face"
ctrlx find-emoji heart --json
```

With `--json` the output is a JSON array of `{ "emoji", "name" }` entries. An empty match set is `[]` with exit 0 (so scripts can pipe through `jq`); the human-readable mode exits 1 with a stderr message instead so shell branches like `if ctrlx find-emoji foo > /dev/null` work the way you'd expect.

**JSON-RPC**: this command is CLI-only — no JSON-RPC method, since name lookup happens entirely in the CLI process.

---

#### `session-state <state>`

Override the state indicator the sidebar shows for a session (working spinner, idle moon, or the orange "needs attention" bell), independent of what the coding agent reports. Unlike `set-color`/`set-emoji` this is a **transient** override — it is *not* persisted to tmux and stays in place only until it's cleared (`clear`) or an agent plugin reports a fresh state for the same pane, at which point the plugin wins. Target with `--session` to apply it to every pane in that session, or `--pane` for a single pane; with neither flag it marks just the calling pane (via `$TMUX_PANE`). The sidebar aggregates the override across a session's panes either way, so a single-pane mark still flips the session's row.

The sidebar's right-click (macOS) / long-press (iOS) **"Set State"** context menu is the GUI equivalent — it drives the same override (issue #695), with the current state checked and an "Automatic" entry to clear it.

```bash
ctrlx session-state working --session work    # explicit session
ctrlx session-state waiting                    # current pane's session via $TMUX_PANE
ctrlx session-state clear                       # revert to the agent-driven state
```

Valid states: `working`, `idle`, `waiting`, `clear`. Aliases: `waiting-for-input`/`attention` (→ waiting), `none` (→ clear).

**JSON-RPC**
- Method: `session.set_state`
- Params: `{ "state": "working"|"idle"|"waiting"|"clear", "session_id"?: string, "pane_id"?: string }` _(unknown states return an error)_
- Response: `{ "applied_to": int }`

---

### Windows

#### `list-windows`

List windows in the current session, or a specific session with `--session`.

```bash
ctrlx list-windows
ctrlx list-windows --session work
```

**JSON-RPC**
- Method: `window.list`
- Params: `{ "session_id": "work" }` _(session_id is optional)_
- Response:
```json
{
  "id": "4",
  "ok": true,
  "result": {
    "windows": [
      { "id": "main:0", "index": 0, "name": "editor", "paneCount": 2, "isActive": true, "sessionId": "main" },
      { "id": "main:1", "index": 1, "name": "server", "paneCount": 1, "isActive": false, "sessionId": "main" }
    ]
  }
}
```

---

#### `new-window`

Create a new window in the current session, or a specific session with `--session`. Use `--path` to set the starting directory for the new window; if omitted, it opens in the user's home directory. Use `--name` to set the tmux window name (tab label) — without it, the daemon auto-generates `terminal N`. To change the tab label later, use [`rename-window`](#rename-window-id-name).

```bash
ctrlx new-window
ctrlx new-window --session work
ctrlx new-window --session work --path /Users/me/code/work
ctrlx new-window --name editor
```

**JSON-RPC**
- Method: `window.create`
- Params: `{ "session_id": "work", "path": "/Users/me/code/work", "name": "editor" }` _(all optional; `path` defaults to `$HOME`)_
- Response:
```json
{
  "id": "5",
  "ok": true,
  "result": { "id": "work:1", "index": 1, "name": "bash", "paneCount": 1, "isActive": false, "sessionId": "work" }
}
```

---

#### `select-window <id>`

Switch to a window by ID.

```bash
ctrlx select-window main:1
```

**JSON-RPC**
- Method: `window.select`
- Params: `{ "window_id": "main:1" }`
- Response: `{ "ok": true }`

---

#### `rename-window <id> <name>`

Set a window's tmux name (the tab label). The only window-scoped CLI mutation — for the session-wide sidebar title, use [`set-title`](#set-title-text). Empty names are rejected.

Under the hood this calls `tmux rename-window`, which also disables tmux's automatic-rename for that window so the tab stops tracking the running command.

```bash
ctrlx rename-window work:1 logs
```

**JSON-RPC**
- Method: `window.set_name`
- Params: `{ "window_id": "work:1", "name": "logs" }`
- Response: `{ "ok": true }`

---

#### `close-window <id>`

Close a window and all its panes.

```bash
ctrlx close-window main:1
```

**JSON-RPC**
- Method: `window.close`
- Params: `{ "window_id": "main:1" }`
- Response: `{ "ok": true }`

---

### Panes

#### `list-panes`

List panes in the current window, or a specific window with `--window`.

```bash
ctrlx list-panes
ctrlx list-panes --window main:0
```

**JSON-RPC**
- Method: `pane.list`
- Params: `{ "window_id": "main:0" }` _(window_id is optional)_
- Response:
```json
{
  "id": "6",
  "ok": true,
  "result": {
    "panes": [
      {
        "id": "%3", "index": 0, "isActive": true,
        "command": "claude", "cwd": "/Users/me/project",
        "width": 220, "height": 50,
        "windowId": "main:0", "hasClaudeSession": true
      }
    ]
  }
}
```

---

#### `split-pane [direction]`

Split the current pane. Direction is `left`, `right`, `up`, or `down` (default: `right`). Use `--pane` to target a specific pane. Use `--path` to set the starting directory for the new pane; if omitted, it opens in the user's home directory. Use `--shell` to run a custom shell or command as the new pane's process instead of the default shell — useful for spinning up a fish, nushell, or bespoke command pane.

```bash
ctrlx split-pane
ctrlx split-pane down
ctrlx split-pane right --pane %3
ctrlx split-pane down --path /Users/me/code/work
ctrlx split-pane right --shell /opt/homebrew/bin/fish
```

**JSON-RPC**
- Method: `pane.split`
- Params: `{ "direction": "down", "pane_id": "%3", "path": "/Users/me/code/work", "shell": "/bin/fish" }` _(all optional; `path` defaults to `$HOME`)_
- Response:
```json
{
  "id": "7",
  "ok": true,
  "result": {
    "id": "%6", "index": 1, "isActive": false,
    "command": "bash", "cwd": "/Users/me/project",
    "width": 220, "height": 24,
    "windowId": "main:0", "hasClaudeSession": false
  }
}
```

---

#### `select-pane <id>`

Focus a pane by its tmux pane ID.

```bash
ctrlx select-pane %3
```

**JSON-RPC**
- Method: `pane.select`
- Params: `{ "pane_id": "%3" }`
- Response: `{ "ok": true }`

---

#### `set-progress <value>`

Set or clear the per-pane sidebar progress bar that the host normally derives from `OSC 9;4` terminal sequences. The override syncs through the same path the OSC reader uses, so every connected viewer (host sidebar, Mac viewer, iOS) sees the same bar.

CLI and OSC updates share `PaneState.progress` and last-write-wins each other — a script can set the bar before kicking off a task, and a subsequent `OSC 9;4` sequence emitted by the running program replaces it (and vice versa).

```bash
ctrlx set-progress 50                  # 50% determinate (blue)
ctrlx set-progress 75 --pane %3        # explicit pane target
ctrlx set-progress indeterminate       # animated blue scanner (no specific %)
ctrlx set-progress warning             # full yellow warning bar
ctrlx set-progress error               # full red error bar
ctrlx set-progress clear               # remove the bar (alias: none, "")
```

Accepted values: `0`–`100` (with or without a trailing `%`), `indeterminate`, `warning`, `error`, `clear` / `none` / empty string.

**JSON-RPC**
- Method: `pane.set_progress`
- Params: `{ "value": "50", "pane_id": "%3" }` _(pane_id is optional; the CLI fills it from `$TMUX_PANE` when no `--pane` flag is given)_
- Response: `{ "ok": true }`

This value can also be set declaratively inside `ctrlx apply` YAML — set `progress: 50` (or `progress: warning`, `progress: indeterminate`) on a pane spec to apply the value at session-creation time. Re-applying syncs the value (and clearing the field clears the bar).

---

### Input

#### `send <text>`

Send text to the active pane, or a specific pane with `--pane`. The text is sent as-is — include `\n` for a newline (Enter).

```bash
ctrlx send "ls -la\n"
ctrlx send "hello" --pane %5
```

**JSON-RPC**
- Method: `input.send_text`
- Params: `{ "text": "ls -la\n", "pane_id": "%5" }` _(pane_id is optional)_
- Response: `{ "ok": true }`

---

#### `send-key <key>`

Send a named key press to the active pane, or a specific pane with `--pane`.

Supported keys: `enter`, `tab`, `escape`, `backspace`, `delete`, `up`, `down`, `left`, `right`, `space`

```bash
ctrlx send-key enter
ctrlx send-key escape --pane %3
```

**JSON-RPC**
- Method: `input.send_key`
- Params: `{ "key": "enter", "pane_id": "%3" }` _(pane_id is optional)_
- Response: `{ "ok": true }`

---

### Notifications

#### `notify`

Send a desktop notification through CtrlX's notification system. Notifications appear identically to terminal-triggered ones. If `$TMUX_PANE` is set, the notification includes pane context so tapping it navigates to that pane.

Pass `--push` to also forward the notification to every paired iOS viewer through the relay server. This reuses the same encrypted-push pipeline that Claude hook events use, so the alert falls back to APNs whenever the viewer is offline. Without `--push` the notification stays local to macOS Notification Center.

```bash
ctrlx notify --title "Deploy done" --body "Production updated successfully"
ctrlx notify --title "Build green" --body "All checks passed" --push
```

**JSON-RPC**
- Method: `notification.create`
- Params: `{ "title": "Deploy done", "body": "Production updated successfully", "push": true }` _(`push` is optional)_
- Response: `{ "ok": true }`

---

### Layouts

#### `apply <file>`

Build a tmux session from a declarative YAML or JSON layout file. Idempotent by default — re-applying selects an existing session instead of duplicating it. The schema is a strict superset of [tmuxp](https://tmuxp.git-pull.com)'s YAML; existing tmuxp configs work without modification.

```bash
ctrlx apply workers.yml
ctrlx apply ~/projects/foo --rebuild       # close-then-build
ctrlx apply layout.yml --detach            # don't switch
ctrlx apply layout.yml --dry-run           # parse + plan, no tmux
ctrlx apply layout.yml --lenient           # warn on unknown keys
ctrlx apply layout.yml --require-create    # exit 3 if session exists
ctrlx apply -                              # read from stdin
envsubst < layout.tmpl.yml | ctrlx apply -
```

When the file argument is a directory, ctrlx looks for `.ctrlx.yaml`, `.ctrlx.yml`, `.tmuxp.yaml`, `.tmuxp.yml` (in that order).

**Exit codes**
- `0` — applied (built or selected)
- `1` — generic failure (parse error, RPC failure)
- `2` — validation error (schema invalid, unknown required field)
- `3` — already exists, in `--require-create` mode

**File format**

```yaml
session_name: workers           # required
description: "Worker scripts"   # sidebar description (CtrlX extension)
color: blue                     # sidebar dot color (CtrlX extension); omit or "" to leave unset
start_directory: ~/code         # default cwd; relative resolves against the file's dir
environment:                    # tmux set-environment for the session
  FOO: bar
shell_command_before:           # commands prepended to every pane (string or array)
  - source ~/.env
before_script: ./bootstrap.sh   # ran once before the session is created (cold start only)
options: {}                     # tmux session options — passed through
suppress_history: true          # default for all panes; prefix sent commands with " "
windows:
  - window_name: editor         # also accepted: `name`
    layout: main-vertical
    focus: true
    options: {}
    panes:
      - vim                     # bare string = shell_command
      - shell_command: ["tail -f log"]
        start_directory: ./logs
        progress: 50            # CtrlX extension; 0-100, indeterminate, warning, error, or clear
      - claude:                 # CtrlX extension
          project: ~/code/foo
          args: ["--resume"]
on_create:                      # cold-start hooks (run once)
  - "echo bootstrap >> /tmp/log"
on_apply:                       # always-run hooks
  - "ctrlx notify --title workers --body 'ready'"
```

Variable expansion: every string-valued field is run through a `${VAR}` / `$VAR` expander. `${VAR:-default}` provides inline defaults. No command substitution, no ERB.

**JSON-RPC**
- Method: `layout.apply`
- Params: `{ "config": <parsed YAML/JSON>, "rebuild": false, "detach": false, "dry_run": false, "lenient": false, "require_create": false, "config_path": "/abs/path/to/file.yaml" }`
- Response:
```json
{
  "id": "10",
  "ok": true,
  "result": {
    "session_name": "workers",
    "created": true,
    "warnings": [],
    "planned_actions": ["session.create name=workers path=$HOME", "..."]
  }
}
```

---

### Plugins

Manage sidecar plugins installed in CtrlX. For the full plugin authoring contract (manifest schema, sidecar API, lifecycle hooks) see [`docs/plugins/sidecar-authoring.md`](plugins/sidecar-authoring.md).

#### `plugin list`

List all installed plugins with their ID, display name, version, and enabled/disabled state.

```bash
ctrlx plugin list
ctrlx plugin list --json
```

---

#### `plugin info <id>`

Show detailed metadata for an installed plugin (manifest fields, bundle path, enabled state).

```bash
ctrlx plugin info com.example.hello
```

---

#### `plugin install <https-url> [--yes]` / `plugin install --zip <path> [--yes]`

Install a sidecar plugin from either a remote HTTPS manifest URL **or** a local `.zip` bundle (`--zip`, whose archive root holds `plugin.json` + the executable). Either way a trust confirmation prompt is shown first; pass `--yes` to skip it (non-interactive / scripted installs). Exactly one of `<url>` or `--zip` must be given. A `--zip` path is resolved relative to your current directory (and `~` is expanded). A zip install carries no remote URL or SHA-256 — integrity pinning is moot for a local file you chose.

```bash
ctrlx plugin install https://example.com/plugin.json
ctrlx plugin install https://example.com/plugin.json --yes
ctrlx plugin install --zip ./my-agent.zip
ctrlx plugin install --zip ~/Downloads/my-agent.zip --yes
```

---

#### `plugin remove <id> [--keep-state|--delete-state]`

Uninstall a plugin by ID. By default the plugin's persistent state directory is preserved so a future reinstall can pick up where it left off. Pass `--delete-state` to also wipe the state directory, or `--keep-state` to make the intent explicit.

```bash
ctrlx plugin remove com.example.hello
ctrlx plugin remove com.example.hello --delete-state
```

---

#### `plugin update [<id>] [--apply]`

Check whether installed plugins have newer versions available. Without `<id>`, checks all plugins. Prints a summary of available updates. Pass `--apply` to download and apply the updates immediately.

```bash
ctrlx plugin update
ctrlx plugin update com.example.hello
ctrlx plugin update --apply
```

---

#### `plugin enable <id>`

Enable a previously disabled plugin. The sidecar process is (re)started immediately.

```bash
ctrlx plugin enable com.example.hello
```

---

#### `plugin disable <id>`

Disable a plugin without uninstalling it. The sidecar process is stopped; state is preserved.

```bash
ctrlx plugin disable com.example.hello
```

---

#### `plugin logs <id>`

Stream or print recent log output from a plugin's sidecar process.

```bash
ctrlx plugin logs com.example.hello
```

---

#### `plugin call <id> <method> [<json-params>]`

Send a one-shot JSON-RPC call to a running plugin sidecar and print the response. Useful for manual testing and debugging.

```bash
ctrlx plugin call com.example.hello greet '{"name":"world"}'
```

---

### Editor

#### `edit <file>`

Open a file in CtrlX's in-app prompt editor. The command blocks until the user submits or cancels in the app, then exits with the result. The calling pane is detected automatically from `$TMUX_PANE`.

This command is used as the `$VISUAL` editor inside CtrlX-managed sessions, enabling Claude Code's prompt editing flow.

```bash
ctrlx edit /tmp/my-prompt.txt
```

**JSON-RPC**
- Method: `editor.open`
- Params: `{ "pane_id": "%3", "file_path": "/tmp/my-prompt.txt" }`
- Response: `{ "ok": true }` _(sent when editing completes)_

---

### Utility

#### `ping`

Check whether CtrlX is running and the socket is reachable.
Fails after at most five seconds if communication cannot complete.

```bash
ctrlx ping
```

**JSON-RPC**
- Method: `system.ping`
- Params: _(none)_
- Response: `{ "pong": true }`

`ctrlx wait-ready --timeout 30 --interval 0.2` polls until ready. Its timeout is
the total budget, including connection/response waits and pauses; each probe has
at most one second. Both options require finite positive seconds. Only this
read-only readiness probe retries; browser actions are never replayed.

---

#### `capabilities`

List all JSON-RPC methods supported by the running app version.

```bash
ctrlx capabilities
ctrlx capabilities --json | jq '.result.methods[]'
```

**JSON-RPC**
- Method: `system.capabilities`
- Params: _(none)_
- Response:
```json
{
  "id": "8",
  "ok": true,
  "result": {
    "methods": [
      "session.list", "session.create", "session.select", "session.current", "session.close",
      "session.set_state", "session.set_title", "session.set_color",
      "window.list", "window.create", "window.select", "window.close", "window.set_name",
      "pane.list", "pane.split", "pane.select", "pane.capture", "pane.set_layout", "pane.set_progress",
      "input.send_text", "input.send_key",
      "notification.create",
      "editor.open",
      "system.ping", "system.capabilities", "system.identify", "system.set_env",
      "project.list", "project.start",
      "layout.apply"
    ]
  }
}
```

---

#### `system.set_env` (RPC-only)

Set or unset session-scoped tmux environment variables. New shells spawned in the session inherit the values; already-running panes keep their existing environment. Used internally by `ctrlx apply` to honor the `environment:` block in a layout config.

**JSON-RPC**
- Method: `system.set_env`
- Params: `{ "session_id": "workers", "vars": { "FOO": "bar", "OLD": null } }` _(value `null` unsets the variable)_
- Response: `{ "ok": true }`

---

#### `pane.set_layout` (RPC-only)

Apply a tmux layout (preset name or hex layout string) to a window. Used internally by `ctrlx apply` for `windows[].layout:` but also useful for scripted retiling.

**JSON-RPC**
- Method: `pane.set_layout`
- Params: `{ "target": "workers:0", "layout": "main-vertical" }`
- Response: `{ "ok": true }`

---

#### `identify`

Show the session, window, and pane context of the calling process. Uses `$TMUX_PANE` to determine context. Useful for scripts that need to know where they are running.
Communication has a five-second deadline. Interactive commands such as
`editor.open` retain their unbounded wait for user input.

```bash
ctrlx identify
```

**JSON-RPC**
- Method: `system.identify`
- Params: _(none)_
- Response:
```json
{
  "id": "9",
  "ok": true,
  "result": {
    "session": { "id": "main", "name": "main", "windowCount": 2, "isAttached": true },
    "window":  { "id": "main:0", "index": 0, "name": "editor", "paneCount": 2, "isActive": true, "sessionId": "main" },
    "pane":    { "id": "%3", "index": 0, "isActive": true, "command": "claude", "cwd": "/Users/me/project", "width": 220, "height": 50, "windowId": "main:0", "hasClaudeSession": true }
  }
}
```

---

## Global Options

| Option | Description |
|--------|-------------|
| `--socket <path>` | Override the socket path (takes priority over `$CTRLX_SOCKET` and the default fallback) |
| `--json` | Print the raw JSON-RPC response instead of formatted output |
| `--pane <id>` | Target a specific pane by tmux pane ID (e.g. `%3`). Overrides the active pane for input commands |
| `--session <id>` | Target a specific session. Used by `list-windows`, `new-window`, `set-title`, `set-color`, `set-emoji` |
| `--window <id>` | Target a specific window. Used by `list-panes` |
| `--path <dir>` | Starting directory for `new-session`, `new-window`, and `split-pane`. Defaults to `$HOME` when omitted. |
| `--name <name>` | tmux window name (tab label) for `new-window`. Without it, the daemon auto-generates `terminal N`. |
| `--shell <cmd>` | Run this command/shell as the new pane's process for `split-pane`. |

---

## Wire Protocol

`ctrlx` communicates with the app using newline-delimited JSON-RPC over a Unix domain socket (`AF_UNIX, SOCK_STREAM`). Each message is a single JSON object followed by `\n`. Connections are persistent — multiple requests can be sent over a single connection.

### Request

```json
{ "id": "unique-id", "method": "session.list", "params": {} }
```

- `id` — arbitrary string, echoed in the response for correlation
- `method` — dot-separated `domain.action` string
- `params` — object with method-specific fields (may be empty `{}`)

### Success Response

```json
{ "id": "unique-id", "ok": true, "result": { ... } }
```

### Error Response

```json
{
  "id": "unique-id",
  "ok": false,
  "error": { "code": "not_found", "message": "Session 'foo' not found" }
}
```

### Method Naming

Methods follow a `domain.action` convention:

| Prefix | Domain |
|--------|--------|
| `session.*` | Session management |
| `window.*` | Window management |
| `pane.*` | Pane management |
| `input.*` | Text and key input |
| `notification.*` | Desktop notifications |
| `editor.*` | Prompt editor |
| `system.*` | Utility / introspection |

---

## Error Codes

| Code | Meaning |
|------|---------|
| `not_found` | The requested resource (session, window, pane) does not exist |
| `invalid_params` | A required parameter is missing or has an invalid value |
| `method_not_found` | The requested method string is not recognized |
| `validation_error` | `layout.apply` config failed schema validation (CLI maps to exit 2) |
| `session_exists` | `layout.apply` was called with `require_create` and the session already exists (CLI maps to exit 3) |
| `internal_error` | An unexpected error occurred inside the app |
