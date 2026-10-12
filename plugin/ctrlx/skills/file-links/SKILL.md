---
name: file-links
description: Present verified repository files or folders as explicit clickable references when reporting outputs or source locations. Not for web URLs, slash commands, or files outside the current agent worktree.
---

# Repository file references

- Verify the file/folder exists inside the **current agent session's Git worktree**.
  Use `git rev-parse --show-toplevel` to find that worktree's root when needed.
  Do not substitute the primary checkout or another machine/container's filesystem.
- Show a root-relative reference as inline code: `<repo:outputs/report.pdf>`.
  Keep both angle brackets and the complete path on one source line. Visual wrapping
  is fine. Use `<repo:.>` for the root; omit leading `./` and never use `..`.
  For a directory, use `<repo:outputs/final_films>`; a single trailing `/` is also accepted.
- Encode spaces and reserved characters using UTF-8 percent encoding:
  `<repo:outputs/John%27s%20report.pdf>`. Encode literal `%` as `%25`;
  also encode `< > # ? : " ' \\ ( )`. Chinese can remain literal or be percent-encoded.
  Do not append line/column numbers, truncate, or hide the marker in a Markdown target.
- Do not emit absolute paths or mark slash commands, web URLs, unverified files,
  or files outside this worktree. Keep web links as ordinary Markdown URLs.
- This is a lightweight output convention, not a registered URI standard. No CLI,
  raw terminal escapes, or startup hook is needed. The Host validates on click.
  References use the current agent's worktree; old output is not pinned to an
  earlier workspace after the session/workspace changes.
