# Terminal quick actions

macOS offers **Agent Commands** (`/`) and **Quick Phrases** in the panes-window
toolbar. Both open button-grid popovers. Click a command or saved phrase to send
literal text, a host-side 200 ms pause, and one Return. There is no confirmation
or extra Send step, and existing terminal input is never cleared automatically.

- The target is the last focused native terminal in this panes scene, including
  a pane in the right-hand workbench split. The popover shows its host, session,
  window name and pane ID. It never infers the target from the left selected tab
  or from a remote tmux client's active pane.
- Commands use the same curated agent catalog as iOS; this is not live capability
  discovery. Unsupported agents have no command panel. Working agents are not
  disabled just because a turn is running.
- Phrases work in ordinary shells too. **Add Phrase** saves without sending;
  right-click a phrase to delete it. The library is local-first and shared across
  windows and hosts. Optional, explicitly enabled pairing sync merges libraries
  between Macs and iPhones (see below).
- Disconnection, stream bootstrap, external editors and blocking agent forms
  prevent sending, not phrase management. Switching terminal, typing into it or
  destroying its native view invalidates the captured action; it cannot silently
  move to another pane or submit twice.

On iOS, the two first-row buttons open a shared **in-page overlay**, not a system
sheet. The overlay covers terminal content without contributing to its layout:
opening, switching and closing it leave the native first responder, keyboard
intent and second-row shortcut accessory in place. Tap the same toolbar button
again, outside the panel or Close to dismiss; the other button switches panels
directly. Panel toggles remain usable in **Add Phrase**, while terminal-key
buttons stay disabled. Only entering **Add Phrase** borrows input focus for its native editor;
returning restores the terminal's existing keyboard intent. Both tiled windows
and standalone terminal views use the same presentation state and target checks.
The overlay uses plain headers and local state for its phrase editor, with no
nested navigation stack, navigation destinations or environment dismiss action.
Closing a panel or cancelling/saving its editor cannot pop the session route.
Both panels share a rounded Liquid Glass surface on iOS 26+, falling back to
ultra-thin material on older systems. Only the overlay moves 24 points and fades
over 0.2 seconds, without an extra shadow layer; it no longer slides its full
height across the live terminal. The animation never wraps the terminal or keyboard rows. Reduce Motion uses a
fade only, and Reduce Transparency uses an opaque, legible surface. The phrase
editor hides its Form background so it does not obscure the shared material.

## Implementation boundaries

`CtrlxCommon/Models` owns `AgentCommandMenu`, `QuickPhraseStore` and
`TerminalPhraseContext` for both platforms. `QuickPhraseStore` migrates the existing
`terminalQuickPhrases.v1` array into `terminalQuickPhrases.v2`, preserving IDs and
order and leaving v1 intact as a backup. v2 is authoritative thereafter; unreadable
v2 fails closed instead of falling back to an obsolete v1 library.

`TerminalQuickActionRouter` is scene-local and tracks native first-responder
events. Each mounted coordinator provides an endpoint backed by its **existing**
`KeystrokeCoalescer`; the local path retains its serial task chain and the remote
path retains its `KeystrokeDebouncer`. No additional queue, tmux resize, rendering
change or SwiftTerm fork change is involved.

## Optional device sync

Enable **Sync Quick Phrases** on **both sides of each pairing**:

- iOS: Settings → Manage Hosts → the host's sync section.
- Mac acting as Host: Settings → Remote Access → the paired Viewer.
- Mac acting as Viewer: Settings → Remote Hosts → the paired Host.

The switch is off by default, persisted locally per pair, and cleared when that
pairing is removed. It applies to the **whole phrase library**, not the currently
visible session. Merged phrases also propagate through other opted-in pairings.
Turning it off stops sharing but does not erase already downloaded phrases.
Do not enable it for a device/user with whom you don't want to share your phrases.

Both app clients need this implementation. `PeerHelloMessage.quickPhraseSync` is
an optional versioned capability/consent offer. Older clients ignore it and
continue working locally; no new message types are sent to them. The existing
Qcloud relay forwards the opaque encrypted envelope, so **no relay redeployment
is required**. Neither the relay nor a new cloud service stores the phrase library.

`QuickPhraseSyncSession` sends a separate, end-to-end-encrypted `quickPhraseSync`
message only after the version handshake. Until both sides opt in, frames contain
consent only, no phrases. Connection epochs bind messages to the current handshake;
disconnect clears peer consent and cancels pending work. Plaintext sync messages
are rejected by both clients. Notification-only connections don't opt into sync.

Changes are saved immediately offline. On connection, both peers exchange and merge
their records; additions/deletions while connected are pushed without polling.
An iPhone in the background/offline catches up when its connection resumes; this
does not claim background/iCloud synchronization. Sync never dispatches terminal
commands or changes terminal size, rendering, scroll position, or input queues.

Records are immutable additions with stable UUIDs and deterministic ordering.
Deletion is a permanent tombstone for the observed IDs (not an array removal),
so stale snapshots cannot resurrect them. Identical text saved independently is
displayed once; deletion marks all currently known aliases. Explicitly saving
the same text again creates a new addition. This is an observed-remove merge,
not wall-clock last-writer-wins, and requires no device clock synchronization.

Snapshots are atomic and bounded: at most 4,096 records including tombstones and
512 KB of encoded JSON, leaving room for encryption/base64 within the relay's
1 MB limit. Unsupported/corrupt or over-limit data reports an error instead of
overwriting local data. Tombstones are not automatically pruned (offline peers
may still carry the deleted addition). At capacity, save/merge fails visibly.

Regression coverage: `AgentCommandMenuTests`, `QuickPhraseTests`, `QuickPhraseSyncTests`,
`QuickPhraseSyncTransportTests` (real local WebSockets with both production clients/E2EE),
`TerminalQuickActionRouterTests`, `LocalKeystrokeInputTests`, and
`KeystrokeDebouncerTests`. When manually checking the UI, cover local and remote
split panes, focus changes while a popover is open, adding/deleting phrases while
offline, typing after closing the editor, and sending with an existing draft.
