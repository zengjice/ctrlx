# Terminal quick actions

macOS offers **Agent Commands** (`/`) and **Quick Phrases** on the right side of
the terminal's bottom status bar, for both local and Viewer windows. They follow
Settings → General → Show status bar. Both open button-grid popovers. Click a
command or saved phrase to send literal text, a host-side 200 ms pause, and one
Return. There is no confirmation
or extra Send step, and existing terminal input is never cleared automatically.

- The target is the last focused native terminal in this panes scene, including
  a pane in the right-hand workbench split. The popover shows its host, session,
  window name and pane ID. It never infers the target from the left selected tab
  or from a remote tmux client's active pane.
- Only the focused window's status bar shows the controls. Other visible terminal
  windows reserve the same space, preventing focus changes from resizing terminals;
  their hidden controls cannot be clicked or accessed by VoiceOver. Unparseable
  remote layouts retain the same window-level status bar as tiled layouts.
- Commands use the same curated agent catalog as iOS; this is not live capability
  discovery. Unsupported agents have no command catalog. Working agents are not
  disabled just because a turn is running.
- Phrases work in ordinary shells too. **Add Phrase** saves without sending;
  right-click a phrase to delete it. Drag a phrase onto another tile to move it
  to that tile's position on both Mac and iOS. Reordering saves immediately, even
  offline, without sending terminal input or closing the panel. VoiceOver offers
  **Move Earlier** and **Move Later** actions. The library is local-first and shared across
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

### Agent identity and command-panel availability

The Mac and iOS `/` buttons always open their panels. If the current pane has no supported
agent identity, the panel explains why no catalog is available; it never guesses
Codex from a window title or reuses another pane's agent. Host metadata arriving
while that explanation is open restores the matching catalog only for the same
host, pane and local input revision. Connection/readiness/editor/blocking-form
checks still apply when sending; opening the panel grants no send permission.
Changing targets or editing terminal input invalidates the captured panel.

Opening an unidentified **local Mac** command panel also requests one fresh,
manifest-driven process snapshot, bypassing the one-second snapshot cache. This
reuses the Host's reconciliation and viewer updates; it does not send terminal
input, guess an agent from the command line or window title, or add a polling
loop. Remote panels wait for Host metadata as before. The ten-second background
scan remains a fallback for manual launches and resumes whose hooks are absent,
disabled, or late. Detection includes an agent that replaces the pane's shell
with `exec`.

Session-end suppression is tied to the observed old agent process IDs, not the
pane ID alone. A different process in the same pane can be identified without
waiting for a scan to observe an empty shell. If no process was observed before
the end event, the Host does not create a blanket suppression for unknown future
processes. Failed probes leave both identity and suppression unchanged. Hook
states remain authoritative; opening a panel grants no send permission.

On the Mac Host, Codex's session-end monitor uses
`PluginHost.agentPanesIfAvailable()`. A failed, cancelled or unsupported process
probe is `nil`, not an empty list: it preserves identity, correlation and the
previous live baseline until a successful probe. Only a confirmed absence can
end a session. This prevents a temporary probe failure from clearing the agent
on all viewers (or requesting pane closure). The legacy sidecar listing API is
unchanged. This fix requires updating the Host Mac for identity stability and
iOS for the always-openable explanation; no Relay deployment is needed.

### Curated command catalogs

