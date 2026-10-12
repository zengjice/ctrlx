# Host-backed Files tabs

Mac Host, Mac Viewer and iOS share `WorkspaceFileBrowserView`.
Right-click a terminal window tab on Mac Host/Viewer and choose **Open Files**.
On iOS, tap the window title to open the **Tabs** list, then use that window row's
`⋯` menu → **Open Files**. Tapping a row switches tabs; its menu operates on that
row without first switching the terminal. Fork, rename and close use the same
per-window menu. New Terminal / Agent remain separate creation actions at the
bottom of the iOS list; the Mac `+` menu does not create Files.
Each session can keep multiple independent Files tabs alongside terminals and
web browsers. On Mac, these are ordinary reorderable, closable, splittable tabs.
On iOS, a Files tab fills the session content area. The title opens a native
medium/large tab-list sheet without a nested navigation stack. Actions are
applied after dismissing this list, before presenting a Fork/Agent sheet or alert.
Files rows expose only their own selection/close actions, not terminal operations.

## Directories and lifetime

- A new tab captures a pane inside the window whose menu was used: prefer the
  focused pane only if it belongs to that window, then its active/first pane.
  Focus in another window can never redirect the initial directory. iOS captures
  the stable window ID and resolves the target again after the list closes; a
  closed target fails rather than falling back to the currently selected window.
  The Host resolves the agent's
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

### Explicit terminal file links

Mac Host, Mac Viewer and iOS recognize the literal marker
`<repo:outputs/report.pdf>`, emitted as inline code to preserve both delimiters.
This is a lightweight application convention, **not a registered URI standard**.
There is no private CtrlX URI, CLI generation step, link registry or startup hook.
Ordinary paths, slash commands, local Markdown targets and `file://`/OSC 8
file targets are not inferred or opened. Web links retain their own handling.
Compatibility with previous file-link output is deliberately dropped.

Paths are relative to the **current source agent's Git worktree root**.
A nested launch directory resolves to its worktree root, not the primary checkout.
`<repo:.>` opens the root. No leading `./`, empty components or `..` are accepted.
Spaces and reserved punctuation use UTF-8 percent encoding; literal percent signs
must be `%25`. Chinese may remain literal or be encoded. Decoding happens once:
a filename containing literal `%27` must not become an apostrophe on the Host.
Complete markers survive soft/hard visual wraps, including a wrap inside the
prefix or percent escape. Missing delimiters, whitespace, malformed escapes,
control characters and paths exceeding 4096 UTF-8 bytes are rejected. No filename
or continuation is guessed.

A click captures the Host, pane and its agent context (plugin ID, conversation ID
when available, and detected project directory). `BrowseFiles.repositoryInfo`
runs off the keyboard receive loop. The Host checks that context before and after
resolution, runs `git rev-parse --show-toplevel`, checks existence and canonical
symlink containment, and returns the existing file-info response. Missing context,
non-Git projects, missing files and links outside the worktree fail clearly:
there is no shell-cwd fallback or alternate-directory search. Remote clients gate
the operation on `supportsRepositoryFileLinks`; an older Host is not sent an
undecodable request. No Relay implementation/deployment change is needed.

The marker intentionally carries no absolute path or repository identity.
It is not an access grant or proof of provenance. After reusing a pane/session for
another workspace, old output is interpreted in the **current** agent worktree;
historical links are not guaranteed to identify the old repository. This is the
chosen KISS boundary, rather than a per-output provenance registry.

Click/tap an underlined marker to open Files in the same session. A directory
opens directly; a file selects its existing inline preview. Video still waits
for Play. Each source terminal window reuses its own link-created Files tab,
even across directories or panes. The association uses the stable tmux window ID
inside that Host/session's private workspace. Different windows never share it
merely because files are in the same directory. Manual **Open Files** tabs stay
independent. Closing the link-created tab allows the next link to create a new
one. Reuse updates the source pane, preserving the tab UUID and Mac split placement.

The window association is live-only: saved layouts retain the directory/selection,
not that association. Restored tabs remain independent. Changing windows, leaving
the view or changing the source agent during resolution prevents late navigation.
The Viewer never resolves a remote path against its own filesystem.

