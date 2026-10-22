---
name: file-links
description: Format verified repository files and folders in user-facing progress updates and final replies as clickable repo references. Not for commands, code, web URLs, or files outside the current worktree.
---

# Repository file references

CtrlX opens repository files and folders from explicit references in agent replies.
When reporting outputs, changes or source locations, format the files/folders you
already need to mention as inline code: `<repo:outputs/report.pdf>`. Use this
instead of a bare path or Markdown file link; do not add unrelated references.

- Link only existing items inside the **current agent session's Git worktree**.
  Reuse evidence from your reads, writes or checks; verify only if unsure.
  Find the root with `git rev-parse --show-toplevel` only when it is not known.
  Do not substitute the primary checkout or another machine/container's filesystem.
- Use a root-relative path, never an absolute path, leading `./` or `..`.
  Root: `<repo:.>`. Folder: `<repo:outputs/final_films>` (one trailing `/` is accepted).
  Keep both angle brackets and the complete marker on one source line; visual
  wrapping is fine. Do not truncate it or hide it in a Markdown link target.
  Put line/column numbers outside the marker: `<repo:src/main.swift>` (line 42).
- Encode spaces and reserved characters with UTF-8 percent encoding:
  `<repo:outputs/John%27s%20report.pdf>`. Encode literal `%` as `%25`;
  also encode `< > # ? : " ' \\ ( )`. Chinese may remain literal or be encoded.
- This applies only to user-facing references. Leave paths inside shell commands,
  code and configuration unchanged. Keep web URLs as ordinary web links; do not
  mark slash commands, examples, deleted/unverified items or files outside this worktree.

No CLI call or terminal escape is needed. The Host validates on click. This is an
output convention, not a registered URI standard or a link pinned to a past worktree.

## Images, Mermaid diagrams and Markdown

When an image or diagram helps answer the user's request, save the deliverable
inside the current worktree and include its explicit repository reference in
the reply. Reuse an existing image file when possible; prefer PNG or JPEG for
new raster images. Save Mermaid as UTF-8
`.mmd` or `.mermaid` source, without Markdown fences, then link that file.
Use the project's existing output location; do not create an extra Markdown
document solely to wrap an image or diagram.

Mac and iOS clients with artifact previews open image and Mermaid references
directly in a zoomable preview. The user chooses when to open it; do not open
browser tabs or switch their workspace just to display the artifact. Older
clients continue opening the file in Files. Plain Mermaid code printed only in
the terminal is not automatically rendered. Keep diagrams within 64 KiB and
500 edges; images use the existing 8 MiB preview limit.

For a document that combines prose, diagrams and images, save UTF-8 `.md` or
`.markdown` and reference that file. Its preview renders Markdown, fenced
`mermaid` blocks and repository images together on Mac and iOS. Use image paths
relative to the Markdown file, such as `images/overview.png`; `../` is supported
only within the repository. Web image URLs and raw HTML are not rendered.
Keep the document within 512 KiB, with at most 16 diagrams and 24 unique images.
PNG/JPEG and the existing image formats are supported; SVG must be UTF-8 and
within 512 KiB. Each diagram retains the limits above. Do not create a separate
`.mmd` solely to duplicate a diagram already embedded in the document.
