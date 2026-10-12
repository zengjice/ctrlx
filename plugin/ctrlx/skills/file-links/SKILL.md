---
name: file-links
description: Present generated artifacts or referenced Host files as clickable file links in CtrlX. Use when reporting file locations or delivering local outputs, not for ordinary web URLs.
---

# File links in CtrlX

Use standard Markdown when delivering a file that the user can open in CtrlX
Files. The target belongs to the **Host running the agent**, not the viewing
iPhone or Mac. No CLI command or custom URI scheme is needed.

## Output contract

1. Use the actual, complete absolute Host path. Resolve relative paths against
   this task's working directory, including its worktree; do not substitute the
   repository's primary checkout or another machine's home directory.
2. Use a short descriptive label. Keep each Markdown link on one source line;
   let the terminal wrap it visually. Never shorten a target with `…` or `...`.
3. Keep backticks out of the label and target. For spaces or parentheses in a
   filename, enclose the target in angle brackets. Preserve Chinese characters.
4. For opening in Files, link to the file itself without editor line/column
   suffixes. Put any requested line number in the surrounding text instead.
5. Only call an artifact ready when it exists on the Host. Do not turn slash
   commands, web URLs, container-only paths or unverified tool-output fragments
   into Host file links. A missing/inaccessible file still fails Host validation.

Examples of output syntax (replace these illustrative targets with actual paths;
emit the links as Markdown, not inside a code block):

```markdown
[Episode 3](/Users/example/Projects/reel/output/A03_完整片.mp4)
[Final report](</Users/example/Projects/reel/output/final report (v2).pdf>)
```

## Renderer limits

Markdown is an output convention, not a guaranteed terminal hyperlink protocol.
An agent TUI may show `label (path)`, shorten the displayed target relative to
its working directory, or emit an OSC 8 hyperlink. CtrlX prefers a valid explicit
file target; otherwise it conservatively recognizes the visible path. Do not
write raw terminal escape sequences in assistant messages.

If the user reports a non-clickable link (for example, only a label or a bare
filename is shown), provide the complete absolute path in parentheses on its
own source line, without Markdown link syntax that could shorten it again.
Do not guess or reconstruct an ellipsized path. Existing tool logs and ordinary
terminal output do not have to follow this convention.