Decorations, hover and activation share one bounded visible-row snapshot,
refreshed on buffer edits, cursor/mouse-mode changes, scrolling, resize and
payload updates. iOS supplies actual native visible rows during inertial scrolling.
The live input/composer, selection, drag and modifier gestures retain their existing
protection. The scanner performs no filesystem I/O or network work.

### Agent output convention and migration

The short independent `file-links` skill remains one of four shared skills.
Its canonical source is `plugin/ctrlx/skills/file-links/SKILL.md`, packaged for
Claude Code and mirrored into Codex by `scripts/sync-codex-skills.sh`.
Bundled skill versions: Codex **1.1.3**, Claude Code **1.3.4**.
Update the Host and each Mac/iOS Viewer, update the installed agent plugin,
then start a new agent session. Updating only the App does not refresh a cached
agent plugin. Both TUIs should receive an inline-code literal marker, never a
Markdown link target that the renderer can hide or shorten.

Tests cover marker recognition, every soft/hard wrap boundary, inertial viewport
snapshots, single decoding, source-context changes and actual Git worktree/symlink
resolution. Device tap/render acceptance still requires a real iPhone; macOS unit
tests do not run the iOS-only viewport test.

### Creating folders and adding files

The directory toolbar's **⋯** menu offers **New Folder…** and **Import Files…**
(local Mac Host) / **Upload Files…** (Mac Viewer and iOS). New Folder accepts one
literal child name through a native alert and reuses `CreateSessionDirectory`.
It refreshes the list without navigating into the new folder or starting a session.
The native file picker accepts multiple ordinary files. Import is a copy, never
a move. Remote upload always writes to the Host, never a matching Viewer path.
The destination is captured from the Files tab when the action begins; navigation
or changing terminal focus cannot redirect an in-progress operation.

Files transfer sequentially, at most 1 GiB each, with filename/byte progress and
Cancel above the directory/preview. Successful files refresh the listing; there
is no automatic preview or insertion into terminal input. Existing names (also
directories or symlinks) are never replaced. Failed files are reported in the
completion summary and remaining selections continue. Closing/hiding the tab,
disconnecting, or backgrounding iOS cancels unfinished work; already completed
files remain. Folder uploads, drag-and-drop, background transfers and resume
are not supported.

`FileBrowserUploadReader` uses the system file-picker access grant to prepare an
`NSFileCoordinator.forUploading` snapshot off the UI actor. It waits for coordinated
saves before taking that snapshot, opens its descriptor inside the accessor, then
releases the original file and access grant. Later saves cannot change the upload
or be blocked by a slow transfer. Reads remain bounded to 128 KiB; directories,
symlinks and files over 1 GiB are rejected. Cancellation stops pending coordination;
closing the descriptor releases the unlinked snapshot. `HostFileUploads` belongs
to one Viewer connection (a separate local instance serves Host imports), allows
four active uploads, and verifies ordered
offsets, declared length and an incremental SHA-256 digest. It opens the destination
directory once, creates a private sibling temporary file, then publishes through
an exclusive atomic rename. Destination replacement/movement fails validation.
Failure/cancel/disconnect removes partial files; abandoned uploads expire after
60 seconds of inactivity, checked every 30 seconds. A process crash can leave
hidden `.ctrlx-upload-*.tmp` files; these are not treated as completed uploads.

Folder creation keeps the existing `supportsDirectoryCreation` capability;
uploads require new optional `supportsFileUploads`. Unsupported actions are
disabled with an upgrade hint, and commands are also gated before transmission.
Host and Viewer need the updated upload implementation; the existing opaque
Relay needs no deployment. Upload chunks and folder creation use the bounded
file-operation queue, outside the keyboard receive loop.

Directory listing, hidden files, recursive filename/text search, UTF-8 text and
Markdown, image and PDF previews, copy path/text. The local Mac Host also previews
video/audio using AVKit and the validated local file URL, without loading media
into memory or applying remote preview limits. Mac supports tree expansion;
iOS opens folders as full-area lists. Markdown attachments do not automatically
fetch network resources or read Viewer-local `file://` URLs.

