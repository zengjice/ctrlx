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

### Curated command catalogs

Both clients use `AgentQuickCommand.commands(for:)` as the display order and
send allowlist. Keep the agents' lists independent: matching command names do
not guarantee matching behavior. The current catalog was checked against Codex
CLI 0.154.0 and Claude Code 2.1.276 plus their official command references:
[Codex](https://developers.openai.com/codex/cli/slash-commands) and
[Claude Code](https://code.claude.com/docs/en/commands).

- **Codex (24):** `/model`, `/status`, `/usage`, `/fast`, `/personality`, `/plan`,
  `/goal`, `/compact`, `/resume`, `/fork`, `/rename`, `/agent`, `/diff`, `/review`,
  `/ps`, `/permissions`, `/skills`, `/mcp`, `/plugins`, `/theme`, `/keymap`,
  `/statusline`, `/experimental`, `/debug-config`.
- **Claude Code (27):** `/model`, `/status`, `/usage`, `/effort`, `/plan`, `/goal`,
  `/compact`, `/autocompact`, `/context`, `/resume`, `/branch`, `/rename`, `/diff`,
  `/review`, `/permissions`, `/skills`, `/mcp`, `/plugin`, `/reload-skills`,
  `/reload-plugins`, `/config`, `/theme`, `/output-style`, `/memory`, `/hooks`,
  `/tasks`, `/help`.

Only include commands with a useful no-argument invocation. Bare `/goal`
inspects the goal; it does not create one. Codex `/fast` changes the service
tier and can increase usage. Model, account, version and feature flags may still
limit commands on the actual host; the panel does not discover capabilities or
promise that every command can execute during a running turn.

Claude's `/plugin` remains singular, not Codex's `/plugins`. In the checked
baseline, bare `/effort`, `/autocompact` and `/output-style` open configuration
choices; `/rename` auto-generates a session name; `/branch` switches to a copy
of the conversation while preserving the original. `/diff` inspects changes,
and `/review` starts a review without adding `--fix` or `--comment`.
`/reload-skills` and `/reload-plugins` pick up pending changes without restarting;
CtrlX never appends `--force` to bypass Claude's plugin-reload warning.

`/agents` no longer opens an agent manager (since 2.1.198), so it is removed.
`/cost` and `/stats` are aliases of `/usage`, and `/code-review` duplicates
`/review`. Claude's `/fork` starts a background copy rather than switching into
a normal branch; `/fast` has additional cost and account restrictions. These,
`/statusline` (a setup task), `/doctor` (a repair workflow), and `/simplify`
(applies code changes) are deliberately excluded from Claude's one-tap catalog.
Clear/delete/exit/stop/approval actions and argument-required commands remain
outside these one-tap catalogs. Newer version-dependent entries are not added
solely because they appear in the latest documentation.

The Claude expansion was checked against the installed 2.1.276 command
definitions as well as the reference above. Updating Claude on a viewer Mac
does not update the agent on its remote hosts; those hosts need a compatible
Claude version too. Updating these built-in lists requires the Mac/iOS client
update, not a Relay deployment or phrase-library synchronization.

The Mac command grid scrolls within a capped height; its header and target label
stay visible. iOS retains its existing scrollable overlay and keyboard behavior.
Catalog tests cover both agents independently, including commands accepted by
one agent but rejected by the other, direct Return submission and stale-target
guards.

### Shared models and routing

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

On **both Mac and iOS**, open **Settings → Quick Phrase Sync**. Each paired device
has **one local switch**, covering every connection to it, regardless of terminal
Host/Viewer roles. Remote Access, Remote Hosts and Manage Hosts contain no phrase
sync controls. Both devices must allow sync; there is no master or role priority.
For reciprocal Office/Home pairings this means two switches total, not four.

Devices are grouped by the SHA-256 fingerprint of their paired Curve25519 public
key, never by device name or pair ID. The short fingerprint shown with each row distinguishes
same-name devices. Missing/malformed keys remain isolated per pairing. Renaming
does not change consent. Another pairing to the same key inherits that device's
choice; a new key does not inherit the replaced pairing's permission. Removing one
route keeps the other routes' consent; removing the last route clears the choice.

New devices default off. For upgrades, both pairing lists are loaded **before**
migrating old per-pair choices. Unanimous choices carry forward. Mixed choices show
**Needs confirmation → Review…**, preserving each old connection's behavior until
the user explicitly enables or disables all routes. They are never merged with OR,
which could turn two mismatched legacy gates into a new sharing path. Choices are
local permissions, not synchronized phrase records. Older peers may still require
their original per-pair switches; the wire protocol is unchanged.

Rows distinguish local off, confirmation needed, not connected, waiting for the
other device, unsupported peer, and connected/both sides enabled. These reflect
the actual version/consent handshake, **not a delivery acknowledgement**. A usable
route wins over an offline reverse route; individual errors remain visible. Status
clears on disconnect and ignores a superseded connection's late reset.

The setting applies to the **whole phrase library**, not the currently visible
session. Merged phrases also propagate through other opted-in devices. Turning a
device off stops direct sharing, but does not erase downloaded phrases or block
indirect propagation through other devices. Only enable sharing within a trusted
group. Built-in agent commands have no separate sync switch.

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

Regression coverage: `AgentCommandMenuTests`, `QuickPhraseTests`, `QuickPhraseDeviceSyncTests`,
`QuickPhraseDeviceSettingsTests` (real Mac settings load/pair/unpair), `QuickPhraseSyncTests`
(including all 16 reciprocal legacy combinations and a four-device cycle),
`QuickPhraseSyncTransportTests` (real local WebSockets with both production clients/E2EE),
`TerminalQuickActionRouterTests`, `LocalKeystrokeInputTests`, and
`KeystrokeDebouncerTests`. When manually checking the UI, cover local and remote
split panes, focus changes while a popover is open, adding/deleting phrases while
offline, typing after closing the editor, and sending with an existing draft.
