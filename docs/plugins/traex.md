# Traex integration

Traex is an independent built-in Agent (`pluginID: traex`). The Host reuses
`CodexPluginCore` with `CodexDistribution.traex` for its compatible hooks, rollout
format and terminal interaction. It does not register Traex sessions as Codex or
share their configuration, account state or pane correlations.

## Configuration and installation

Install the Traex CLI separately. Settings → Agents → Traex defaults to command
`traex`; an explicit executable such as `traecli` can be configured. The manifest
recognizes both process names. The native configuration is
`$TRAE_HOME/traecli.toml`, defaulting to `~/.trae/traecli.toml`. Additional
configuration directories must be existing Traex homes. History and project
discovery read `cli/sessions` inside those homes, not Codex's `sessions` folder.

Provider, login and model defaults remain in Traex's native configuration. CtrlX
does not supply Codex's OpenAI default, custom Provider profiles, Keychain accounts
or account quota queries to Traex. There is no CtrlX-managed Traex CLI updater.

The packaged `plugin/traex` marketplace contains two native Codex-format plugins:
`ctrlx@ctrlx` for shared skills and `ctrlx-hooks@ctrlx` for lifecycle events.
The hook bridge identifies itself as `traex`. Packaging mirrors the shared skill
tree into each native marketplace; it does not duplicate skill sources in Git.
The Traex bridge starts at 1.0.1 so upgrading a previously installed Codex-format
bridge (1.0.0) in a Traex home replaces its old `codex` event identity.

Install/update uses Traex's native marketplace registration and `plugin install
--yes` to refresh missing or older components. `plugin upgrade` requires a Git
marketplace and cannot update the App's local bundle. Status reads `plugin list`, then verifies each registered
component's `.active-version` and cached manifest. The marketplace must resolve
to the current App's Traex bundle before replacing plugins. Uninstall removes
only the two marketplace-qualified CtrlX components from the selected home.
Unknown CLI output is a check error, not proof that plugins are absent.

## Capabilities

| Operation | Behavior |
|---|---|
| New Agent / project | Launches Traex with its native configuration |
| Working and completion | Uses Traex lifecycle hooks and the compatible event translator |
| Questions | Recognizes native `AskUserQuestion` hooks for notifications and navigation; Traex opens its own terminal panel |
| Resume / Fork | Native `resume` / `fork` with the exact conversation ID and source `TRAE_HOME` |
| Restart and workspace recovery | Preserves the recorded executable, configuration root and supported options |
| Browser ownership and workflow identity | Verifies the current process lifetime and writable native rollout; a process name alone is insufficient |
| Plain workflow / Agent interaction | Admitted for the locally verified `traecli 0.213.1`; unknown versions fail automatic input admission |
| Images | Native pasted paths produce the compatible `[Image #N]` attachments; image targets and workflow transport recognize Traex |
| Model catalog | Reads native `debug models`; a missing display label falls back to the model slug |
| Model / effort switching | Use Traex's native `/model` picker; automatic inline commands and workflow overrides are rejected |
| Hook trust / refresh | Use Traex's native `/hooks`; CtrlX does not drive Codex's incompatible trust menu |
| Usage telemetry | Codex OTLP export is not enabled; the local Traex probe did not emit compatible records |

Managed interactive launches add `--no-daemon` to keep the process and writable
rollout in the owned tmux pane, plus `--dangerously-bypass-hook-trust`. The latter
applies to every enabled hook in that process; it does not bypass command or
sandbox approvals and does not save persistent trust. New CtrlX zsh terminals
apply the same policy to manual `traex` / `traecli`, `resume` and `fork` commands.
Existing aliases/functions win. Maintenance commands such as `exec` and `plugin`
do not receive interactive flags. No user shell startup files are changed.

An already-running daemon-backed Traex does not gain local process ownership by
installing the plugin. Reopen it explicitly in a new CtrlX terminal if identity
checks report that it is outside a local pane. Do not borrow another Agent's ID.

Traex 0.213.1 treats Codex's `/model <name> --reasoning=<effort>` as a normal
Agent prompt. Its native picker also persists changes to native configuration.
CtrlX therefore rejects automatic switching before sending that command, rather
than treating the shared catalog format as proof of command compatibility.

Traex 0.213.1 exposes `AskUserQuestion`, rather than Codex's
`request_user_input(_async)`. Native requests with either `isBlocking` value
directly open a `Question 1/N` terminal panel. CtrlX emits a question notification
once per native tool-call ID, without fabricating a response form or sending
Codex's Shift+Left opener. That opener remains limited to Codex's verified
collapsed-queue layout. The local check used real Traex and a loopback model
fixture with private HOME/TRAE_HOME/tmux/socket roots; it does not establish
signed-App or physical iOS acceptance.

The native answer roundtrip also covers two consecutive single-question calls
in one turn for each `isBlocking` value: both panels open, Beta/Alpha choices
reach the model as the matching tool outputs, each call emits `PostToolUse`, and
the Agent continues to its final `Stop`/native completion. Workflow tests cover
Traex's question marker, human intervention and subsequent execution; encrypted
push tests cover its Agent destination without fabricating answer buttons.

Esc interrupts the native turn. Traex 0.213.1 writes `turn_aborted` without a
`Stop` hook. On the next Agent process reconciliation, the Host clears Working
when the live process, writable conversation and latest submitted turn match
that interruption.

## Verification

Focused Swift tests cover home and event isolation, project discovery, native
history lookup, Resume/Fork, unsupported menu guards, writer validation and zsh
launch policy. Native plugin installation is opt-in and uses a private home:

```sh
CTRLX_TRAEX_NATIVE_TESTS=1 ./scripts/unit-tests.sh -- --no-parallel --filter Traex
python3 -m unittest scripts.tests.test_agent_skills
```

The native test can select an executable with `CTRLX_TRAEX_TEST_EXECUTABLE`.
Local TUI acceptance uses Traex 0.213.1, private HOME/TRAE_HOME/tmux/socket roots
and a loopback model fixture. This verifies the actual hook payloads, rollout
writer and native menus without a user conversation or model credentials. It
does not establish signed-App E2E, remote-Host or physical iOS acceptance, or
compatibility with other Traex releases.