Both clients use `AgentQuickCommand.commands(for:)` as the display order and
send allowlist. Keep the agents' lists independent: matching command names do
not guarantee matching behavior. The current catalog was checked against Codex
CLI 0.160.0 and Claude Code 2.1.276 plus their official command references:
[Codex](https://learn.chatgpt.com/docs/developer-commands?surface=cli) and
[Claude Code](https://code.claude.com/docs/en/commands).

- **Codex (46):** `/model`, `/status`, `/usage`, `/fast`, `/personality`, `/plan`,
  `/goal`, `/compact`, `/resume`, `/fork`, `/rename`, `/agent`, `/diff`, `/review`,
  `/ps`, `/permissions`, `/skills`, `/mcp`, `/plugins`, `/theme`, `/keymap`,
  `/statusline`, `/experimental`, `/debug-config`, `/ide`, `/vim`, `/apps`,
  `/hooks`, `/memories`, `/copy`, `/import`, `/feedback`, `/init`, `/app`, `/side`,
  `/raw`, `/title`, `/pets`; **Session Actions:** `/new`, `/clear`, `/archive`,
  `/delete`, `/approve`, `/stop`, `/logout`, `/exit`.
- **Claude Code (75):** `/model`, `/status`, `/usage`, `/effort`, `/fast`, `/plan`, `/goal`,
  `/compact`, `/autocompact`, `/context`, `/resume`, `/branch`, `/fork`, `/rename`, `/diff`,
  `/review`, `/permissions`, `/skills`, `/mcp`, `/plugin`, `/reload-skills`,
  `/reload-plugins`, `/config`, `/theme`, `/output-style`, `/memory`, `/hooks`,
  `/tasks`, `/help`, `/advisor`, `/artifacts`, `/copy`, `/export`, `/import`,
  `/feedback`, `/bug`, `/ide`, `/chrome`, `/color`, `/desktop`, `/mobile`, `/passes`,
  `/powerup`, `/privacy-settings`, `/radio`, `/rate-limit-options`, `/recap`,
  `/release-notes`, `/remote-control`, `/remote-env`, `/sandbox`, `/scroll-speed`,
  `/skill-doctor`, `/teleport`, `/tui`, `/focus`, `/upgrade`, `/usage-credits`,
  `/voice`, `/web-setup`, `/workflows`, `/statusline`, `/doctor`, `/debug`, `/init`,
  `/insights`, `/security-review`, `/simplify`; **Session Actions:** `/background`,
  `/rewind`, `/clear`, `/stop`, `/login`, `/logout`, `/exit`.

`AgentCommandSection` partitions the same send allowlist for both clients,
preserving order with nonempty sections and stable section/command IDs.
Session/account actions are separated at the bottom by a **Session Actions**
heading and red-tinted buttons. They still send immediately on a single click;
CtrlX does not add a confirmation or suppress the agent's own dialogs.
These actions can reset a conversation, remove a transcript, stop work, exit or
change host credentials. They retain the same target/input/availability checks
as ordinary commands; `/approve` cannot bypass an open blocking form.

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

Claude's `/fork` starts a background copy rather than switching into a normal
branch; `/fast` has additional cost and account restrictions. Setup/repair
workflows such as `/statusline`, `/doctor` and `/init`, plus code-editing
`/simplify`, are now explicit user-invoked buttons, not automatic tasks.
`/remote-control`, `/chrome`, `/desktop` and other integrations retain Claude's
own semantics; CtrlX does not replace them with its Relay or Agent Browser.

Removed Claude entries (`/agents`, `/vim`, `/pr-comments`, `/ultraplan`), duplicate
aliases, required-inline-argument entries (`/mention`, `/add-dir`, `/batch`,
`/deep-research`, `/subtask`), Codex's Windows-only sandbox setup and hidden
credential-bearing `/heapdump` stay out. Claude's provider-specific setup and
other-terminal configuration commands are not generic CtrlX shortcuts. This is
a curated built-in catalog, not enumeration of every bundled/custom skill.

The Claude expansion was checked against the installed 2.1.276 command
definitions as well as the reference above. Updating Claude on a viewer Mac
does not update the agent on its remote hosts; those hosts need a compatible
Claude version too. Updating these built-in lists requires the Mac/iOS client
update, not a Relay deployment or phrase-library synchronization.

The Mac command grid scrolls within a capped height; its header and target label
stay visible. iOS retains its existing scrollable overlay and keyboard behavior.
Catalog tests cover both agents independently, including commands accepted by
one agent but rejected by the other, stable section order and complete coverage,
direct Return submission and stale-target guards. Tests construct requests and
inspect key sequences; they never execute logout/reset/delete/exit against a
real agent or change account credentials.

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

User-defined order is a separate optional snapshot, not a mutation of an
addition's original `order`. It is stored in the same v2 library and encrypted
sync frame. Higher logical revisions win; a UUID deterministically breaks ties
between concurrent offline reorders. The next local reorder increments the
accepted revision. New, unranked phrases append; known duplicate-text aliases
move together, and tombstones still prevent resurrection. A stale or record-only
snapshot never resets an accepted order. Both devices must be updated to sync
ordering; older clients ignore the additive field and continue syncing additions
and deletions. Reordering neither changes consent nor needs a Relay deployment.

Snapshots are atomic and bounded: at most 4,096 records including tombstones and
512 KB of encoded library JSON including ordering, leaving room for encryption/base64 within the relay's
1 MB limit. Unsupported/corrupt or over-limit data reports an error instead of
overwriting local data. Tombstones are not automatically pruned (offline peers
may still carry the deleted addition). At capacity, save/merge fails visibly.

Regression coverage: `AgentCommandMenuTests`, `QuickPhraseTests`, `QuickPhraseReorderingTests`, `QuickPhraseDeviceSyncTests`,
`QuickPhraseDeviceSettingsTests` (real Mac settings load/pair/unpair), `QuickPhraseSyncTests`
(including all 16 reciprocal legacy combinations and a four-device cycle),
`QuickPhraseSyncTransportTests` (real local WebSockets with both production clients/E2EE),
`TerminalQuickActionRouterTests`, `LocalKeystrokeInputTests`, and
`KeystrokeDebouncerTests`. When manually checking the UI, cover local and remote
split panes, focus changes while a popover is open, adding/deleting phrases while
offline, typing after closing the editor, and sending with an existing draft.