Word (`doc`, `docx`), Excel (`xls`, `xlsx`) and PowerPoint (`ppt`, `pptx`)
use read-only system Quick Look inside the Files preview area: `QLPreviewView`
on Mac and `QLPreviewController` on iOS, not an external app or modal sheet.
The local Host uses a validated file URL. Viewer/iOS selection automatically
downloads a cache copy through the existing encrypted download command, capped
at 32 MiB before creating the cache. Loading shows progress and Cancel; changing
file, refreshing, leaving the tab or disconnecting cancels that task and removes
partial copies. Refresh Preview retries a cancelled/failed preview. Existing
text/image/PDF/media limits and rendering remain unchanged. Quick Look support
and fidelity depend on the OS; encrypted, damaged or complex documents may not
render. Office editing, macros, formula recalculation and slide animations are
not supported. The external-open action remains available as a fallback.

**Open in Default App** hands a local Host file to macOS. **Download and Open**
on Mac Viewer or iOS downloads a copy only after a click. Mac opens the copy in
the default app; iOS uses Quick Look and offers **Share / Open in…** for other
apps or Save to Files. System codec/app support still determines whether a file
can be opened. Copies are not edited back onto the Host.

### Remote video playback

Mac Viewer and iOS offer **Play Video** for MP4/MOV in the inline preview area.
Selection alone sends no video reads. Playback uses AVKit and a custom
AVFoundation resource loader, requesting byte ranges through the existing
encrypted download command. It does not expose a public file URL, start an HTTP
server, create a complete disk copy or use Chromium. The local Mac Host keeps
its validated file-URL player unchanged. Other formats retain Download and Open;
actual codec support is determined by the OS. There is no transcoding or live
streaming, and the existing 1 GiB export limit is preserved.

Each preview has an 8 MiB LRU chunk cache, at most one network read in flight,
and a bounded loading-request queue. Reads rotate between pending ranges, so
file-tail metadata and seeks cannot wait behind a request for the entire file.
The player requests a three-second forward buffer; actual loaded time ranges
also suspend feeding once sufficiently buffered. This is not a hard bound on
AVFoundation's own decoder/buffer memory. Pause/background suspend reads.
Leaving the active scene during metadata preparation cancels that attempt;
late replies cannot create a player, even after returning to the foreground.
A ready player is retained but never automatically resumed on foregrounding.
On iOS, each opened video starts muted, with a persistent **Enable Sound / Mute**
speaker button below the player. The choice survives pause/foregrounding within
that preview, but closing/reopening or selecting another video starts muted again.
Enabling sound during playback uses the media-playback audio session, so the
Silent Mode switch does not prevent sound. Media volume and the selected output
route (including headphones) remain system-controlled. Preparing or starting a
muted video does not explicitly activate audio. Once enabled, audio is released
on pause, backgrounding or closing; muting does not restart the player. Native
controls reactivate audio on audible resume and keep the speaker button in sync.
Audio ownership uses one stable lease per player across all iOS scenes; only
releasing the last lease deactivates the shared session. Pausing or closing one
iPad window therefore leaves another window's audible playback active.
Voice-input cleanup only releases its own recording session and cannot deactivate
a video that has since taken over. Mac Host/Viewer playback defaults are unchanged.
Unbuffered seeks while paused are serviced on explicit resume. Closing, changing file,
refreshing or disconnecting cancels reads and drops the memory cache. There is
no persistent video cache. Low bandwidth/high latency can still cause buffering.
Blocks yield between replies; they do not change terminal receive scheduling.

Streaming needs the existing file-download capability, so download-capable
older Hosts work without a new command/handshake field or Relay deployment.
New viewers fail immediately with the existing upgrade hint on a legacy Host.

Downloads show byte progress and can be cancelled. Selecting another file,
leaving the tab or disconnecting cancels pending work. Partial copies are removed;
successful copies stay in the app's `Caches/CtrlX/FileBrowserDownloads` directory
so external apps can continue reading. Starting another download cleans copies
older than 24 hours, never active downloads. Free space is checked before writing.

