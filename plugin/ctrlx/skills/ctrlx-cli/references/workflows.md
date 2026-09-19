# Labels, feedback and project workflows

Use explicit IDs discovered with `identify` / `list-*`. These examples are
mutations: run only the operation the user requested.

## Session labels versus window names

```bash
ctrlx set-title 'Build service' --session work
ctrlx set-color blue --session work
ctrlx set-emoji rocket --session work
ctrlx rename-window work:1 logs
```

Title/color/emoji apply to the whole session; they do not rename its tmux name
or individual tabs. They accept `--session`, otherwise use the calling pane's
session. Passing `--pane` or `--window` does not retarget these label commands.
`rename-window` takes two positional arguments; it also disables tmux's automatic
rename for that window. An empty window name is invalid.

- Clear title with `set-title ''`; clear color/emoji with `none` or `''`.
- Colors: red, orange, yellow, green, blue, purple, pink, gray; aliases
  violet→purple, magenta→pink, grey→gray.
- Emoji accepts a glyph or name/CLDR keyword. Ambiguous matches fail with
  candidates; inspect with `ctrlx find-emoji trash --json`. This local-only
  lookup returns an array of `{emoji, name}`, not a JSON-RPC envelope. No matches
  means `[]`/exit 0 in JSON mode, exit 1 in human mode.

## Activity and progress

```bash
ctrlx session-state working --pane %3
ctrlx set-progress 50 --pane %3
ctrlx set-progress clear --pane %3
ctrlx session-state clear --pane %3
```

`session-state` accepts working/idle/waiting/clear. `--pane` affects one pane;
`--session` affects that session's panes. This is a display override, not a change
to the running agent; subsequent activity events may clear it.

Progress accepts 0–100, indeterminate, warning, error, clear/none/empty. CLI and
terminal `OSC 9;4` updates use the same per-pane bar; the latest update wins.

## Notifications and editing

```bash
ctrlx notify --title 'Build done' --body 'Tests passed'
ctrlx notify --title 'Build done' --body 'Tests passed' --push
ctrlx edit /absolute/path/to/prompt.txt
```

`notify` is local unless `--push` is requested; push also reaches paired iOS
viewers. With no paired viewer, only the local notification appears.
The calling `$TMUX_PANE` supplies the notification's deep-link context.

`edit` requires `$TMUX_PANE` and blocks until the user submits/cancels. Use it
only for an interactive prompt-editing request, not fire-and-forget automation.
It does not emit a JSON envelope even with `--json`.

## Project discovery and launch

```bash
ctrlx list-projects --json
ctrlx start-project /path/to/project
ctrlx start-project /path/to/project --agent claude-code -- --resume
```

`list-projects` merges projects from enabled agent plugins; JSON includes
`plugin_id`. The CLI's `start-project` defaults to **Codex**; use `--agent <plugin-id>`
to choose another agent. Nonempty arguments after `--` replace the plugin's default
launch arguments. The [socket API](api-reference.md) accepts the same choice through
`project.start`'s `plugin_id`. `new-session --path` follows the app's auto-run
setting instead.
