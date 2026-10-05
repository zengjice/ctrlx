# Host-backed Files tabs

Mac Host, Mac Viewer and iOS share the read-only `WorkspaceFileBrowserView`.
Open **New Files** from the Mac tab-strip `+` menu or the iOS window-title menu.
Each session can keep multiple independent Files tabs alongside terminals and
web browsers. On Mac, these are ordinary reorderable, closable, splittable tabs.
On iOS, a Files tab fills the session content area; the title menu switches tabs
without adding a navigation stack or presenting a half-height sheet.

## Directories and lifetime

- A new tab captures the focused terminal pane. The Host resolves the agent's
  project directory, then a fresh `pane_current_path`, then its home directory.
  The Viewer never interprets a remote path against its own disk.
- Once opened, its directory does not follow later `cd` operations. **Source Pane
  Directory** explicitly resolves it again. Up, Home and the path field navigate
  independently in each tab.
- Closing the source pane does not destroy the Files tab. Persisted layouts keep
  paths, expanded folders, hidden-file preference and selected file, not ephemeral
  pane IDs or file contents. Mac uses its existing Host + folder layout store;
  iOS saves a private Host + folder workspace. Both restore and save use the Host's
  active window/pane directory (agent project, then cwd). A context change updates
  the save target even if no tabs changed; it never reloads over live tabs. Initial
  restoration waits for a known directory instead of using a placeholder home path.
  Layouts are not broadcast to peers.
- Refresh is explicit. There is no background directory polling; previews release
  their data when hidden. Reopening reloads current Host contents.

## Supported operations

Directory listing, hidden files, recursive filename/text search, UTF-8 text and
Markdown, image and PDF previews, copy path/text. Mac supports tree expansion;
iOS opens folders as full-area lists. Markdown attachments do not automatically
fetch network resources or read Viewer-local `file://` URLs.

Editing, large-file transfer, video playback and remote Chromium control are not
part of this change. Existing local editor tabs and web-browser ownership remain
separate.

## Transport and bounds

`BrowseFiles` uses the existing encrypted command/response connection. The Host
advertises optional `supportsFileBrowsing`; missing/false capability fails before
sending a command, with an upgrade message. The opaque Relay needs no deployment.
The Host and the Viewer app must both contain this feature.

`FileBrowserSource` hides local/remote transport. The dependency-injected
`FileBrowserClient` runs filesystem work on the independent `HostFileBrowser`
actor. Each connection allows up to four pending file operations, dispatched
outside its sequential receive loop so a slow file request does not block keys.
Disconnect cancels pending work and prevents old-connection replies.

- Directory pages: at most 200 entries / 128 KiB; directories above 50,000 entries
  require opening a subfolder directly.
- Reads: regular files only, 128 KiB chunks; text up to 512 KiB, images/PDFs up to
  8 MiB. Descriptor/path revisions are checked around reads; mixed-version data
  is never shown. Directory page revisions are also checked before appending.
- Search: at most 20,000 entries, 200 matches, approximately 16 MiB read and a
  two-second scan budget, checked between files. Partial results are labelled.
  Search does not recurse into symlinks; explicit navigation into one is allowed.
- Image decoding runs off the UI actor and thumbnails to at most 2048 pixels.
- Each tab rejects stale replies after a newer navigation/preview request.

## Validation

Focused coverage: `HostFileBrowserTests`, `FileBrowserLayoutTests`,
`FileBrowserTabTests`, `FileBrowserProtocolTests`, `IOSFileBrowserWorkspaceTests`,
`LayoutSnapshotMapperTests`, and `TerminalPasteTransportTests`.
Tests include fresh source-pane cwd resolution,
directory pagination/hidden files, symlink loops, special/oversized/changing files,
multi-chunk search, stale replies, private layout restoration after directory
changes, terminal selection replacing Files without disturbing split tabs,
legacy capability gating, and encrypted transport while a file response is delayed.

Manual acceptance on installed apps: open two panes in different directories;
create a Files tab from each on Mac Host, Mac Viewer and iOS; preview text,
Markdown, image and PDF; switch tabs during loading; disconnect/reconnect; return
to a terminal and type while a search is running. Verify Mac tab reorder/split/
close and that the iOS title menu stays in the session page.
