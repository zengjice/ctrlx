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

## Agent collaboration

The task's `[CtrlX workflow invocation: …]` block identifies the current
invocation. It includes a completion command only when that step is authorized
to end the workflow. Workflow images are delivered as native image attachments
with the task; use those images directly.
The task and step instructions determine the response; the workflow block adds
no answer format.

The attachment lookup below is available for an explicit file lookup. It is not
required to receive native workflow images. Use the invocation UUID supplied
with the current task. Check `ctrlx workflow attachments --help` first if the
installed CLI's capabilities are unknown.

```bash
ctrlx workflow attachments --invocation '<UUID from this task>' --json
```

The response lists only that invocation's authorized files, including their
name, media type, SHA-256 and Host-local path. Read each image with your native
image-reading tool and each UTF-8 text file in full before using it as evidence.
The text response itself does not contain image pixels or prove that the model
has inspected them. If your tools cannot read a file, report the limitation and
ask for an explicit conversion; never claim to have read it or silently omit it.
Do not enumerate other workflow directories, substitute a previous invocation,
or use the file references as authorization for unrelated Host files. Audio and
video require a supported conversion before this reader can return them.
Converted inputs include optional `conversion` metadata describing the original
name, checksum and conversion. Read their notes and sampled images together;
sampled video frames do not establish what happened between samples. A transcript
is user-reviewed text, and notes explicitly identify excluded audio. Do not claim
you inspected an original audio/video file merely because it is retained by the
workflow.

Pausing handoffs does not revoke your current accepted invocation's attachment
access. You may finish its authorized work while the workflow
is paused. New tasks remain stopped; ended or expired runs and completed or
replaced invocations cannot obtain further access.

### Workspace files

Save code, reports and other files in the working directory agreed by the task.
Downstream Agents read them through those workspace paths. Text answers follow
the configured connections; images supplied by the workflow use the attachment
reader above. The workflow does not upload files mentioned in an answer.

### Requesting completion

The workflow task or step instructions define the completion condition. This
skill and the CLI do not choose business criteria. Use this only when that
configured condition is met, the current step grants completion, and the task
supplies its invocation UUID. Check `ctrlx workflow finish --help` on the installed
CLI; older releases may not provide the command.

```bash
ctrlx workflow finish --invocation '<UUID from this task>' --reason '<completion reason>'
```

The Host verifies the calling Agent process, the current invocation and the
node's finish grant. Knowing a UUID or command does not grant authority. Do not
reuse an invocation from an earlier round or pass pane/session/window overrides.
An accepted request stops new handoffs. Completion waits for the Host to verify
the current turn's final result; command success alone does not close the run.
If the workflow is paused, the request and result are saved until an operator
continues it. Do not resume the workflow or resend the task yourself. A denied request is not
workflow completion; report the reason without switching to another Agent's
identity or forcibly closing its terminal. This command does not kill Agents.
