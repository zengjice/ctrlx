# Repository Claude Code hooks

This repo ships a few **project-scoped Claude Code hooks** in `.claude/settings.json`.
They run for anyone working in the repo with Claude Code and exist to keep the
development workflow consistent. They are unrelated to the `ctrlx` plugin hooks
(`plugin/**/hooks/`), which forward session events to the monitoring app. The
plugin's `SessionStart` hook also supplies the shared
[file-reference output convention](file-browser.md#agent-output-convention-and-migration)
as agent context; it does not enforce this repository's development workflow.

The tool-independent requirements live in [CONTRIBUTING.md](../CONTRIBUTING.md)
and the [PR checklist](../.github/PULL_REQUEST_TEMPLATE.md). Other AI tools must
perform applicable checks explicitly; having `.claude/settings.json` in the
repository does not prove that a hook ran. Do not duplicate project rules into
a separate agent-specific instruction file.

## PostToolUse hooks

### `Edit|MultiEdit|Write` → swiftformat

After any file edit, an inline command runs `swiftformat` on the file when it is a
`.swift` file. Keeps formatting consistent without a manual step.

### `Bash` → PR checklist (`.claude/hooks/pr-checklist.py`)

Fires after every `Bash` tool call. When the command that just ran opens a pull
request (`gh pr create`), the hook prints a `hookSpecificOutput.additionalContext`
block so the agent finishes the project's post-PR chores before stopping:
applicable documentation/AGENTS.md updates, CLI + `ctrlx`-skill updates when the
CLI changes, and targeted end-to-end scenarios for changed app interactions.
It follows the shared validation rules and does not assume GUI/device permissions
or authorize extra scope. For every other Bash command it prints nothing and
exits 0, so it is a no-op.

The checklist text itself lives in `.claude/hooks/pr-checklist.md` (read lazily, only
when a PR-creating command fires) so the wording can be edited without touching the
script.

Matching is intentionally simple: a regex for `gh pr create`, tolerant of env prefixes
(`GH_TOKEN=… gh pr create`), `cd … && gh pr create`, and extra whitespace. A leading
`\b` keeps it from matching inside longer words and a trailing `(?=\s|$)` lookahead
requires whitespace or end-of-string after `create`, so it won't fire on a
hypothetical `gh pr create-from-draft`. It does not try to fully parse the shell, so a
command that merely *mentions* the phrase (an `echo`, a `grep`) will also fire — a
harmless false positive whose only cost is an injected reminder.

#### Output contract

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "Complete the applicable PR checks before stopping: …"
  }
}
```

See the [PostToolUse hook reference](https://code.claude.com/docs/en/hooks.md#posttooluse).

#### Tests

`.claude/hooks/test_pr_checklist.py` runs the hook as a subprocess (exactly how
Claude Code invokes it) across the fire/silent cases. Stdlib only — no pytest:

```bash
python3 .claude/hooks/test_pr_checklist.py
```