Editing and remote Chromium control are not part of this change. Existing local
editor tabs and web-browser ownership remain separate.

## Transport and bounds

`BrowseFiles` uses the existing encrypted command/response connection. The Host
advertises optional `supportsFileBrowsing`; missing/false capability fails before
sending a command, with an upgrade message. The opaque Relay needs no deployment.
The Host and the Viewer app must both contain this feature. Explicit downloads
have their own optional `supportsFileDownloads` capability; an older Host can
still browse/preview while a new Viewer immediately prompts an upgrade for
downloads, without sending the unknown command variant.
Office inline previews need the same download capability. They detect the file
extension on the client, so a download-capable older Host that labels Office as
text does not need a protocol update. No Office-specific wire enum is added.

`FileBrowserSource` hides local/remote transport. The dependency-injected
`FileBrowserClient` runs filesystem work on the independent `HostFileBrowser`
actor. Each connection allows up to four pending file operations, dispatched
outside its sequential receive loop so a slow file request does not block keys.
Disconnect cancels pending work and prevents old-connection replies.

- Directory pages: at most 200 entries / 128 KiB; directories above 50,000 entries
  require opening a subfolder directly. Listings use `getattrlistbulk` types and
  flags from the parent filesystem without reading child-directory metadata, so
  a stalled child NFS mount does not block its parent (including Home). Directory
  rows carry navigation hints (zero size/empty revision); entering a directory
  validates its actual metadata.
  Files, symbolic links and unknown entry types retain metadata checks. Hidden
  listings include dot-prefixed names and entries marked with macOS `UF_HIDDEN`;
  otherwise both are skipped before sorting and pagination.
- Reads: regular files only, 128 KiB chunks; text up to 512 KiB, images/PDFs up to
  8 MiB. Descriptor/path revisions are checked around reads; mixed-version data
  is never shown. Directory page revisions are also checked before appending.
- Explicit downloads: regular files up to 1 GiB, the same 128 KiB encrypted
  chunks and revision checks, written one chunk at a time off the UI actor.
  This does not relax the inline-preview or search bounds. Even empty files
  require a validated Host read, rejecting FIFOs/devices without blocking.
- Automatic Office previews use that download path with a stricter 32 MiB
  client-side limit; local Host Office previews use the file directly.
- Search: at most 20,000 entries, 200 matches, approximately 16 MiB read and a
  two-second scan budget, checked between files. Partial results are labelled.
  Search does not recurse into symlinks; explicit navigation into one is allowed.
- Image decoding runs off the UI actor and thumbnails to at most 2048 pixels.
- Each tab rejects stale replies after a newer navigation/preview request.

## Validation

Focused coverage: `HostFileBrowserTests`, `FileBrowserLayoutTests`,
`HostFileUploadTests`, `FileBrowserUploadTests`,
`FileBrowserTabTests`, `FileBrowserTransferTests`, `FileBrowserProtocolTests`, `IOSFileBrowserWorkspaceTests`,
`LayoutSnapshotMapperTests`, and `TerminalPasteTransportTests`.
`TerminalFileLinkTests` covers explicit URI encoding, all hard/soft wrap boundaries,
truncation and ordinary-path rejection, Chinese OSC 8 hit cells, web precedence,
input protection, Host-only resolution, unavailable files and cancellation.
`FileLinkCommandTests` and `FileLinkAPITests` cover CLI worktree resolution,
Host-only existence checks, file/directory targets, missing files and capabilities.
`TerminalFileLinkSnapshotTests` checks decoration/activation agreement across a
long wrapped link, reuse on unchanged content, in-place edits, cursor/mouse mode,
resize, alternate buffers, scrollback trimming and external payload invalidation.
Workspace tests cover cross-directory/per-pane reuse within one window, separate
windows at the same directory, manual-tab isolation, close/reopen, tab limits,
Host isolation, split placement and restoration without stale window ownership.
Tests include fresh source-pane cwd resolution,
directory pagination/dot-prefixed and system-hidden files and folders, search
visibility consistency, deferred mount-point metadata, unknown types,
symlink loops, special/oversized/changing files,
upload snapshots waiting for coordinated saves, cancellation during that wait,
and snapshot stability across subsequent saves,
multi-chunk search, stale replies, private layout restoration after directory
changes, terminal selection replacing Files without disturbing split tabs,
legacy capability gating, and encrypted transport while a file response is delayed.
The opt-in `CTRLX_VERIFY_FILE_BROWSER_HOME=1` enables the read-only
`HostFileBrowserTests.liveHomeProbe` against the actual Host Home directory.
Additional coverage checks native local-media URLs without transfer, explicit
binary downloads, download frame round-trips, cancellation/failed-copy cleanup,
disk-cache expiration, and new-command rejection on a legacy Host.
Office regressions cover six case-insensitive extensions, binary copies from
Hosts classifying them as text, the automatic-preview size boundary, local
file URLs, download capability gating and preservation of other preview paths.
Video coverage includes random ranges/EOF/overflow, LRU and the default 8 MiB
bound, corrupt/stale replies, cancellation, capability gating, real MP4/MOV
first-frame decoding before a complete download, forward/backward seeks,
single-flight reads, native playback pause/resume/teardown, and delayed metadata
across backgrounding, foregrounding, cancellation and a fresh preparation.
Audio coverage uses an H.264/AAC fixture to extract its audio track through the
streaming loader, and injected audio-session calls verify explicit/native resume,
pause/background/close, default-muted playback, sound toggling without restart,
native mute changes, activation failure and idempotent cleanup. Audible output
in Silent Mode and output routing still require an iPhone acceptance check.
Shared-lease tests cover duplicate acquisition/release, failed acquisition and
two players when one pauses, backgrounds or closes. Native resume tests check
current playback and lease ownership rather than accumulated callback counts,
since AVPlayer can transiently pause during a rapid background/resume.

Manual acceptance on installed apps: open two panes in different directories;
create a Files tab from each on Mac Host, Mac Viewer and iOS; preview text,
Markdown, image and PDF; switch tabs during loading; disconnect/reconnect; return
to a terminal and type while a search is running. Verify Mac tab reorder/split/
close and that the iOS tab list stays in the session page.
Click links to two different directories in one terminal window and verify a
single Files tab changes its directory/preview. Repeat from another pane in the
same window, then from a different window pointing at the same directory. Move
the first Files tab to the Mac right split, rename/reorder its source window,
and repeat the links; keep manually opened Files tabs unchanged. Close the
link-created tab and click again to verify a fresh tab is created.
Also preview a local MP4 larger than 8 MiB, open it in the default app, then
download/open it on Mac Viewer and iOS. Verify Quick Look/share, cancel mid-copy,
change the source file mid-copy, and test against a Host without download support.
Also operate on a nonselected window while focus remains in another one. Check
its directory/Fork source, rename/close target after a window reorder, and close
an unselected Files row without changing the current tab. Cancelling the iOS tab
list must not switch tabs, start a request or open a second sheet.
Office acceptance: open Word/Excel/PowerPoint documents in all three Files
surfaces without a sheet or external app; inspect multiple pages/sheets/slides.
Cancel a slow transfer, switch files, refresh, and disconnect; confirm partial
copies are removed and later previews still work. A remote document above
32 MiB must offer the existing Download and Open path rather than auto-transfer.
Video acceptance: use Play Video on Mac Viewer/iOS, seek forward/backward,
pause/resume and leave the tab. Check unsupported codecs, a movie above 1 GiB,
Host disconnect/reconnect and simultaneous terminal input. Compare first-frame,
seek latency and terminal-input latency on LAN, WireGuard and the hosted Relay;
automated local-delay tests cannot establish real-network playback quality.
On iPhone, repeat with Silent Mode enabled and a nonzero media volume: confirm
initial playback is silent, Enable Sound produces speaker/headphone audio, and
Mute silences it without a seek/restart. Check pause/foreground behavior, a fresh
preview resetting to muted, and video/voice-input switching.
On iPad, enable sound in two app windows, then pause/background/close one:
the other must retain sound until it too pauses or closes.
